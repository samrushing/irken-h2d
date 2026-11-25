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

This needs an Irken with two fixes:

* `lib/json.scm` parses empty objects (`{}`), which x402 clients send.  (In
  irken-compiler's master since `a2d7755`.)
* the HTTP/2 server and client agree on the type of `:H2/BadFrame` (a
  string), so that one program can have both: irken-h2d serves HTTP/2 and
  makes HTTPS requests to the facilitator.  (irken-compiler's
  `h2-bad-frame-reason` branch, until it's merged.)  Without it, `serve.scm`
  fails to compile with `type error: string vs. {type=H2-FRAME ...}`.

Then build `serve.scm` as usual.

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
* `settler.scm`: settlers, and the facilitator client (over Irken's
  `doom/http/client.scm`).
* `config.scm`: reading the configuration.
* `handler.scm`: the handler that charges for priced paths.
* `t-x402.scm`: tests of `x402.scm` against the spec's examples.
* `mock-facilitator.py`, `test-e2e.py`: an end-to-end test (below).
* `pay.py`: a small client that pays (below).

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

## Paying for real (testnet)

`pay.py` is a small x402 client: it asks for a page, reads the 402, signs
exactly the payment asked for (a USDC `transferWithAuthorization`, EIP-712
signed), and asks again with it.  It speaks HTTP/2, as irken-h2d must be
spoken to, and makes throwaway wallets.  For testnets and throwaway keys only:
keys are kept unencrypted in `~/.x402-test/<name>.key` (mode 0600).

    $ pip install eth-account "httpx[http2]"

1. Two wallets: one to be paid, one to pay.

       $ python3 x402/pay.py new-wallet payee
       $ python3 x402/pay.py new-wallet payer

2. Test USDC for the payer, from https://faucet.circle.com (Base Sepolia).
   The payer needs no ETH: the facilitator submits the transfer and pays the
   gas.  Check with `python3 x402/pay.py balance payer`.

3. A configuration: `x402.conf.example`, with `pay-to` set to the payee's
   address (`python3 x402/pay.py address payee`) and a small price (say
   `1000`, 0.001 USDC).  The facilitator is `https://x402.org/facilitator`,
   which is free and needs no key, and runs on Base Sepolia.

4. Run the server (any certificate for localhost will do) and pay:

       $ ./serve 127.0.0.1:4433 -root <www> -cert <cert> -key <key> -r -log x402.log -x402 x402.conf
       $ python3 x402/pay.py get https://localhost:4433/premium/<page> -key payer -k

   The page is `<www>/localhost/premium/<page>`: under `-root`, a
   directory per host name.  `-r` and `-log` keep the server off port 80
   and out of /var/log.  `-k` doesn't check the server's certificate; `-cacert <pem>` checks it
   against a file.  `-dry-run` signs and shows the payment without sending
   it.  The answer's `PAYMENT-RESPONSE` names the transaction, with a link to
   it on sepolia.basescan.org; the balances (`balance payer`, `balance
   payee`) move by the price.

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
