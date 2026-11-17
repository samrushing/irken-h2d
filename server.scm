;; -*- Mode: Irken -*-

;; the parts of an irken-h2d server that every program built on it shares:
;;  TLS/h2 connections, the accept loop, certificates, users, SIGHUP
;;  reloading and the globals the handlers use.  serve.scm (the file
;;  server) and photos/photos.scm (the photo browser) are built on it.

(require "lib/basis.scm")
(require "lib/getopt.scm")
(require "lib/random.scm")
(require "lib/mtwist.scm")
(require "lib/posix.scm")
(require "lib/regex.scm")
(require "doom/tls/tls13.scm")
(require "lib/crypto/x509.scm")
(require "doom/socket.scm")
(require "doom/http/h2.scm")
(require "doom/http/html.scm")
(require "log.scm")
(require "redirect.scm")
(require "stats.scm")
(require "handler.scm")
(require "file-handler.scm")
(require "timestamp.scm")
(require "dns.scm") ;; for ptr lookups

(define (send-status request code)
  (debugf "=> " (ansi red code) " " (string (if-maybe p (lookup-header ":path" request.headers) p "none")) "\n")
  (request.send-headers code (list:nil) #f))

(define (send-404 request)
  (send-status request "404"))

(define (note-event stat event)
  (push! stat.events event)
  (match event with
    (conn-event:tls-error (maybe:yes desc) s)
    -> (debugf "tls-error " (sym (tls-alert-desc->name desc)) " " (string s) "\n")
    (conn-event:tls-error (maybe:no) s)
    -> (debugf "tls-error " (string s) "\n")
    (conn-event:h2-error err)
    -> (debugf "h2-error " (string err) "\n")
    (conn-event:os-error err)
    -> (debugf "os-error " (string err) "\n")
    _
    -> #u
    ))

;; <creds> is {x509s skey}: each connection uses the current ones (see
;;  reload-on-sighup).
(define (h2-channel h2-handler creds alpns)
  (lambda (addr sockfun)
    (poller/fork
     (lambda ()
       (let ((stat (*stats*.add addr)))
         (try
          (let ((sock (tls13/make-channel sockfun creds.x509s creds.skey alpns)))
            (note-event stat (conn-event:tls-good (sock.get-info)))
            (try
            (try
             ;; create and invoke h2 read-frames loop.  each request is
             ;;  recorded against this connection's entry (not looked up by
             ;;  address: another connection may share it, e.g. one to
             ;;  port 80 from the same source port).
             ((make-h2-conn addr sock
                            (lambda (request)
                              (note-event stat (conn-event:h2-request request.headers))
                              (h2-handler request))))
             except
             (:Doom/EOF _)
             -> (note-event stat (conn-event:os-error "eof"))
             (:H2/BadFrame f)
             -> (note-event stat (conn-event:h2-error "bad-frame"))
             (:H2/BadPreface p)
             -> (note-event stat (conn-event:h2-error "bad-preface"))
             (:TLS/Alert kind what)
             -> (note-event stat (conn-event:tls-error (maybe:yes kind) what))
             (:TLS/Failed (maybe:yes desc))
             -> (note-event stat (conn-event:tls-error (maybe:yes desc) ""))
             (:TLS/Failed (maybe:no))
             -> (note-event stat (conn-event:tls-error (maybe:no) "fail/1"))
             (:OSError n)
             -> (note-event stat (conn-event:os-error (strerror n)))
             )
             except
             ;; anything else: close the socket (don't leak the fd), then
             ;;  let it go on to be logged as an unhandled exception.
             EXN -> (begin
                      (note-event stat (conn-event:os-error "exception (see log)"))
                      (sock.set-closed)
                      (sock.close)
                      (raise EXN)))
            (sock.set-closed)
            (sock.close))
          except
          (:TLS/Failed mdesc)
          -> (note-event stat (conn-event:tls-error mdesc "fail"))
          (:OSError n)
          -> (note-event stat (conn-event:os-error (strerror n)))
          )
         )))))

;; a listening socket on <ip>:<port>.  (separate from the accept loops,
;;  so that privileged ports can be bound before dropping root.)
;; --------------------------------------------------------------------------------
;; startup errors: an errno alone (2!) doesn't say what went wrong, so
;;  each step that opens something names it.

(define (startup-failed what)
  (logf what)
  (%exit #f 1))

;; open the log file <path> (for appending), or say why not and exit.
(define (open-log path)
  (try
   (file/open-append path #o644)
   except
   (:OSError n) -> (startup-failed (format "can't open the log " path ": " (strerror n)))))

(define (listen-on ip port)
  (let ((sock (doom/make (tcp4-sock)))
        (addr (address/make4 ip port)))
    (try
     (sock.bind addr)
     except
     (:OSError n) -> (startup-failed (format "can't listen on " (address/unparse addr) ": " (strerror n))))
    ;; a small backlog fails under a burst of connections: macOS (and
    ;;  FreeBSD) reset connections once the accept queue is full.
    (sock.listen SOMAXCONN)
    (debugf "listening on " (address/unparse addr) ", fd = " (int (sock.get-fd)) "\n")
    sock))

;; handler := (lambda (sockfun) ...)
(define (serve sock handler)
  (begin
    (let loop ()
      (debugf "accept wait...\n")
      (try
       (let (((sockfun addr) (sock.accept))
             (addr-string (address/unparse addr)))
         (debugf "client: addr " addr-string "\n")
         (handler addr-string sockfun)
         (loop))
       except (:OSError errno)
       -> (cond ((= errno ECONNABORTED) (loop))
                ;; out of file descriptors: back off for a moment, rather
                ;;  than leave the accept loop (which stops the server).
                ((or (= errno EMFILE) (= errno ENFILE))
                 (logf "accept: out of file descriptors (" (int errno) ")")
                 (timeq/sleep 100)
                 (loop))
                (else
                 (logf "OSError on accepting socket: " (int errno))))
       )
      )
    (logf "after accept loop.")
    ))

(define (read-certs path)
  (with-file file (file/open-read path)
    (let ((pgen (pem-read-gen (file-char-generator file)))
          (result '()))
      (for pem pgen
        (match pem with
          (:tuple "CERTIFICATE" asn1) -> (push! result asn1)
          _ -> (raise (:TLS/ExpectedCertificate path))
          ))
      (reverse result))))

(define key-matches?
  (skey:p256 sk)     (public-key:ec k _)     -> (string=? (p256-public-key sk) k)
  (skey:ed25519 sd)  (public-key:ed25519 pk) -> (let (((sk pk0) (ed25519-seed-to-keypair sd)))
                                                  (string=? pk0 pk))
  (skey:rsa r)       (public-key:rsa n e)    -> (big= r.n n)
  _ _ -> #f
  )

;; read <path> with (read path), turning whatever can go wrong into
;;  (:Serve/BadCreds why), with the path in <why>.
(define (read-cred read path)
  (try
   (read path)
   except
   (:OSError n) -> (raise (:Serve/BadCreds (format "can't read " path ": " (strerror n))))
   (:TLS/ExpectedCertificate _) -> (raise (:Serve/BadCreds (format path ": a PEM block that isn't a certificate")))
   (:SIG/NoPEMFound _) -> (raise (:Serve/BadCreds (format path ": no key in it")))
   (:SIG/UnexpectedPEM kind) -> (raise (:Serve/BadCreds (format path ": unexpected PEM block " kind)))))

;; the certificate chain and key, checking that they go together.  any
;;  problem raises (:Serve/BadCreds why).
(define (load-creds cert key)
  (let ((x509s (read-cred read-certs cert))
        (skey (read-cred read-skey key)))
    (when (null? x509s)
      (raise (:Serve/BadCreds (format "no certificates in " cert))))
    (let ((leaf (try
                 (parse-x509 (first x509s))
                 except
                 (:X509/Unexpected what _) -> (raise (:Serve/BadCreds (format cert ": can't parse the certificate (" what ")")))
                 (:X509/Unsupported what _) -> (raise (:Serve/BadCreds (format cert ": unsupported certificate (" what ")"))))))
      (when (not (key-matches? skey leaf.cert.pubkey.key))
        (raise (:Serve/BadCreds (format key " is not the key for " cert))))
      {x509s=x509s skey=skey})))

;; on SIGHUP, reopen the access log <log>, and reload <cert> and <key>
;;  into <creds>: new connections use them, existing ones carry on.  if
;;  they can't be loaded, keep the old.
(define (reload-on-sighup creds cert key log)
  ;; reopen the access log, for log rotation: newsyslog renames it and
  ;;  sends SIGHUP.  we may no longer be root, so newsyslog should create
  ;;  the new file owned by us (see README); if it can't be opened, keep
  ;;  writing to the old one.
  (define (reopen-log)
    (try
     (let ((new (file/open-append log #o644)))
       (when-maybe old *logfile*
         (file/flush old)
         (file/close old)
         #u)
       (set! *logfile* (maybe:yes new))
       (logf "SIGHUP: reopened " log))
     except
     (:OSError n) -> (logf "SIGHUP: can't reopen " log ": " (strerror n) ": keeping the old one")))
  (define (reload)
    (reopen-log)
    (try
     (let ((new (load-creds cert key)))
       (set! creds.x509s new.x509s)
       (set! creds.skey new.skey)
       (logf "SIGHUP: reloaded " cert " (" (int (length new.x509s)) " certs) and " key))
     except
     (:Serve/BadCreds why) -> (logf "SIGHUP: " why ": keeping the old ones")))
  (if poller/signals?
      (begin
        (signal/ignore SIGHUP)
        (poller/fork
         (lambda ()
           (let loop ()
             (poller/wait-for-signal SIGHUP)
             (reload)
             (loop)))))
      (logf "no SIGHUP reloading on this platform (yet)")))

;; -users: "name:password" lines; blank lines and #-comments are skipped.
;; (a users file that can't be read stops the server: it's only read at
;;  startup.)
(define (load-users path)
  (try
   (load-users* path)
   except
   (:OSError n) -> (startup-failed (format "can't read the users file " path ": " (strerror n)))))

(define (load-users* path)
  (let ((info (stat path))
        (users (tree/empty))
        (n 0))
    (when (not (= 0 (logand info.mode #o077)))
      (logf "warning: " path " can be read by others: chmod 600 it"))
    (with-file f (file/open-read path)
      (for-list line0 (file/read-lines f)
        (let ((line (string-trim-both line0))
              (colon (string-find ":" line)))
          (inc! n)
          (cond ((= 0 (string-length line)) #u)
                ((eq? (string-ref line 0) #\#) #u)
                ((< colon 1) (logf path ": line " (int n) " is not name:password"))
                (else
                 (tree/insert! users string-cmp
                               (substring line 0 colon)
                               (substring line (+ colon 1) (string-length line))))))))
    users))

(define *logfile* (maybe:no))
(define *stats* (make-server-history 1000))
(define *expires-delta* 3600) ;; for the Expires: header - one hour.

;; placeholder
(define (*dnscache* addr)
  "")

(define *start-time* (gettime/realtime))

