;; -*- Mode: Irken -*-

;; x402/x402.scm, against the examples in the x402 spec
;;  (transports-v2/http.md).  run from the top of the tree:
;;
;;    $ irken x402/t-x402.scm && x402/t-x402
;;
;; and compare with the ";; =>" lines.

(require "x402/x402.scm")

;; the spec's terms and price.
(define terms {network="eip155:84532"
               asset="0x036CbD53842c5426634e7929541eC2318f3dCF7e"
               asset-name="USDC"
               asset-version="2"
               pay-to="0x209693Bc6afc0C5328bA36FaF03C514EF312287C"
               max-timeout=60})
(define price {prefix="/premium-data" amount="10000" description="Access to premium market data"})

;; our PAYMENT-REQUIRED header decodes to the spec's object, except
;;  that the spec's also gives a mimeType, which is optional.
(define required (x402/payment-required terms price "https://api.example.com/premium-data"
                                        "PAYMENT-SIGNATURE header is required"))
(printf (json->string required) "\n")
;; => {"x402Version":2,"error":"PAYMENT-SIGNATURE header is required","resource":{"url":"https://api.example.com/premium-data","description":"Access to premium market data"},"accepts":[{"scheme":"exact","network":"eip155:84532","amount":"10000","asset":"0x036CbD53842c5426634e7929541eC2318f3dCF7e","payTo":"0x209693Bc6afc0C5328bA36FaF03C514EF312287C","maxTimeoutSeconds":60,"extra":{"name":"USDC","version":"2"}}]}

;; and it round-trips through the header encoding.
(printf (bool (match (x402/header-decode (x402/header-encode required)) with
                (maybe:yes j) -> (string=? (json->string j) (json->string required))
                (maybe:no) -> #f))
        "\n")
;; => #t

;; the spec's PAYMENT-SIGNATURE example.
(define spec-signature "eyJ4NDAyVmVyc2lvbiI6MiwicmVzb3VyY2UiOnsidXJsIjoiaHR0cHM6Ly9hcGkuZXhhbXBsZS5jb20vcHJlbWl1bS1kYXRhIiwiZGVzY3JpcHRpb24iOiJBY2Nlc3MgdG8gcHJlbWl1bSBtYXJrZXQgZGF0YSIsIm1pbWVUeXBlIjoiYXBwbGljYXRpb24vanNvbiJ9LCJhY2NlcHRlZCI6eyJzY2hlbWUiOiJleGFjdCIsIm5ldHdvcmsiOiJlaXAxNTU6ODQ1MzIiLCJhbW91bnQiOiIxMDAwMCIsImFzc2V0IjoiMHgwMzZDYkQ1Mzg0MmM1NDI2NjM0ZTc5Mjk1NDFlQzIzMThmM2RDRjdlIiwicGF5VG8iOiIweDIwOTY5M0JjNmFmYzBDNTMyOGJBMzZGYUYwM0M1MTRFRjMxMjI4N0MiLCJtYXhUaW1lb3V0U2Vjb25kcyI6NjAsImV4dHJhIjp7Im5hbWUiOiJVU0RDIiwidmVyc2lvbiI6IjIifX0sInBheWxvYWQiOnsic2lnbmF0dXJlIjoiMHgyZDZhNzU4OGQ2YWNjYTUwNWNiZjBkOWE0YTIyN2UwYzUyYzZjMzQwMDhjOGU4OTg2YTEyODMyNTk3NjQxNzM2MDhhMmNlNjQ5NjY0MmUzNzdkNmRhOGRiYmY1ODM2ZTliZDE1MDkyZjllY2FiMDVkZWQzZDYyOTNhZjE0OGI1NzFjIiwiYXV0aG9yaXphdGlvbiI6eyJmcm9tIjoiMHg4NTdiMDY1MTlFOTFlM0E1NDUzODc5MWJEYmIwRTIyMzczZTM2YjY2IiwidG8iOiIweDIwOTY5M0JjNmFmYzBDNTMyOGJBMzZGYUYwM0M1MTRFRjMxMjI4N0MiLCJ2YWx1ZSI6IjEwMDAwIiwidmFsaWRBZnRlciI6IjE3NDA2NzIwODkiLCJ2YWxpZEJlZm9yZSI6IjE3NDA2NzIxNTQiLCJub25jZSI6IjB4ZjM3NDY2MTNjMmQ5MjBiNWZkYWJjMDg1NmYyYWViMmQ0Zjg4ZWU2MDM3YjhjYzVkMDRhNzFhNDQ2MmYxMzQ4MCJ9fX0=")

(define (pays? terms price header)
  (match (x402/header-decode header) with
    (maybe:yes payload) -> (if (x402/payment-matches? payload (x402/requirements terms price)) "pays" "doesn't match")
    (maybe:no) -> "undecodable"))

;; it pays our requirements; with the addresses in another case too.
(printf (pays? terms price spec-signature) "\n")
(printf (pays? {network=terms.network asset=(downcase terms.asset) asset-name="USDC" asset-version="2"
                pay-to=(downcase terms.pay-to) max-timeout=60}
               price spec-signature) "\n")
;; => pays
;; => pays

;; but not another amount, network or recipient.
(printf (pays? terms {prefix="/" amount="20000" description=""} spec-signature) "\n")
(printf (pays? {network="eip155:8453" asset=terms.asset asset-name="USDC" asset-version="2"
                pay-to=terms.pay-to max-timeout=60}
               price spec-signature) "\n")
(printf (pays? {network=terms.network asset=terms.asset asset-name="USDC" asset-version="2"
                pay-to="0x0000000000000000000000000000000000000001" max-timeout=60}
               price spec-signature) "\n")
;; => doesn't match
;; => doesn't match
;; => doesn't match

;; the payment's details, for the log.
(match (x402/header-decode spec-signature) with
  (maybe:yes payload)
  -> (match (json/get payload "payload") with
       (maybe:yes p) -> (match (json/get p "authorization") with
                          (maybe:yes a) -> (printf (json/get-string a "from") " " (json/get-string a "value") "\n")
                          _ -> (printf "no authorization\n"))
       _ -> (printf "no payload\n"))
  (maybe:no) -> (printf "undecodable\n"))
;; => 0x857b06519E91e3A54538791bDbb0E22373e36b66 10000

;; garbage: not base64, bad padding, base64 of non-JSON, a JSON
;;  array, empty, and too long.
(for-list h (list "!!!!" "eyJ" "eyJ4Ij=1" (b64-encode "hello there") (b64-encode "[1,2]") ""
                  (b64-encode (format "{\"x\":\"" (repeat 7000 "a") "\"}")))
  (printf (pays? terms price h) "\n"))
;; => undecodable
;; => undecodable
;; => undecodable
;; => undecodable
;; => undecodable
;; => undecodable
;; => undecodable

;; a valid payment with an empty object (as clients may send).
(printf (pays? terms price
               (b64-encode (format "{\"x402Version\":2,\"accepted\":" (json->string (x402/requirements terms price))
                                   ",\"payload\":{},\"extensions\":{}}")))
        "\n")
;; => pays

;; the settlement response from the spec's PAYMENT-RESPONSE example.
(match (x402/header-decode "eyJzdWNjZXNzIjp0cnVlLCJ0cmFuc2FjdGlvbiI6IjB4MTIzNDU2Nzg5MGFiY2RlZjEyMzQ1Njc4OTBhYmNkZWYxMjM0NTY3ODkwYWJjZGVmMTIzNDU2Nzg5MGFiY2RlZiIsIm5ldHdvcmsiOiJlaXAxNTU6ODQ1MzIiLCJwYXllciI6IjB4ODU3YjA2NTE5RTkxZTNBNTQ1Mzg3OTFiRGJiMEUyMjM3M2UzNmI2NiJ9") with
  (maybe:yes r) -> (printf (bool (x402/get-bool r "success")) " " (json/get-string r "transaction") "\n")
  (maybe:no) -> (printf "undecodable\n"))
;; => #t 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
