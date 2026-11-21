# x402 payments

irken-h2d can charge for parts of a site with [x402](https://www.x402.org)
(version 2): HTTP 402 Payment Required, paid in a stablecoin such as USDC on
an EVM chain.  A client asks for a priced page, gets a 402 saying what to
pay, signs a payment, and asks again with it; the server has the payment
verified and settled, then serves the page.

Payments go straight from the payer to your `pay-to` address.  The server
holds no key and no money: verifying and settling are done by a
*facilitator*, a service the server calls.  (Settling on-chain without one is
planned; see "Settlers" below.)

## Building

This needs an Irken whose `lib/json.scm` parses empty objects (`{}`), which
x402 clients send: irken-compiler's `mburr/json-empty-object` branch, until
that's merged.  Then build `serve.scm` as usual.

## Running

    $ serve 0.0.0.0:443 -root /var/www/data -cert ... -key ... -x402 /usr/local/etc/x402.conf

See `x402.conf.example`.  The configuration is checked at startup, and the
server won't start if anything is missing or malformed.  It names:

* `facilitator`: its URL (https only).  `facilitator-root` optionally names a
  PEM file of certificates to trust for it instead of the system's roots.
* `network`, `asset`, `asset-name`, `asset-version`: the chain (as CAIP-2,
  e.g. `eip155:84532` for Base Sepolia) and the token: its contract address
  and its EIP-712 domain name and version (`USDC`, `2` for Circle's USDC).
* `pay-to`: the address payments go to.
* `max-timeout`: seconds a client has to pay (default 60).
* `price <path prefix> <amount> <description>`: any number of these.  Amounts
  are in the token's smallest units (USDC has 6 decimals, so `10000` is 0.01
  USDC).  The longest matching prefix wins.

Each payment is logged: `x402: paid <amount> for <path> by <payer>,
transaction <hash>`.

## What happens to a request

For a path with a price:

| the request | the answer |
|---|---|
| no `PAYMENT-SIGNATURE` | 402, with `PAYMENT-REQUIRED` (and the same JSON as the body) |
| a malformed one | 400 |
| a payment for something other than what we offer, or one the facilitator refuses | 402, with the reason as the `error` in `PAYMENT-REQUIRED` |
| a good payment | whatever the site answers; see below |
| the facilitator can't be reached | 500, and logged |

The payment is settled only when the site is about to send a 200: then the
200 goes out with `PAYMENT-RESPONSE` (the transaction).  If settling fails,
a 402 with `PAYMENT-RESPONSE` saying why goes out instead, and no content.
Anything else (a 404, a 304) goes out unchanged, and nothing is charged.

Prices are matched against the path as it will be served, after `%`-decoding
and removing `.` and `..`, so `/%70remium/x` and `/free/../premium/x` cost the
same as `/premium/x`.

## Files

* `x402.scm`: the protocol's messages and headers.
* `settler.scm`: settlers, and the facilitator client.
* `https.scm`: the HTTPS (HTTP/1.1) requests the facilitator client makes.
* `config.scm`: reading the configuration.
* `handler.scm`: the handler that charges for priced paths.
* `t-x402.scm`: tests of `x402.scm` against the spec's examples.
* `mock-facilitator.py`, `test-e2e.py`: an end-to-end test (below).

## Settlers

A settler is a record of two functions, `verify` and `settle`.  The
facilitator is one; settling on-chain ourselves would be another, needing
secp256k1 and keccak-256 (in irken-compiler), EIP-712 hashing, transaction
signing, and a JSON-RPC client for an Ethereum node.

## Testing

    $ irken x402/t-x402.scm && x402/t-x402      # compare with the ";; =>" lines
    $ python3 x402/test-e2e.py ./serve

`test-e2e.py` runs `serve` with a price on `/premium/`, against
`mock-facilitator.py` (which checks everything but the signature, and has no
blockchain), and uses curl to check: the 402, payments that work, are
replayed, are for the wrong amount or address, are malformed, or fail at
verify or at settle; paths that try to get around the price; that a 404 isn't
charged; and that the server copes without the facilitator.  It needs
python3, openssl, and a curl with HTTP/2.

## Not done yet

* **HTTP/1.1 clients can't connect.**  irken-h2d speaks only HTTP/2, and some
  x402 clients (Node's `fetch`, Python's `requests`) speak only HTTP/1.1.
  Python's `httpx` with `http2=True`, and browsers, are fine.
* **Responses are deflated whether or not the client asks** (an irken-h2d
  bug, not x402's), so a client must accept `deflate`.  Most do.
* **No CORS headers**, which browser clients on other origins need (see the
  spec's `transports-v2/http.md`).
* **Facilitators that need an API key aren't supported.**
* **No timeout** on facilitator requests: a facilitator that hangs holds
  that request.
* **One network and token**, and prices apply to every host the server
  serves.
* **v1 clients** (the `X-PAYMENT` header) aren't supported.
