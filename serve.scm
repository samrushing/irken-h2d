;; -*- Mode: Irken -*-

;;
;; goal: a bog-standard GET handler with file listing for a directory.
;;
;; source: stripped-down from the demo/maze handler.
;;
;; question: can we list a directory?
;;      yes: os/listdir.  gives type/name, no stat data.

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
(define (listen-on ip port)
  (let ((sock (doom/make (tcp4-sock)))
        (addr (address/make4 ip port)))
    (sock.bind addr)
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

;; the certificate chain and key, checking that they go together.
(define (load-creds cert key)
  (let ((x509s (read-certs cert))
        (skey (read-skey key)))
    (when (null? x509s)
      (raise (:Serve/BadCreds (format "no certificates in " cert))))
    (let ((leaf (parse-x509 (first x509s))))
      (when (not (key-matches? skey leaf.cert.pubkey.key))
        (raise (:Serve/BadCreds (format key " is not the key for " cert))))
      {x509s=x509s skey=skey})))

;; on SIGHUP, reload <cert> and <key> into <creds>: new connections use
;;  them, existing ones carry on.  if they can't be loaded, keep the old.
;; on SIGHUP, reload <cert> and <key> into <creds>: new connections use
;;  them, existing ones carry on.  if they can't be loaded, keep the old.
(define (reload-on-sighup creds cert key)
  (define (reload)
    (try
     (let ((new (load-creds cert key)))
       (set! creds.x509s new.x509s)
       (set! creds.skey new.skey)
       (logf "SIGHUP: reloaded " cert " (" (int (length new.x509s)) " certs) and " key))
     except
     (:Serve/BadCreds why) -> (logf "SIGHUP: " why ": keeping the old ones")
     (:OSError n) -> (logf "SIGHUP: " (strerror n) ": keeping the old ones")
     (:TLS/ExpectedCertificate path) -> (logf "SIGHUP: unexpected PEM in " path ": keeping the old ones")
     (:SIG/NoPEMFound path) -> (logf "SIGHUP: no key in " path ": keeping the old ones")
     (:SIG/UnexpectedPEM kind) -> (logf "SIGHUP: unexpected PEM " kind ": keeping the old ones")
     (:X509/Unexpected what _) -> (logf "SIGHUP: can't parse the certificate (" what "): keeping the old ones")
     (:X509/Unsupported what _) -> (logf "SIGHUP: unsupported certificate (" what "): keeping the old ones")))
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
(define (load-users path)
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

(define program-options
  (makeopt
   (arg 'root (string "/var/local/www/data"))
   (arg 'cert (string "cert.pem"))
   (arg 'key  (string "key.pem"))
   (arg 'log  (string "/var/log/irken-httpd.log"))
   (arg 'acme (string ""))
   (arg 'users (string ""))
   (arg 'user (string ""))
   (flag 'd)
   (arg 'http (int 80))
   (flag 'r)
   (pos 'addr (string "127.0.0.1:4433"))
   (flag 'h)
   ))

(define (get-options)
  (if (< sys.argc 2)
      (usage)
      (try
       (process-options program-options (rest (vector->list sys.argv)))
       except
       (:Getopt/MissingArg _ _) -> (usage)
       (:Getopt/UnknownArg _ _) -> (usage)
       )))

(define (usage)
  (printf "HTTP/2 TLS-1.3 file server.\n\n")
  (printf "Usage: " sys.argv[0] " <addr>\n"
          "  [-root = /var/local/www/data\n"
          "  [-cert = cert.pem]\n"
          "  [-key = key.pem]\n"
          "  [-log = /var/log/irken-httpd.log]\n"
          "  [-r] disable redirect (301 Moved Permanently) on port 80\n"
          "  [-acme <dir>] on port 80, answer ACME http-01 challenges\n"
          "     (/.well-known/acme-challenge/<token>) from <dir>/<token>\n"
          "  [-http <port>] use <port> instead of 80 for redirects & challenges\n"
          "  [-users <file>] users for /status (basic auth): name:password lines.\n"
          "     without it, /status is disabled.\n"
          "  [-user <name>] after binding the ports, run as this user\n"
          "     (start as root to bind ports 80 and 443)\n"
          "  [-d] print debugging output\n"
          "  [-h] print this usage.\n"
          "\n"
          " note: the root filesystem is expected to be of the form:\n"
          "      /var/www/root/hostname0/index.html\n"
          "      /var/www/root/hostname1/index.html\n"
          "   where each <hostname> is the FQDN/authority for that site.\n"
          "\n"
          "example: $ " sys.argv[0] " 127.0.0.1:4433 -root /var/www/root/\n"
          "\n"
          )
  (%exit #f -1))

(define (split-addr addr)
  (match (string-split addr #\:) with
    (ip port) -> (:tuple ip (string->int port))
    (ip)      -> (:tuple ip 443)
    _         -> (usage)
    ))

;; placeholder
(define (*dnscache* addr)
  "")

(define *start-time* (gettime/realtime))

(define (main)
  (let ((opts (get-options))
        (addr "127.0.0.1:4433")
        (root "/var/local/www/data")
        (cert "cert.pem")
        (key  "key.pem")
        (redirect? #t)
        (acme-dir (maybe:no))
        (http-port 80)
        (log  "/var/log/irken-httpd.log")
        (users (maybe:no))
        (user (maybe:no)))
    (when-maybe v (get-bool-opt opts 'h) (usage))
    (when-maybe v (get-bool-opt opts 'r) (set! redirect? #f))
    (when-maybe v (get-string-opt opts 'root) (set! root v))
    (when-maybe v (get-string-opt opts 'cert) (set! cert v))
    (when-maybe v (get-string-opt opts 'key)  (set! key v))
    (when-maybe v (get-string-opt opts 'log)  (set! log v))
    (when-maybe v (get-string-opt opts 'addr) (set! addr v))
    (when-maybe v (get-string-opt opts 'acme) (when (> (string-length v) 0) (set! acme-dir (maybe:yes v))))
    (when-maybe v (get-int-opt opts 'http) (set! http-port v))
    (when-maybe v (get-string-opt opts 'users) (when (> (string-length v) 0) (set! users (maybe:yes v))))
    (when-maybe v (get-string-opt opts 'user) (when (> (string-length v) 0) (set! user (maybe:yes v))))
    (set! *debugf* #f)
    (when-maybe v (get-bool-opt opts 'd) (set! *debugf* v))
    ;; the runtime's GC messages (on stderr, so also in syslog) too.
    (set-verbose-gc *debugf*)
    (set! *dnscache* (dnscache/make "127.0.0.1" 1000))

    (let ((creds (try
                  (load-creds cert key)
                  except
                  (:Serve/BadCreds why) -> (begin (printf why "\n") (%exit #f 1))))
          ((ip port) (split-addr addr))
          (status (match users with
                    (maybe:yes path)
                    -> (list (basic-auth-wrapper (load-users path) "status" "/status" (status-handler addr opts)))
                    (maybe:no)
                    -> (begin (logf "no -users: /status is disabled") (list:nil))))
          (handler (h2-handler
                    (multi-handler
                     (append status
                             (list favicon-handler
                                   (host-handler root))))))
          ;;(handler (h2-handler (host-handler root)))
          )
      (set! *logfile* (maybe:yes (file/open-append log #o644)))
      (logf "read " (int (length creds.x509s)) " certs from " cert)
      (debugf "redirect? " (bool redirect?) "\n")
      (let ((main-sock (listen-on ip port))
            (http-sock (if (or redirect? (not (eq? acme-dir (maybe:no))))
                           (maybe:yes (listen-on ip http-port))
                           (maybe:no))))
        (logf "listening on " addr
              (match http-sock with
                (maybe:yes _) -> (format " and port " (int http-port))
                (maybe:no) -> ""))
        ;; the ports are bound, and the log file and certificates
        ;;  read: give up root.
        (when-maybe name user
          (try
           (begin
             (drop-privileges name)
             (logf "running as " name))
           except
           (:OSError e) -> (begin (logf "can't run as " name ": " (strerror e)) (%exit #f 1))
           (:Posix/NoSuchUser _) -> (begin (logf "no such user: " name) (%exit #f 1))
           (:Posix/StillRoot _) -> (begin (logf "still root after becoming " name) (%exit #f 1))))
        (when-maybe sock http-sock
          (poller/fork (lambda () (serve-redirect sock acme-dir))))
        (reload-on-sighup creds cert key)
        (serve main-sock (h2-channel handler creds '("h2"))))
      (poller/wait-and-schedule))))

;; don't let SIGPIPE take down the server.
(signal/ignore SIGPIPE)
(main)
(printf "after main.\n")
