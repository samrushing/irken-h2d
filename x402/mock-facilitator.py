# -*- Mode: Python -*-

# a pretend x402 facilitator, for testing: /verify and /settle (and
#   /supported) over HTTPS, with no blockchain.  it checks what it can
#   without one: the version, that the authorization pays the
#   requirements (recipient and amount), its time window, and that its
#   nonce hasn't been settled before.  the signature is NOT checked.
#
# two payer addresses act out failures:
#   0x...dead  has no money: verify says insufficient_funds.
#   0x...beef  passes verify, but settling fails (insufficient_funds),
#              as if the money left between the two.
#
# answers are gzipped when the client accepts that, so that its
#   decompressing them is tested too.
#
#   python3 x402/mock-facilitator.py -port 4402 -cert fac.pem -key fac-key.pem
#
# see x402/test-e2e.py, which runs it.

import sys
import ssl
import gzip
import json
import time
import argparse
import http.server

POOR = '0x000000000000000000000000000000000000dead'
FICKLE = '0x000000000000000000000000000000000000beef'

settled = set()   # nonces
log = []

def check (body):
    """-> (payer, reason): reason is '' for a good payment."""
    if body.get ('x402Version') != 2:
        return '', 'invalid_x402_version'
    payload = body.get ('paymentPayload') or {}
    req = body.get ('paymentRequirements') or {}
    auth = (payload.get ('payload') or {}).get ('authorization') or {}
    payer = auth.get ('from', '')
    if not auth or not payload.get ('payload', {}).get ('signature'):
        return payer, 'invalid_payload'
    if req.get ('scheme') != 'exact':
        return payer, 'unsupported_scheme'
    if auth.get ('to', '').lower() != req.get ('payTo', '').lower():
        return payer, 'invalid_exact_evm_payload_recipient_mismatch'
    if auth.get ('value') != req.get ('amount'):
        return payer, 'invalid_exact_evm_payload_authorization_value_mismatch'
    now = int (time.time())
    if int (auth.get ('validBefore', 0)) < now + 6:
        return payer, 'invalid_exact_evm_payload_authorization_valid_before'
    if int (auth.get ('validAfter', 0)) > now:
        return payer, 'invalid_exact_evm_payload_authorization_valid_after'
    if auth.get ('nonce') in settled:
        return payer, 'invalid_transaction_state'
    if payer.lower() == POOR:
        return payer, 'insufficient_funds'
    return payer, ''

class Handler (http.server.BaseHTTPRequestHandler):

    def answer (self, status, ob):
        data = json.dumps (ob).encode()
        self.gzipped = 'gzip' in self.headers.get ('accept-encoding', '')
        self.send_response (status)
        self.send_header ('content-type', 'application/json')
        if self.gzipped:
            data = gzip.compress (data)
            self.send_header ('content-encoding', 'gzip')
        self.send_header ('content-length', str (len (data)))
        self.end_headers()
        self.wfile.write (data)

    def do_GET (self):
        if self.path == '/supported':
            self.answer (200, {'kinds': [{'x402Version': 2, 'scheme': 'exact', 'network': 'eip155:84532'}],
                               'extensions': [], 'signers': {}})
        else:
            self.answer (404, {})

    def do_POST (self):
        try:
            body = json.loads (self.rfile.read (int (self.headers.get ('content-length', 0))))
        except ValueError:
            return self.answer (400, {'isValid': False, 'invalidReason': 'invalid_payload'})
        payer, reason = check (body)
        network = (body.get ('paymentRequirements') or {}).get ('network', '')
        if self.path == '/verify':
            if reason:
                self.answer (400, {'isValid': False, 'invalidReason': reason, 'payer': payer})
            else:
                self.answer (200, {'isValid': True, 'payer': payer})
        elif self.path == '/settle':
            if not reason and payer.lower() == FICKLE:
                reason = 'insufficient_funds'
            if reason:
                self.answer (400, {'success': False, 'errorReason': reason, 'payer': payer,
                                   'transaction': '', 'network': network})
            else:
                auth = body['paymentPayload']['payload']['authorization']
                settled.add (auth['nonce'])
                tx = '0x' + ('%064x' % (len (settled)))
                self.answer (200, {'success': True, 'payer': payer, 'transaction': tx, 'network': network})
        else:
            return self.answer (404, {})
        print ('mock-facilitator: %s %s -> %s%s' % (self.path, payer, reason or 'ok',
                                                    ' (gzipped)' if self.gzipped else ''), flush=True)

    def log_message (self, *args):
        pass

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument ('-port', type=int, default=4402)
    ap.add_argument ('-cert', required=True)
    ap.add_argument ('-key', required=True)
    args = ap.parse_args()
    ctx = ssl.SSLContext (ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain (args.cert, args.key)
    server = http.server.HTTPServer (('127.0.0.1', args.port), Handler)
    server.socket = ctx.wrap_socket (server.socket, server_side=True)
    print ('mock-facilitator: listening on 127.0.0.1:%d' % (args.port,), flush=True)
    server.serve_forever()

if __name__ == '__main__':
    main()
