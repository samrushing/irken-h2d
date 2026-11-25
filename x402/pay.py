# -*- Mode: Python -*-

# a small x402 (v2) client, for paying irken-h2d with real (testnet)
#   money: it asks for a page, reads the 402, signs exactly the payment
#   asked for (an EIP-3009 USDC authorization, EIP-712 signed), asks
#   again with it, and shows what came back.  it also makes throwaway
#   wallets and shows their USDC balances.
#
#   python3 x402/pay.py new-wallet payer          # ~/.x402-test/payer.key
#   python3 x402/pay.py address payer
#   python3 x402/pay.py balance payer             # or an 0x address
#   python3 x402/pay.py get https://localhost:4433/premium/x.html -key payer -k
#
# -k skips checking the server's certificate (for a local test server);
#   -cacert <pem> checks it against <pem> instead.  -dry-run signs and
#   shows the payment without sending it.
#
# needs: pip install eth-account "httpx[http2]"   (irken-h2d speaks only HTTP/2)
#
# FOR TESTNETS AND THROWAWAY KEYS ONLY: keys are kept unencrypted, in
#   ~/.x402-test/<name>.key (mode 0600).

import os
import sys
import json
import time
import base64
import secrets
import argparse

import httpx
from eth_account import Account
from eth_account.messages import encode_typed_data

KEYDIR = os.path.expanduser ('~/.x402-test')

# public Base Sepolia RPC, and USDC there, for `balance`.
RPC = {'eip155:84532': 'https://sepolia.base.org'}
USDC = {'eip155:84532': '0x036CbD53842c5426634e7929541eC2318f3dCF7e'}
EXPLORER = {'eip155:84532': 'https://sepolia.basescan.org/tx/'}

def die (msg):
    sys.exit ('pay.py: ' + msg)

# --- wallets ---

def key_path (name):
    return name if os.sep in name else os.path.join (KEYDIR, name + '.key')

def load_account (name):
    path = key_path (name)
    if not os.path.isfile (path):
        die ('no key %s: make one with "pay.py new-wallet %s"' % (path, name))
    return Account.from_key (open (path).read().strip())

def new_wallet (name):
    path = key_path (name)
    if os.path.exists (path):
        die ('%s exists: not overwriting it' % (path,))
    os.makedirs (os.path.dirname (path), mode=0o700, exist_ok=True)
    acct = Account.create()
    fd = os.open (path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write (fd, (acct.key.hex() if acct.key.hex().startswith ('0x') else '0x' + acct.key.hex()).encode() + b'\n')
    os.close (fd)
    print ('%s  (key in %s)' % (acct.address, path))

def address_of (who):
    return who if who.startswith ('0x') and len (who) == 42 else load_account (who).address

def balance (who, network='eip155:84532'):
    addr = address_of (who)
    data = '0x70a08231' + addr[2:].lower().rjust (64, '0')     # balanceOf(address)
    try:
        r = httpx.post (RPC[network], json={'jsonrpc': '2.0', 'id': 1, 'method': 'eth_call',
                                            'params': [{'to': USDC[network], 'data': data}, 'latest']}, timeout=20)
        r.raise_for_status()
        units = int (r.json()['result'], 16)
    except (httpx.HTTPError, KeyError, ValueError) as e:
        die ('asking %s for the balance: %s' % (RPC[network], e))
    print ('%s: %d.%06d USDC  (%d units) on %s' % (addr, units // 10**6, units % 10**6, units, network))

# --- paying ---

def b64json (s):
    return json.loads (base64.b64decode (s))

def sign_authorization (acct, req):
    """an EIP-3009 TransferWithAuthorization paying exactly <req>."""
    if req.get ('scheme') != 'exact' or not req.get ('network', '').startswith ('eip155:'):
        die ('only the "exact" scheme on EVM networks is supported: %r' % (req,))
    now = int (time.time())
    auth = {'from': acct.address, 'to': req['payTo'], 'value': req['amount'],
            'validAfter': str (now - 600),                                  # allow for clock skew
            'validBefore': str (now + int (req.get ('maxTimeoutSeconds', 60))),
            'nonce': '0x' + secrets.token_hex (32)}
    domain = {'name': req['extra']['name'], 'version': req['extra']['version'],
              'chainId': int (req['network'].split (':')[1]), 'verifyingContract': req['asset']}
    types = {'TransferWithAuthorization': [
        {'name': 'from', 'type': 'address'}, {'name': 'to', 'type': 'address'},
        {'name': 'value', 'type': 'uint256'}, {'name': 'validAfter', 'type': 'uint256'},
        {'name': 'validBefore', 'type': 'uint256'}, {'name': 'nonce', 'type': 'bytes32'}]}
    msg = {'from': auth['from'], 'to': auth['to'], 'value': int (auth['value']),
           'validAfter': int (auth['validAfter']), 'validBefore': int (auth['validBefore']),
           'nonce': bytes.fromhex (auth['nonce'][2:])}
    signable = encode_typed_data (domain_data=domain, message_types=types, message_data=msg)
    sig = acct.sign_message (signable).signature.hex()
    sig = sig if sig.startswith ('0x') else '0x' + sig
    # check it before anyone else does.
    if Account.recover_message (signable, signature=sig) != acct.address:
        die ('the signature does not recover to %s' % (acct.address,))
    return {'signature': sig, 'authorization': auth}

def show_headers (r):
    print ('HTTP/%s %d' % (r.http_version.split ('/')[-1], r.status_code))
    for k, v in r.headers.items():
        if k.startswith ('payment-'):
            print ('  %s: %s' % (k, json.dumps (b64json (v), indent=2).replace ('\n', '\n  ')))
        else:
            print ('  %s: %s' % (k, v))

def get (url, keyname, verify, dry_run):
    acct = load_account (keyname)
    print ('paying from %s' % (acct.address,))
    with httpx.Client (http2=True, verify=verify, timeout=120) as c:
        print ('\n--- asking for %s' % (url,))
        try:
            r = c.get (url)
        except httpx.HTTPError as e:
            die ('asking for %s: %s' % (url, e))
        show_headers (r)
        if r.status_code != 402:
            print ('\n(not a 402: nothing to pay)')
            print (r.text[:2000])
            return
        if 'payment-required' not in r.headers:
            die ('a 402 without PAYMENT-REQUIRED')
        required = b64json (r.headers['payment-required'])
        offers = [a for a in required.get ('accepts', []) if a.get ('scheme') == 'exact' and a.get ('network', '').startswith ('eip155:')]
        if not offers:
            die ('nothing offered that this client can pay: %r' % (required.get ('accepts'),))
        req = offers[0]
        print ('\n--- paying %s units of %s to %s on %s' % (req['amount'], req['asset'], req['payTo'], req['network']))
        payload = {'x402Version': 2, 'resource': required.get ('resource'), 'accepted': req,
                   'payload': sign_authorization (acct, req)}
        header = base64.b64encode (json.dumps (payload, separators=(',', ':')).encode()).decode()
        if dry_run:
            print (json.dumps (payload, indent=2))
            print ('\n(dry run: not sent)')
            return
        print ('\n--- asking again, with the payment (settling can take a few seconds)')
        t0 = time.time()
        try:
            r = c.get (url, headers={'payment-signature': header})
        except httpx.HTTPError as e:
            die ('asking again for %s: %s' % (url, e))
        print ('(%.1f s)' % (time.time() - t0,))
        show_headers (r)
        print ()
        print (r.text[:2000])
        if 'payment-response' in r.headers:
            resp = b64json (r.headers['payment-response'])
            tx = resp.get ('transaction', '')
            if resp.get ('success') and tx and resp.get ('network') in EXPLORER:
                print ('\ntransaction: %s%s' % (EXPLORER[resp['network']], tx))

def main():
    ap = argparse.ArgumentParser (description='pay for a page with x402 (testnets only)')
    sub = ap.add_subparsers (dest='cmd', required=True)
    p = sub.add_parser ('new-wallet', help='make a throwaway wallet'); p.add_argument ('name')
    p = sub.add_parser ('address', help='show a wallet\'s address'); p.add_argument ('name')
    p = sub.add_parser ('balance', help='USDC balance on Base Sepolia'); p.add_argument ('who', help='a wallet name or an 0x address')
    p = sub.add_parser ('get', help='get a page, paying if asked')
    p.add_argument ('url'); p.add_argument ('-key', required=True, help='the paying wallet')
    p.add_argument ('-k', action='store_true', help="don't check the server's certificate")
    p.add_argument ('-cacert', help='check it against this PEM file instead')
    p.add_argument ('-dry-run', action='store_true', help='sign and show the payment, but don\'t send it')
    a = ap.parse_args()
    if a.cmd == 'new-wallet':
        new_wallet (a.name)
    elif a.cmd == 'address':
        print (load_account (a.name).address)
    elif a.cmd == 'balance':
        balance (a.who)
    else:
        get (a.url, a.key, False if a.k else (a.cacert or True), a.dry_run)

if __name__ == '__main__':
    main()
