acme: get certificates from Let's Encrypt (or any ACME CA)
===========================================================

A small ACME (RFC 8555) client, using http-01 challenges.  It uses
only Irken's own TLS 1.3 client, HTTP/2 or HTTP/1.1, JSON, and P-256
ECDSA: no openssl, no certbot.

$ irken acme/acme.scm

    irken-acme -challenges <dir> [options] name ...

(installed as irken-acme, to keep it apart from other ACME tools.)

The challenge responses are written as files named by their tokens in
<dir>; a web server must answer

    http://<name>/.well-known/acme-challenge/<token>

with the contents of <dir>/<token>.  irken-h2d (serve.scm) does this
on its port-80 (redirect) listener with -acme:

    irken-h2d -root /var/www -cert cert.pem -key key.pem \
        -acme /var/acme 0.0.0.0:443

so certificates can be renewed while the server keeps running.  (Other
requests to port 80 are still redirected to https.)

Options
-------

  -challenges <dir>  where to write the challenge responses (required)
  -account <file>    the ACME account key [account.key]: created on first use
  -key <file>        the certificate's key [key.pem]: created if missing,
                     and kept across renewals
  -cert <file>       where to write the certificate chain [cert.pem]
  -days <n>          do nothing if -cert names all the names and is good for
                     more than <n> days: for running from cron
  -email <addr>      a contact address for the account (optional)
  -profile <name>    request a certificate profile, e.g. "shortlived"
  -staging           use Let's Encrypt's staging server
  -server <url>      use this ACME directory URL (default: Let's Encrypt)
  -root <pem>        trust these roots for the ACME server (for testing
                     with pebble)
  -v                 print the protocol exchange

Keys are P-256, in PKCS#8 PEM files (mode 0600), as read-skey (and
openssl) read them.  The first name is used as the certificate's CN;
all the names go in subjectAltName.

Try -staging first: Let's Encrypt's production server has rate limits,
and the staging server doesn't (its certificates aren't trusted).

Renewing from cron
------------------

Certificates last 90 days (64 from February 2027, 45 from February
2028).  Something like this, daily:

    /usr/local/bin/irken-acme -challenges /var/acme -days 30 \
        -account /usr/local/etc/ssl/dark/acme-account.key \
        -key /usr/local/etc/ssl/dark/dark.key \
        -cert /usr/local/etc/ssl/dark/dark.chain \
        nightmare.com dark.nightmare.com www.nightmare.com unintuitive.org \
      | grep -q '^wrote' && service irken_h2d reload

irken-acme prints "wrote <cert>" when it renews (and exits 0 both then
and when there's nothing to do).  "service irken_h2d reload" (see
irken_h2d.sh) sends the server SIGHUP, and it reloads its -cert and
-key: new connections use them, and existing ones carry on.  If they
can't be loaded, or the key doesn't match the certificate, it keeps the
old ones (and says so).  [SIGHUP reloading uses kqueue, so for now it
works on the BSDs and macOS, not Linux.]

Testing with pebble
-------------------

pebble (https://github.com/letsencrypt/pebble) is Let's Encrypt's test
CA.  With pebble-challtestsrv answering DNS (every name -> 127.0.0.1)
and pebble's httpPort set to the server's -http port:

    pebble-challtestsrv -http01 "" -https01 "" -tlsalpn01 "" -doh "" \
        -dnsserver 127.0.0.1:8053 &
    pebble -config config.json -dnsserver 127.0.0.1:8053 &
    ./serve -http 5080 -acme /tmp/acme ... 127.0.0.1:4433 &
    acme/acme -server https://localhost:14000/dir \
        -root test/certs/pebble.minica.pem -challenges /tmp/acme test.example.com

Not (yet) supported
-------------------

tls-alpn-01 and dns-01 challenges; ACME Renewal Information (ARI);
revocation and account key rollover; RSA keys; IPv6; timeouts.
