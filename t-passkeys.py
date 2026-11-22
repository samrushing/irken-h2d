# End-to-end test of irken-h2d's passkey login, with Chromium's virtual
# authenticator (needs playwright, and curl with HTTP/2).
#
# usage: python3 t-passkeys.py <serve-binary> <workdir> <pki-dir>
#   <pki-dir> holds chain.pem and leaf.p8 (a cert for localhost) and
#   root.pem (its CA).  <workdir> gets the users/passkeys files and logs.
#   on Linux there's no SIGHUP reloading, so the test restarts the
#   server where an admin would reload it.
import base64, json, os, re, signal, ssl, subprocess, sys, time, urllib.request
from playwright.sync_api import sync_playwright

SERVE, WORK = sys.argv[1], sys.argv[2]
PKI = sys.argv[3]
BASE = 'https://localhost:4433'
PASSKEYS = os.path.join(WORK, 'passkeys')
USERS = os.path.join(WORK, 'users')
open(USERS, 'w').write('admin:s3cr:et\n'); os.chmod(USERS, 0o600)
open(PASSKEYS, 'w').write('# passkeys\n')
os.makedirs(os.path.join(WORK, 'www', 'localhost'), exist_ok=True)
open(os.path.join(WORK, 'www', 'localhost', 'index.html'), 'w').write('hello\n')

results = []
def check(name, ok, detail=''):
    results.append(ok)
    print(('ok   ' if ok else 'FAIL ') + name + (('   [' + detail + ']') if detail and not ok else ''), flush=True)

server = None
def start():
    global server, out
    out = open(os.path.join(WORK, 'serve.out'), 'w')
    server = subprocess.Popen([SERVE, '-http', '5080', '-root', os.path.join(WORK, 'www'),
                               '-cert', os.path.join(PKI, 'chain.pem'), '-key', os.path.join(PKI, 'leaf.p8'),
                               '-log', os.path.join(WORK, 'access.log'),
                               '-users', USERS, '-passkeys', PASSKEYS, '127.0.0.1:4433'],
                              stdout=out, stderr=subprocess.STDOUT)
    for _ in range(50):
        time.sleep(0.2)
        m = re.search(r'/login/enroll/([A-Za-z0-9_-]+)', open(os.path.join(WORK, 'serve.out')).read())
        if m: return m.group(1)
    raise SystemExit('no enroll token in the log:\n' + open(os.path.join(WORK, 'serve.out')).read())

def stop():
    server.terminate(); server.wait()

def http(path, method='GET', headers={}, body=None):
    # the server speaks only h2: use curl.
    cmd = ['curl', '-s', '--http2', '--cacert', os.path.join(PKI, 'root.pem'), '-X', method,
           '-D', '/tmp/e2e.hdr', '-o', '/tmp/e2e.body', '-w', '%{http_code}']
    for k, v in headers.items(): cmd += ['-H', '%s: %s' % (k, v)]
    if body is not None: cmd += ['--data-binary', '@-']
    st = int(subprocess.run(cmd + [BASE + path], input=body, capture_output=True).stdout or 0)
    hdrs = {}
    for l in open('/tmp/e2e.hdr', encoding='latin1').read().splitlines()[1:]:
        if ':' in l:
            k, v = l.split(':', 1); hdrs[k.strip().lower()] = v.strip()
    return st, hdrs, open('/tmp/e2e.body', 'rb').read()
basic = {'authorization': 'Basic ' + base64.b64encode(b'admin:s3cr:et').decode()}

token = start()
with sync_playwright() as p:
    browser = p.chromium.launch(args=['--ignore-certificate-errors'])
    context = browser.new_context(ignore_https_errors=True)
    page = context.new_page()
    cdp = context.new_cdp_session(page)
    cdp.send('WebAuthn.enable')
    auth = cdp.send('WebAuthn.addVirtualAuthenticator', {'options': {
        'protocol': 'ctap2', 'transport': 'internal', 'hasResidentKey': True,
        'hasUserVerification': True, 'isUserVerified': True, 'automaticPresenceSimulation': True}})
    bodies = {}
    page.on('request', lambda r: bodies.__setitem__(r.url.split('4433')[1], r.post_data) if r.method == 'POST' else None)

    # --- not logged in: a page request goes to /login/
    page.goto(BASE + '/status/')
    check('browser without a session is sent to /login/', page.url.startswith(BASE + '/login/?next=/status/'), page.url)

    # --- enroll
    page.goto(BASE + '/login/enroll/' + token)
    page.fill('#name', 'sam')
    page.click('#go')
    page.wait_for_selector('#line', state='visible', timeout=15000)
    line = page.text_content('#line')
    check('enrollment shows a passkeys line', re.fullmatch(r'sam [A-Za-z0-9_-]+ [A-Za-z0-9_-]+', line or '') is not None, repr(line))
    check('enrollment names the passkeys file', page.text_content('#file') == PASSKEYS)
    creds = cdp.send('WebAuthn.getCredentials', {'authenticatorId': auth['authenticatorId']})['credentials']
    check('the authenticator holds one discoverable credential', len(creds) == 1 and creds[0]['isResidentCredential'])
    check('credential id in the line matches', base64.urlsafe_b64encode(base64.b64decode(creds[0]['credentialId'])).rstrip(b'=').decode() == line.split()[1])
    # the link is single-use
    page.goto(BASE + '/login/enroll/' + token)
    check('enroll link is single-use', 'expired or been used' in page.content())
    st, _, _ = http('/login/enroll/' + token + '/begin', 'POST', {'content-type': 'application/json'}, b'{"name":"x"}')
    check('used enroll link refuses begin', st == 404, str(st))

    # --- not in the file yet: login is refused
    page.goto(BASE + '/login/?next=/status/')
    page.click('#go')
    page.wait_for_function("document.getElementById('msg').textContent.length > 0", timeout=15000)
    check('passkey not yet in the file is refused', 'login failed' in page.text_content('#msg'), page.text_content('#msg'))

    # --- add it (as the admin would), restart (no SIGHUP on Linux), log in
    open(PASSKEYS, 'a').write(line + '\n')
    stop(); token2 = start()
    check('a new enroll token after restart', token2 != token)
    page.goto(BASE + '/status/')
    page.click('#go')
    page.wait_for_url(BASE + '/status/', timeout=15000)
    check('passkey login lands on the page asked for', page.url == BASE + '/status/', page.url)
    check('status page shows', 'href="addrs/"' in page.content())
    cookie = [c for c in context.cookies() if c['name'] == 'h2d-session']
    check('session cookie is Secure, HttpOnly, Lax', len(cookie) == 1 and cookie[0]['secure'] and cookie[0]['httpOnly'] and cookie[0]['sameSite'] == 'Lax', str(cookie))
    page.goto(BASE + '/status/addrs/')
    check('the session works for other pages', page.url == BASE + '/status/addrs/' and 'addr' in page.content())

    # --- replaying the browser's login POST: refused (challenge used up)
    st, _, b = http('/login/finish', 'POST', {'content-type': 'application/json'}, bodies['/login/finish'].encode())
    check('replayed assertion is refused', st == 403, '%d %r' % (st, b))
    # tampered: right challenge structure but a forged signature
    fin = json.loads(bodies['/login/finish'])
    st, _, ch = http('/login/begin', 'POST', {'content-type': 'application/json'}, b'{}')
    fin['signature'] = fin['signature'][:-4] + ('AAAA' if not fin['signature'].endswith('AAAA') else 'BBBB')
    st, _, b = http('/login/finish', 'POST', {'content-type': 'application/json'}, json.dumps(fin).encode())
    check('reused challenge with a changed signature is refused', st == 403, '%d %r' % (st, b))
    st, _, b = http('/login/finish', 'POST', {'content-type': 'application/json'}, b'{"id": 3, nope')
    check('malformed JSON is a 400', st == 400, '%d %r' % (st, b))
    st, _, b = http('/login/finish', 'POST', {'content-type': 'application/json'}, b'{}')
    check('empty login is refused', st == 403, '%d %r' % (st, b))
    # wrong origin: log in from a page whose origin isn't the server's
    st, _, _ = http('/status/', 'GET', {'cookie': 'h2d-session=forged'})
    check('forged cookie is a 401', st == 401, str(st))

    # --- logout
    page.goto(BASE + '/login/logout')
    page.goto(BASE + '/status/')
    check('after logout, back to /login/', page.url.startswith(BASE + '/login/'), page.url)
    st, _, _ = http('/status/', 'GET', {'cookie': 'h2d-session=' + cookie[0]['value']})
    check('the old session cookie no longer works', st == 401, str(st))

    # --- the password fallback
    st, h, _ = http('/status/')
    check('curl without credentials: 401 with a basic challenge', st == 401 and 'Basic' in h.get('www-authenticate', ''), str(st))
    st, _, b = http('/status/', 'GET', basic)
    check('curl with a password still works', st == 200 and b'href="addrs/"' in b, str(st))
    st, h, _ = http('/login/password?next=%2Fstatus%2Faddrs%2F', 'GET', basic)
    check('/login/password sets a session and redirects', st == 302 and h.get('location') == '/status/addrs/' and 'h2d-session=' in h.get('set-cookie', ''), '%d %r' % (st, h))
    st, h, _ = http('/login/password?next=https%3A%2F%2Fevil.example%2F', 'GET', basic)
    check('next= can\'t leave the site', st == 302 and h.get('location') == '/', h.get('location'))
    st, h, _ = http('/login/password?next=%2F%2Fevil.example%2F', 'GET', basic)
    check('next= can\'t be //host', st == 302 and h.get('location') == '/', h.get('location'))
    st, _, _ = http('/status/gc', 'GET', dict(basic, **{'sec-fetch-site': 'cross-site'}))
    check('cross-site gc still refused', st == 403, str(st))
    browser.close()

stop()
log = open(os.path.join(WORK, 'serve.out')).read()
check('server logged the login', 'login: sam (passkey)' in log)
# (thread 1 is the DNS cache: nothing answers on 127.0.0.1:53 here.)
others = [b for b in log.split('unhandled exception in thread: ')[1:] if not (b.startswith('1\n') and '{u6 111}' in b)]
check('no unhandled exceptions (besides the DNS cache)', not others, repr(others)[:500])
print('%d/%d passed' % (sum(results), len(results)))
