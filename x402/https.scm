;; -*- Mode: Irken -*-

;; one HTTPS request, over HTTP/1.1, for talking to a facilitator.
;;
;; this is doom/http/client.scm's https/request, without its HTTP/2
;;  support: doom/http/h2client.scm raises (:H2/BadFrame <string>)
;;  where the server side (doom/http/h2.scm) raises (:H2/BadFrame
;;  <frame>), and Irken's exceptions are one global type, so a program
;;  can't have both.  any HTTPS server speaks HTTP/1.1, so a server
;;  that uses this loses nothing.  (url/parse and resolve-host are
;;  copied from there too, for the same reason.)
;;
;; errors are reported as (:X402/HTTPS why).

(require "lib/net/dns.scm")
(require "lib/crypto/x509path.scm")
(require "doom/tls/client.scm")
(require "doom/http/h1client.scm")

(define (x402-https-failed why)
  (raise (:X402/HTTPS why)))

;; https://host[:port][/path] -> {host port path authority}
(define (x402/parse-url url)
  (if (not (starts-with url "https://"))
      (x402-https-failed (format "not an https:// URL: " url))
      (let ((rest (substring url 8 (string-length url)))
            (slash (string-find "/" rest))
            (hostport (if (= slash -1) rest (substring rest 0 slash)))
            (path (if (= slash -1) "/" (substring rest slash (string-length rest)))))
        (match (string-split hostport #\:) with
          (host)      -> {host=host port=443 path=path authority=host}
          (host port) -> {host=host port=(string->int port) path=path authority=hostport}
          _           -> (x402-https-failed (format "bad URL: " url))
          ))))

;; whitespace-separated fields of each line, without comments.
(define (x402-config-lines path)
  (if (isfile? path)
      (with-file f (file/open-read path)
        (let ((r (list:nil)))
          (for-list line (file/read-lines f)
            (push! r (filter (lambda (s) (> (string-length s) 0))
                             (string-split-ws (first (string-split line #\#))))))
          (reverse r)))
      (list:nil)))

(define (string-split-ws s)
  (let ((r (list:nil))
        (cur (list:nil)))
    (define (end-field)
      (when (not (null? cur))
        (push! r (list->string (reverse cur)))
        (set! cur (list:nil))))
    (for-string ch s
      (if (or (char=? ch #\space) (char=? ch #\tab) (char=? ch #\return) (char=? ch #\newline))
          (end-field)
          (push! cur ch)))
    (end-field)
    (reverse r)))

(define (x402-hosts-lookup host)
  (let loop ((lines (x402-config-lines "/etc/hosts")))
    (match lines with
      () -> (maybe:no)
      ((ip . names) . rest)
      -> (if (and (ipv4-literal? ip) (member? host names string=?))
             (maybe:yes ip)
             (loop rest))
      (_ . rest) -> (loop rest)
      )))

(define (x402-find-nameserver)
  (let loop ((lines (x402-config-lines "/etc/resolv.conf")))
    (match lines with
      () -> (x402-https-failed "no IPv4 nameserver in /etc/resolv.conf")
      (("nameserver" ip) . rest) -> (if (ipv4-literal? ip) ip (loop rest))
      (_ . rest) -> (loop rest)
      )))

(define (x402-dns-lookup host)
  (let ((sock (doom/make (udp4-sock) 4096 1024)))
    (sock.connect (address/make4 (x402-find-nameserver) 53))
    (sock.send (build-question 1 host (dnstype:a) dnsclass-in 1))
    (let (((header reply) (unpack-reply (sock.recv)))
          (r (maybe:no)))
      (sock.close)
      (for-list rr reply.an
        (match rr.data with
          (dnsrr:a bytes)
          -> (when (eq? r (maybe:no))
               (set! r (maybe:yes (format (join int->string "." (map char->int (vector->list bytes)))))))
          _ -> #u))
      r)))

;; host -> IPv4 address: a literal, /etc/hosts, or DNS.
(define (x402/resolve-host host)
  (if (ipv4-literal? host)
      host
      (match (x402-hosts-lookup host) with
        (maybe:yes ip) -> ip
        (maybe:no)
        -> (match (x402-dns-lookup host) with
             (maybe:yes ip) -> ip
             (maybe:no) -> (x402-https-failed (format "can't find an address for " host))
             ))))

;; trust anchors from <path>, or (if "") the system's bundle.
(define (x402/load-anchors path)
  (if (> (string-length path) 0)
      (x509-load-anchors path)
      (let loop ((paths x509-system-anchor-paths))
        (match paths with
          () -> (list:nil)
          (p . rest) -> (if (isfile? p) (x509-load-anchors p) (loop rest))))))

;; one request on its own connection: {status headers body}.
(define (x402/https-request method url headers body anchors)
  (let ((u (x402/parse-url url))
        (ip (x402/resolve-host u.host))
        (now (let ((t (gettime/realtime))) t.sec))
        (sock (doom/make (tcp4-sock))))
    (try
     (sock.connect (address/make4 ip u.port))
     except
     (:OSError n) -> (x402-https-failed (format "connecting to " u.authority ": " (strerror n))))
    (let ((tls (try
                (tls13/client sock u.host '("http/1.1")
                              (lambda (ders) (x509-verify-server ders anchors u.host now)))
                except
                (:TLS/ClientFailed why) -> (x402-https-failed (format "TLS with " u.authority ": " why))
                (:X509/Invalid why) -> (x402-https-failed (format "certificate of " u.authority ": " why))))
          (resp (try
                 (h1/request tls method u.authority u.path headers body)
                 except
                 (:H1/BadResponse what) -> (x402-https-failed (format "HTTP/1.1 from " u.authority ": " what))
                 (:Doom/EOF _) -> (x402-https-failed (format u.authority " closed the connection")))))
      (tls.close)
      resp)))
