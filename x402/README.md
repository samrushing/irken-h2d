# x402 payments

`x402/serve`, a version of irken-h2d's `serve`, charges for parts of a site with [x402](https://www.x402.org)
(version 2): HTTP 402 Payment Required, paid in a stablecoin such as USDC on
an EVM chain.  A client asks for a priced page, gets a 402 saying what to
pay, signs a payment, and asks again with it; the server has the payment
verified and settled, then serves the page.

Payments go straight from the payer to your `pay-to` address.  The server
holds no key and no money: verifying and settling are done by a
*facilitator*, a service the server calls.  (Settling on-chain without one is
planned; see "Settlers" below.)

## Building

`x402/serve.scm` is `serve.scm` with `-x402` added, a program of its own (like
`photos/` and `source/`) so that plain `serve` has none of the x402 code.  Its
`main` is a copy of `serve.scm`'s: a change to one should go in the other.
From the top of the tree:

    $ irken x402/serve.scm

which makes `x402/serve`.  It needs an irken-compiler from after November
2026 (master has the fixes it needs: `{}` in `lib/json.scm`, and one type for
`:H2/BadFrame` so a program can be both an HTTP/2 server and an HTTPS
client).

## Running

    $ x402/serve 0.0.0.0:443 -root /var/www/data -cert ... -key ... -x402 /usr/local/etc/x402.conf

It takes all of `serve`'s options; `-x402` is required.

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
* `settler.scm`: settlers, and the facilitator client (over Irken's
  `doom/http/client.scm`).
* `config.scm`: reading the configuration.
* `handler.scm`: the handler that charges for priced paths.
* `t-x402.scm`: tests of `x402.scm` against the spec's examples.
* `mock-facilitator.py`, `test-e2e.py`: an end-to-end test (below).
* `pay.py`: a small client that pays (below).
* `MANUAL-TESTING.md`: paying for real (testnet), step by step.

## Settlers

A settler is a record of two functions, `verify` and `settle`.  The
facilitator is one; settling on-chain ourselves would be another, needing
secp256k1 and keccak-256 (in irken-compiler), EIP-712 hashing, transaction
signing, and a JSON-RPC client for an Ethereum node.

## Testing

    $ irken x402/t-x402.scm && x402/t-x402      # compare with the ";; =>" lines
    $ python3 x402/test-e2e.py x402/serve

`test-e2e.py` runs `x402/serve` with a price on `/premium/`, against
`mock-facilitator.py` (which checks everything but the signature, and has no
blockchain), and uses curl to check: the 402, payments that work, are
replayed, are for the wrong amount or address, are malformed, or fail at
verify or at settle; paths that try to get around the price; that a 404 isn't
charged; and that the server copes without the facilitator.  It needs
python3, openssl, and a curl with HTTP/2.

## Paying for real (testnet)

`pay.py` is a small x402 client: it asks for a page, reads the 402, signs
exactly the payment asked for (a USDC `transferWithAuthorization`, EIP-712
signed), and asks again with it, over HTTP/2.  It also makes throwaway wallets
and shows their USDC balances.  `MANUAL-TESTING.md` says how to use it to pay
irken-h2d with real testnet money, step by step.

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
