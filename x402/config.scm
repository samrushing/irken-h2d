;; -*- Mode: Irken -*-

;; the x402 configuration file (serve -x402 <file>): what we charge
;;  for, in what, to whom, and who settles.  see x402/x402.conf.example.
;;
;;   facilitator       https://x402.org/facilitator
;;   facilitator-root  <pem>   (optional: trust only these certificates
;;                              for the facilitator, e.g. a test one's own)
;;   network           eip155:84532
;;   asset             0x036CbD53842c5426634e7929541eC2318f3dCF7e
;;   asset-name        USDC
;;   asset-version     2
;;   pay-to            0x...
;;   max-timeout       60
;;   price  <path-prefix>  <amount>  <description...>
;;
;; '#' starts a comment.  there may be any number of price lines;
;;  the longest matching prefix wins.

(require "x402/settler.scm")

(define (x402-config-error what)
  (raise (:X402/BadConfig what)))

;; 0x and 40 hex digits.
(define (x402/address? s)
  (and (= 42 (string-length s))
       (string=? "0x" (substring s 0 2))
       (all? hex-digit? (string->list (substring s 2 42)))))

(define (x402/amount? s)
  (and (> (string-length s) 0)
       (all? digit? (string->list s))
       (not (all? (lambda (ch) (char=? ch #\0)) (string->list s)))))

;; -> {terms prices settler}
(define (x402/load-config path)
  (when (not (isfile? path))
    (x402-config-error (format "no such file: " path)))
  (let ((settings (tree/empty))
        (prices (list:nil)))
    (for-list line (config-lines path)
      (match line with
        () -> #u
        ("price" prefix amount . description)
        -> (begin
             (when (not (string=? "/" (substring prefix 0 1)))
               (x402-config-error (format "price: the prefix must start with /: " prefix)))
             (when (not (x402/amount? amount))
               (x402-config-error (format "price: the amount must be a positive number of the token's atomic units: " amount)))
             (push! prices {prefix=prefix amount=amount description=(string-join description " ")}))
        (key value)
        -> (tree/insert! settings string-compare key value)
        _ -> (x402-config-error (format "can't read this line: " (string-join line " ")))))
    (define (get key)
      (match (tree/member settings string-compare key) with
        (maybe:yes v) -> v
        (maybe:no) -> (x402-config-error (format "missing: " key))))
    (define (get-or key default)
      (match (tree/member settings string-compare key) with
        (maybe:yes v) -> v
        (maybe:no) -> default))
    (when (null? prices)
      (x402-config-error "no price lines: nothing would be charged for"))
    (let ((facilitator (get "facilitator"))
          (root (get-or "facilitator-root" ""))
          (network (get "network"))
          (asset (get "asset"))
          (pay-to (get "pay-to"))
          (timeout (string->int (get-or "max-timeout" "60"))))
      (when (not (string=? "https://" (substring facilitator 0 (min 8 (string-length facilitator)))))
        (x402-config-error (format "facilitator: must be an https:// URL: " facilitator)))
      (when (not (string=? "eip155:" (substring network 0 (min 7 (string-length network)))))
        (x402-config-error (format "network: only EVM networks (eip155:<chain id>) are supported: " network)))
      (when (not (x402/address? asset))
        (x402-config-error (format "asset: not an address: " asset)))
      (when (not (x402/address? pay-to))
        (x402-config-error (format "pay-to: not an address: " pay-to)))
      (when (and (> (string-length root) 0) (not (isfile? root)))
        (x402-config-error (format "facilitator-root: no such file: " root)))
      (let ((anchors (try
                      (load-trust-anchors root)
                      except
                      (:HTTPS/Failed why) -> (x402-config-error (format "facilitator certificates: " why)))))
        (when (null? anchors)
          (x402-config-error (format "no trusted certificates for the facilitator in "
                                     (if (> (string-length root) 0) root "the system's bundle"))))
        {terms={network=network asset=asset asset-name=(get "asset-name") asset-version=(get "asset-version")
                pay-to=pay-to max-timeout=timeout}
         ;; longest prefix first.
         prices=(sort (lambda (a b) (> (string-length a.prefix) (string-length b.prefix))) prices)
         settler=(x402/facilitator facilitator anchors)}))))
