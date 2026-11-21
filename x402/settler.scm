;; -*- Mode: Irken -*-

;; settlers: who checks and settles x402 payments.
;;
;; a settler is a record of two functions, each given the client's
;;  PaymentPayload and our PaymentRequirements (both JSON):
;;
;;   verify: is this a good payment?  nothing moves yet.
;;   settle: move the money.  done just before the resource is sent.
;;
;; the only settler so far is a facilitator (x402/facilitator, below),
;;  a service that does both over HTTPS.  settling on-chain ourselves
;;  would be another settler with the same two functions.

(require "x402/x402.scm")
(require "x402/https.scm")

(datatype x402-verified
  (:ok string)        ;; a good payment, from this payer
  (:invalid string)   ;; a bad one, for this reason (an x402 error code)
  (:failed string)    ;; we couldn't find out: why
  )

(datatype x402-settled
  (:ok json)          ;; settled: the SettlementResponse
  (:refused json)     ;; not settled: the SettlementResponse says why
  (:failed string)    ;; we couldn't find out: why
  )

;; --- facilitators ---
;;
;; POST <url>/verify and <url>/settle, each with
;;  {"x402Version": 2, "paymentPayload": ..., "paymentRequirements": ...}.
;;  verify answers a VerifyResponse ({"isValid": ..., "invalidReason":
;;  ..., "payer": ...}), settle a SettlementResponse ({"success": ...,
;;  "errorReason": ..., "transaction": ..., "network": ..., "payer":
;;  ...}).  some facilitators answer a refusal with a 4xx status, so
;;  the body is believed whatever the status, if it's one of these.
;;
;; <anchors> are the certificates trusted for the facilitator's
;;  server: the system's roots, or (for testing) its own certificate.

;; the facilitator may compress its answer.
(define (x402-decode-body resp)
  (match (lookup-header "content-encoding" resp.headers) with
    (maybe:no) -> resp.body
    (maybe:yes "identity") -> resp.body
    (maybe:yes other) -> (raise (:X402/Facilitator (format "answered with content-encoding " other)))))

;; POST <body> to <url>: (:tuple status (maybe json)), or raises
;;  (:X402/Facilitator why).
(define (x402-post url body anchors)
  (let ((resp (try
               (x402/https-request "POST" url
                                   (list (:tuple "content-type" "application/json")
                                         (:tuple "accept" "application/json")
                                         (:tuple "user-agent" "irken-h2d"))
                                   body anchors)
               except
               (:X402/HTTPS why) -> (raise (:X402/Facilitator why))
               (:OSError n) -> (raise (:X402/Facilitator (strerror n))))))
    (:tuple resp.status
            (try
             (maybe:yes (x402-json-parse (x402-decode-body resp)))
             except
             (:NoParse _) -> (maybe:no)))))

(define (x402-describe-failure status body)
  (format "facilitator answered " status
          (match body with
            (maybe:yes j) -> (format ": " (json->string j))
            (maybe:no) -> " (not JSON)")))

(define (x402/facilitator url anchors)

  (define (request-body payload requirements)
    (json->string
     (json:obj (list (:tuple "x402Version" (json:number X402-VERSION))
                     (:tuple "paymentPayload" payload)
                     (:tuple "paymentRequirements" requirements)))))

  (define (verify payload requirements)
    (try
     (match (x402-post (format url "/verify") (request-body payload requirements) anchors) with
       (:tuple status (maybe:yes j))
       -> (match (json/get j "isValid") with
            (maybe:yes (json:bool #t)) -> (x402-verified:ok (json/get-string j "payer"))
            (maybe:yes (json:bool #f)) -> (x402-verified:invalid (let ((r (json/get-string j "invalidReason")))
                                                                   (if (= 0 (string-length r)) "invalid_payload" r)))
            _ -> (x402-verified:failed (x402-describe-failure status (maybe:yes j))))
       (:tuple status (maybe:no))
       -> (x402-verified:failed (x402-describe-failure status (maybe:no))))
     except
     (:X402/Facilitator why) -> (x402-verified:failed why)))

  (define (settle payload requirements)
    (try
     (match (x402-post (format url "/settle") (request-body payload requirements) anchors) with
       (:tuple status (maybe:yes j))
       -> (match (json/get j "success") with
            (maybe:yes (json:bool #t)) -> (x402-settled:ok j)
            (maybe:yes (json:bool #f)) -> (x402-settled:refused j)
            _ -> (x402-settled:failed (x402-describe-failure status (maybe:yes j))))
       (:tuple status (maybe:no))
       -> (x402-settled:failed (x402-describe-failure status (maybe:no))))
     except
     (:X402/Facilitator why) -> (x402-settled:failed why)))

  {verify=verify settle=settle name=(format "facilitator " url)})
