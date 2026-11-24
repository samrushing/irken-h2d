;; -*- Mode: Irken -*-

;; logging in: with a passkey (WebAuthn), or with a password (basic auth,
;;  the -users file) as a fallback.  either one gets you a session cookie.
;;
;; - passkeys are lines in the -passkeys file, "name credential-id key"
;;   (both base64url).  the server only reads it (at startup and on
;;   SIGHUP): a new passkey is added by whoever runs the server, who
;;   pastes in the line the enroll page shows.
;; - the enroll page is /login/enroll/<token>: the server logs a fresh
;;   token at startup and on each SIGHUP, good for one enrollment within
;;   an hour.  (a leaked one is no use by itself: the passkey it makes
;;   does nothing until its line is in the file.)
;; - sessions live in memory (a restart logs everyone out), for a week.
;;
;; passkeys are for the site's registrable domain (e.g. nightmare.com,
;;  for www.nightmare.com and dark.nightmare.com too): see rp-id-for.

(require "lib/crypto/webauthn.scm")

(define login-session-seconds (* 7 24 3600))
(define login-challenge-seconds 300)
(define login-enroll-seconds 3600)
(define login-max-challenges 1000)
(define login-max-sessions 1000)
(define login-cookie "h2d-session")

(define (login-now-seconds)
  (let ((ts (gettime/monotonic)))
    ts.sec))

(define *login-rng* (urandom-make))

(define (login-digit-char? ch) (let ((n (char->int ch))) (and (>= n 48) (<= n 57))))
(define (login-alpha-char? ch) (let ((n (char->int ch))) (or (and (>= n 65) (<= n 90)) (and (>= n 97) (<= n 122)))))

(define (login-random-bytes n) (*login-rng* n))

;; --------------------------------------------------------------------------------
;; the passkeys file

;; credential id (raw) => {name key count}
(define (load-passkeys path)
  (let ((creds (tree/empty))
        (n 0))
    (with-file f (file/open-read path)
      (for-list line0 (file/read-lines f)
        (let ((line (string-trim-both line0)))
          (inc! n)
          (cond ((= 0 (string-length line)) #u)
                ((eq? (string-ref line 0) #\#) #u)
                (else
                 (match (filter (lambda (s) (> (string-length s) 0)) (string-split line #\space)) with
                   (name id64 key64)
                   -> (try
                       (let ((key (webauthn/cose-key (cbor/decode (b64url-decode key64)))))
                         (tree/insert! creds string-compare (b64url-decode id64) {name=name key=key count=0}))
                       except
                       (:WebAuthn/Failed why) -> (logf path ": line " (int n) ": " why)
                       (:CBOR/Bad why _) -> (logf path ": line " (int n) ": bad key: " why))
                   _ -> (logf path ": line " (int n) " is not \"name credential-id key\"")))))))
    creds))

(define (login-count-passkeys creds)
  (let ((n 0))
    (for-map k v creds (inc! n))
    n))

;; --------------------------------------------------------------------------------
;; the login state

(define (login/make users-path passkeys-path)
  (let ((self {users     = (match users-path with
                             (maybe:yes path) -> (maybe:yes (load-users path))
                             (maybe:no) -> (maybe:no))
               passkeys  = passkeys-path
               creds     = (tree/empty)
               sessions  = (tree/empty)
               nsessions = 0
               challenges = (tree/empty)    ;; raw challenge => {kind expires}
               nchallenges = 0
               enroll-token = ""            ;; "" once used
               enroll-expires = 0
               }))
    (login/reload! self #f)
    self))

(define (login-enabled? self) (not (eq? self.passkeys (maybe:no))))

;; (re)read the passkeys file and log a new enroll link.  at startup a
;;  missing or unreadable file stops the server; on SIGHUP the old
;;  passkeys are kept.
(define (login/reload! self sighup?)
  (when-maybe path self.passkeys
    (try
     (let ((creds (load-passkeys path)))
       (set! self.creds creds)
       (logf (if sighup? "SIGHUP: " "") "read " (int (login-count-passkeys creds)) " passkeys from " path))
     except
     (:OSError n)
     -> (if sighup?
            (logf "SIGHUP: can't read " path ": " (strerror n) ": keeping the old passkeys")
            (startup-failed (format "can't read the passkeys file " path ": " (strerror n)))))
    (set! self.enroll-token (b64url-encode (login-random-bytes 18)))
    (set! self.enroll-expires (+ (login-now-seconds) login-enroll-seconds))
    (logf "to add a passkey (once, within the hour): https://<host>/login/enroll/" self.enroll-token)))

;; forget expired challenges and sessions.
(define (login-prune! self)
  (let ((now (login-now-seconds))
        (old (list:nil)))
    (for-map k v self.challenges
      (when (< v.expires now) (push! old k)))
    (for-list k old
      (tree/delete! self.challenges string-compare k)
      (dec! self.nchallenges))
    (set! old (list:nil))
    (for-map k v self.sessions
      (when (< v.expires now) (push! old k)))
    (for-list k old
      (tree/delete! self.sessions string-compare k)
      (dec! self.nsessions))))

;; a new challenge, for a login or an enrollment ('login or 'enroll).
(define (login-new-challenge! self kind)
  (when (>= self.nchallenges login-max-challenges)
    (login-prune! self))
  (if (>= self.nchallenges login-max-challenges)
      (maybe:no)
      (let ((ch (login-random-bytes 32)))
        (tree/insert! self.challenges string-compare ch {kind=kind expires=(+ (login-now-seconds) login-challenge-seconds)})
        (inc! self.nchallenges)
        (maybe:yes ch))))

;; use up challenge <ch> (of <kind>): #t if we handed it out, it's
;;  still good, and it's not been used.
(define (login-take-challenge! self ch kind)
  (match (tree/member self.challenges string-compare ch) with
    (maybe:yes c)
    -> (begin
         (tree/delete! self.challenges string-compare ch)
         (dec! self.nchallenges)
         (and (eq? c.kind kind) (>= c.expires (login-now-seconds))))
    (maybe:no) -> #f))

;; a new session for <name>: its cookie value.
(define (login-new-session! self name)
  (when (>= self.nsessions login-max-sessions)
    (login-prune! self))
  (let ((token (b64url-encode (login-random-bytes 32))))
    (tree/insert! self.sessions string-compare token {name=name expires=(+ (login-now-seconds) login-session-seconds)})
    (inc! self.nsessions)
    token))

;; --------------------------------------------------------------------------------
;; requests

;; the value of cookie <name>.  (h2 may split cookies over several
;;  cookie headers.)
(define (login-request-cookie request name)
  (let ((prefix (format name "="))
        (r (maybe:no)))
    (for-list hdr request.headers
      (match hdr with
        (:tuple "cookie" val)
        -> (for-list part (string-split val #\;)
             (let ((p (string-trim-both part)))
               (when (starts-with p prefix)
                 (set! r (maybe:yes (substring p (string-length prefix) (string-length p)))))))
        _ -> #u))
    r))

(define (login-session-user self request)
  (match (login-request-cookie request login-cookie) with
    (maybe:yes token)
    -> (match (tree/member self.sessions string-compare token) with
         (maybe:yes s) -> (if (>= s.expires (login-now-seconds)) (maybe:yes s.name) (maybe:no))
         (maybe:no) -> (maybe:no))
    (maybe:no) -> (maybe:no)))

(define (login-user self request)
  (match (login-session-user self request) with
    (maybe:yes name) -> (maybe:yes name)
    (maybe:no) -> (match self.users with
                    (maybe:yes users) -> (basic-auth-user users request)
                    (maybe:no) -> (maybe:no))))

;; host and port, as the browser sees them.
(define (login-request-authority request)
  (match (lookup-header ":authority" request.headers) with
    (maybe:yes a) -> a
    (maybe:no) -> "localhost"))

(define (login-request-host request)
  (car (string-split (login-request-authority request) #\:)))

;; the relying party id for <host>: its last two labels (nightmare.com
;;  for dark.nightmare.com), so one passkey works across a domain's
;;  hosts; an address, or a name of one or two labels, as it is.  (not
;;  right for the likes of example.co.uk.)
(define (rp-id-for host)
  (let ((labels (string-split host #\.)))
    (if (or (<= (length labels) 2)
            (every? (lambda (l) (every? login-digit-char? (string->list l))) labels))
        host
        (string-join (list (nth labels (- (length labels) 2)) (last labels)) "."))))

;; split :path into path and query.
(define (login-path-and-query request)
  (let ((full (match (lookup-header ":path" request.headers) with (maybe:yes p) -> p (maybe:no) -> "/"))
        (q (string-find "?" full)))
    (if (< q 0)
        (:tuple full "")
        (:tuple (substring full 0 q) (substring full (+ q 1) (string-length full))))))

;; where to go after logging in: a path on this site, or "/".
(define (login-next query)
  (let ((r "/"))
    (for-list part (string-split query #\&)
      (when (starts-with part "next=")
        (match (decode-hex (string-replace-all (substring part 5 (string-length part)) "+" " ")) with
          (maybe:yes p)
          -> (when (and (starts-with p "/") (not (starts-with p "//")) (< (string-find "\\" p) 0))
               (set! r p))
          (maybe:no) -> #u)))
    r))

(define (login-query-escape s)
  (let ((out (list:nil)))
    (for-string ch s
      (let ((n (char->int ch)))
        (push! out (if (or (and (>= n 48) (<= n 57)) (and (>= n 65) (<= n 90)) (and (>= n 97) (<= n 122))
                           (member? ch (string->list "-._~/") eq?))
                       (char->string ch)
                       (format "%" (zpad 2 (hex n)))))))
    (string-concat (reverse out))))

;; a JSON string, safe inside <script> too.
(define (login-js-string s)
  (let ((out (list:nil)))
    (for-string ch s
      (let ((n (char->int ch)))
        (push! out (if (or (< n 32) (= n 34) (= n 92) (= n 60) (= n 62) (= n 38) (= n 39))
                       (format "\\u00" (zpad 2 (hex n)))
                       (char->string ch)))))
    (format "\"" (string-concat (reverse out)) "\"")))

(define login-no-store (:tuple "cache-control" "no-store"))

(define (login-send request status type headers body)
  (request.send-headers status
                        (append (list (:tuple "content-type" type)
                                      (:tuple "content-length" (int->string (string-length body)))
                                      login-no-store)
                                headers)
                        (> (string-length body) 0))
  (when (> (string-length body) 0)
    (request.send-data body #t)))

(define (login-send-json request status body)
  (login-send request status "application/json" (list:nil) body))

(define (login-send-text request status body)
  (login-send request status "text/plain; charset=utf-8" (list:nil) (format body "\n")))

(define (login-send-page request status title body)
  (login-send request status "text/html; charset=utf-8" (list:nil) (login-page title body)))

(define (login-session-cookie token max-age)
  (:tuple "set-cookie"
          (format login-cookie "=" token "; Path=/; Max-Age=" (int max-age) "; Secure; HttpOnly; SameSite=Lax")))

;; the request's JSON body (an object), or raise Login/BadRequest.
(define (login-json-body request)
  (try
   (webauthn/parse-json (request.recv-body))
   except
   (:WebAuthn/Failed _) -> (raise (:Login/BadRequest "malformed JSON"))
   (:H2/BodyTooLarge _) -> (raise (:Login/BadRequest "too large"))))

(define (login-json-b64 members key)
  (b64url-decode (webauthn/json-string members key)))

(define (login-addr-of request)
  (let ((info (request.get-info)))
    info.addr))

;; --------------------------------------------------------------------------------
;; logging in

(define (handle-login-begin self request)
  (match (login-new-challenge! self 'login) with
    (maybe:yes ch)
    -> (login-send-json request "200" (format "{\"challenge\":" (login-js-string (b64url-encode ch))
                                        ",\"rpId\":" (login-js-string (rp-id-for (login-request-host request))) "}"))
    (maybe:no) -> (login-send-text request "503" "too many logins in progress: try again in a few minutes")))

(define (handle-login-finish self request)
  (let ((body (login-json-body request))
        (id (login-json-b64 body "id"))
        (cdj (login-json-b64 body "clientDataJSON"))
        (ad (login-json-b64 body "authenticatorData"))
        (sig (login-json-b64 body "signature"))
        (rp (rp-id-for (login-request-host request)))
        (origin (format "https://" (login-request-authority request))))
    (define (refuse why)
      (logf "login refused from " (login-addr-of request) ": " why)
      (login-send-text request "403" "login failed"))
    (match (tree/member self.creds string-compare id) with
      (maybe:no) -> (refuse "unknown passkey (not in the passkeys file?)")
      (maybe:yes cred)
      -> (try
          (if (not (login-take-challenge! self (webauthn/client-challenge cdj) 'login))
              (refuse "unknown or stale challenge")
              (let ((count (webauthn/verify-assertion rp origin (webauthn/client-challenge cdj) cdj ad sig cred.key)))
                ;; a counter that goes backwards: a cloned authenticator.
                ;;  (passkeys that sync keep theirs at 0.)
                (if (and (> count 0) (<= count cred.count))
                    (refuse (format "signature counter went from " (int cred.count) " to " (int count)))
                    (begin
                      (set! cred.count count)
                      (logf "login: " cred.name " (passkey) from " (login-addr-of request))
                      (login-send request "200" "application/json"
                                  (list (login-session-cookie (login-new-session! self cred.name) login-session-seconds))
                                  "{\"ok\":true}")))))
          except
          (:WebAuthn/Failed why) -> (refuse why)))))

;; with a password: basic auth on this one URL, then a session.
(define (handle-login-password self request query)
  (match (login-user self request) self.users with
    (maybe:yes name) _
    -> (begin
         (when (eq? (login-session-user self request) (maybe:no))
           (logf "login: " name " (password) from " (login-addr-of request)))
         (request.send-headers "302" (list (:tuple "location" (login-next query))
                                           (login-session-cookie (login-new-session! self name) login-session-seconds)
                                           login-no-store)
                               #f))
    (maybe:no) (maybe:yes _)
    -> (request.send-headers "401" (list (:tuple "www-authenticate" "Basic realm=\"login\"") login-no-store) #f)
    (maybe:no) (maybe:no)
    -> (login-send-text request "404" "no password logins here")))

(define (handle-logout self request)
  (when-maybe token (login-request-cookie request login-cookie)
    (tree/delete!? self.sessions string-compare token)
    #u)
  (login-send request "200" "text/html; charset=utf-8"
              (list (login-session-cookie "" 0))
              (login-page "logged out" "<p>You're logged out. <a href=\"/login/\">Log in again</a>.</p>")))

;; --------------------------------------------------------------------------------
;; enrolling a passkey

(define (login-enroll-token-ok? self token)
  (and (> (string-length self.enroll-token) 0)
       (string=? token self.enroll-token)
       (>= self.enroll-expires (login-now-seconds))))

(define (login-valid-name? name)
  (and (> (string-length name) 0)
       (<= (string-length name) 64)
       (every? (lambda (ch) (or (login-alpha-char? ch) (login-digit-char? ch) (member? ch (string->list "._@-") eq?)))
               (string->list name))))

(define (handle-enroll-begin self request)
  (let ((body (login-json-body request))
        (name (webauthn/json-string body "name")))
    (if (not (login-valid-name? name))
        (login-send-text request "400" "a name is letters, digits and ._@- (up to 64)")
        (match (login-new-challenge! self 'enroll) with
          (maybe:yes ch)
          -> (login-send-json request "200"
                        (format "{\"challenge\":" (login-js-string (b64url-encode ch))
                                ",\"rpId\":" (login-js-string (rp-id-for (login-request-host request)))
                                ",\"userId\":" (login-js-string (b64url-encode (login-random-bytes 16)))
                                ",\"name\":" (login-js-string name)
                                ",\"exclude\":[" (join (lambda (id) (login-js-string (b64url-encode id))) "," (tree/keys self.creds)) "]}"))
          (maybe:no) -> (login-send-text request "503" "too many logins in progress: try again in a few minutes")))))

(define (handle-enroll-finish self request)
  (let ((body (login-json-body request))
        (name (webauthn/json-string body "name"))
        (cdj (login-json-b64 body "clientDataJSON"))
        (ao (login-json-b64 body "attestationObject"))
        (rp (rp-id-for (login-request-host request)))
        (origin (format "https://" (login-request-authority request))))
    (define (refuse why)
      (logf "passkey enrollment refused from " (login-addr-of request) ": " why)
      (login-send-text request "403" (format "enrollment failed: " why)))
    (cond ((not (login-valid-name? name)) (refuse "bad name"))
          (else
           (try
            (if (not (login-take-challenge! self (webauthn/client-challenge cdj) 'enroll))
                (refuse "unknown or stale challenge")
                (let ((cred (webauthn/verify-registration rp origin (webauthn/client-challenge cdj) cdj ao))
                      (line (format name " " (b64url-encode cred.id) " " (b64url-encode cred.raw))))
                  ;; the link is used up.
                  (set! self.enroll-token "")
                  (logf "passkey enrolled for " name " from " (login-addr-of request) " (add its line to the passkeys file)")
                  (login-send-json request "200" (format "{\"line\":" (login-js-string line)
                                                   ",\"file\":" (login-js-string (match self.passkeys with (maybe:yes p) -> p (maybe:no) -> ""))
                                                   "}"))))
            except
            (:WebAuthn/Failed why) -> (refuse why)
            (:CBOR/Bad why _) -> (refuse (format "malformed attestation (" why ")")))))))

;; --------------------------------------------------------------------------------
;; pages

(define (login-page title body)
  (format
   "<!doctype html>\n<html><head><meta charset=\"utf-8\">"
   "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
   "<title>" title "</title>"
   "<style>body{font-family:system-ui,sans-serif;max-width:32em;margin:3em auto;padding:0 1em;line-height:1.5}"
   "button{font-size:1.1em;padding:.5em 1em}input{font-size:1.1em;padding:.3em}"
   "code{display:block;word-break:break-all;background:#eee;padding:.5em;margin:.5em 0}"
   "#msg{color:#b00}@media(prefers-color-scheme:dark){body{background:#181818;color:#ddd}code{background:#333}a{color:#8af}}</style>"
   "</head><body>\n<h1>" title "</h1>\n" body "\n</body></html>\n"))

(define login-js-common
  (format
   "const b64u = b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\\+/g,'-').replace(/\\//g,'_').replace(/=+$/,'');\n"
   "const unb64u = s => Uint8Array.from(atob(s.replace(/-/g,'+').replace(/_/g,'/')), c => c.charCodeAt(0));\n"
   "const say = s => { document.getElementById('msg').textContent = s; };\n"
   "async function post(url, body) {\n"
   "  const r = await fetch(url, {method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify(body||{})});\n"
   "  if (!r.ok) throw new Error(await r.text());\n"
   "  return r.json();\n"
   "}\n"))

(define (handle-login-page self request query)
  (login-send-page
   request "200" "Log in"
   (format
    "<p><button id=\"go\">Log in with a passkey</button></p>\n<p id=\"msg\"></p>\n"
    (match self.users with
      (maybe:yes _) -> (format "<p>Or <a href=\"/login/password?next=" (login-query-escape (login-next query)) "\">use a password</a>.</p>\n")
      (maybe:no) -> "")
    "<script>\n" login-js-common
    "const next = " (login-js-string (login-next query)) ";\n"
    "async function login() {\n"
    "  try {\n"
    "    const o = await post('/login/begin');\n"
    "    const c = await navigator.credentials.get({publicKey: {challenge: unb64u(o.challenge), rpId: o.rpId, userVerification: 'required', timeout: 120000}});\n"
    "    await post('/login/finish', {id: b64u(c.rawId), clientDataJSON: b64u(c.response.clientDataJSON),\n"
    "                                 authenticatorData: b64u(c.response.authenticatorData), signature: b64u(c.response.signature)});\n"
    "    location.href = next;\n"
    "  } catch (e) { say(e.message || String(e)); }\n"
    "}\n"
    "document.getElementById('go').onclick = login;\n"
    "</script>")))

(define (handle-enroll-page self request token)
  (if (not (login-enroll-token-ok? self token))
      (login-send-page request "404" "Add a passkey"
                 "<p>This link has expired or been used. The server logs a new one when it starts, and on each reload (SIGHUP).</p>")
      (login-send-page
       request "200" "Add a passkey"
       (format
        "<p><label>Name: <input id=\"name\" autocomplete=\"username\"></label> <button id=\"go\">Create a passkey</button></p>\n"
        "<p id=\"msg\"></p>\n<div id=\"done\" hidden><p>Add this line to <span id=\"file\"></span>, then reload the server (<tt>service irken_h2d reload</tt>):</p><code id=\"line\"></code></div>\n"
        "<script>\n" login-js-common
        "const base = '/login/enroll/' + " (login-js-string token) ";\n"
        "async function enroll() {\n"
        "  try {\n"
        "    const o = await post(base + '/begin', {name: document.getElementById('name').value});\n"
        "    const c = await navigator.credentials.create({publicKey: {\n"
        "      challenge: unb64u(o.challenge), rp: {id: o.rpId, name: o.rpId},\n"
        "      user: {id: unb64u(o.userId), name: o.name, displayName: o.name},\n"
        "      pubKeyCredParams: [{type: 'public-key', alg: -7}, {type: 'public-key', alg: -8}],\n"
        "      excludeCredentials: o.exclude.map(id => ({type: 'public-key', id: unb64u(id)})),\n"
        "      authenticatorSelection: {residentKey: 'required', userVerification: 'required'},\n"
        "      attestation: 'none', timeout: 120000}});\n"
        "    const r = await post(base + '/finish', {name: o.name, clientDataJSON: b64u(c.response.clientDataJSON),\n"
        "                                            attestationObject: b64u(c.response.attestationObject)});\n"
        "    say('');\n"
        "    document.getElementById('file').textContent = r.file;\n"
        "    document.getElementById('line').textContent = r.line;\n"
        "    document.getElementById('done').hidden = false;\n"
        "  } catch (e) { say(e.message || String(e)); }\n"
        "}\n"
        "document.getElementById('go').onclick = enroll;\n"
        "</script>"))))

;; --------------------------------------------------------------------------------
;; the handler

;; /login/...: (maybe fun).
(define (login-routes self request)
  (let (((path query) (login-path-and-query request))
        (method (match (lookup-header ":method" request.headers) with (maybe:yes m) -> m (maybe:no) -> ""))
        (parts (string-split path #\/)))
    (define (wrap fun)
      (maybe:yes
       (lambda (request)
         (try
          (fun request)
          except
          (:Login/BadRequest why) -> (login-send-text request "400" why)))))
    (match method parts with
      "GET"  ("" "login" "")                  -> (wrap (lambda (r) (handle-login-page self r query)))
      "POST" ("" "login" "begin")             -> (wrap (lambda (r) (handle-login-begin self r)))
      "POST" ("" "login" "finish")            -> (wrap (lambda (r) (handle-login-finish self r)))
      "GET"  ("" "login" "password")          -> (wrap (lambda (r) (handle-login-password self r query)))
      "GET"  ("" "login" "logout")            -> (wrap (lambda (r) (handle-logout self r)))
      "GET"  ("" "login" "enroll" token)      -> (wrap (lambda (r) (handle-enroll-page self r token)))
      "POST" ("" "login" "enroll" token "begin")
      -> (wrap (lambda (r) (if (login-enroll-token-ok? self token) (handle-enroll-begin self r) (login-send-text r "404" "this link has expired or been used"))))
      "POST" ("" "login" "enroll" token "finish")
      -> (wrap (lambda (r) (if (login-enroll-token-ok? self token) (handle-enroll-finish self r) (login-send-text r "404" "this link has expired or been used"))))
      _ _ -> (maybe:no))))

;; <handler>, for paths starting with <prefix>, needs a login.  without
;;  one, a browser asking for a page is sent to /login/ (when there are
;;  passkeys); anything else gets a 401 (with a basic-auth challenge, if
;;  there are passwords).  /login/... is always reachable.
(define (login-wrapper self prefix handler)
  (lambda (request)
    (cond ((and (login-enabled? self) (header-matches? request starts-with ":path" "/login/"))
           (login-routes self request))
          ((not (header-matches? request starts-with ":path" prefix))
           (maybe:no))
          ((not (eq? (login-user self request) (maybe:no)))
           (handler request))
          (else
           (maybe:yes
            (lambda (request)
              (let ((wants-page (and (header-matches? request string=? ":method" "GET")
                                     (match (lookup-header "accept" request.headers) with
                                       (maybe:yes a) -> (>= (string-find "text/html" a) 0)
                                       (maybe:no) -> #f))))
                (cond ((and wants-page (login-enabled? self))
                       (let (((path query) (login-path-and-query request))
                             (here (if (string=? query "") path (format path "?" query))))
                         (request.send-headers "302" (list (:tuple "location" (format "/login/?next=" (login-query-escape here))) login-no-store) #f)))
                      ((not (eq? self.users (maybe:no)))
                       (request.send-headers "401" (list (:tuple "www-authenticate" "Basic realm=\"login\"") login-no-store) #f))
                      (else
                       (login-send-text request "401" "log in first: /login/"))))))))))
