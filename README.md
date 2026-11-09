
 Irken HTTP/2 Server
=====================

An HTTPS (TLS 1.3, HTTP/2) file server, and an ACME client to keep its
certificate current, written in Irken.

To build
--------

Against an installed Irken (python3 util/install.py in the compiler
repo; set IRKENLIB if it isn't installed in /usr/local/lib/irken/):

    $ irken serve.scm
    $ irken acme/acme.scm

and install them as, e.g., /usr/local/sbin/irken-h2d and
/usr/local/bin/irken-acme.  These build against the installed copy of
Irken's libraries, so re-install Irken after changing them.

irken_h2d.sh is a FreeBSD rc script: see the comments at its top.

Status page and logging
-----------------------

/status/ (basic auth) is enabled with -users <file>, a file of
"name:password" lines kept outside the repo (mode 0600: the server
warns otherwise).  Without -users, /status/ is disabled.

Under daemon(8), the server's output goes to syslog.  It logs only
startup, SIGHUP reloads and errors, as plain lines; -d adds the
(colorful) per-connection debugging output.

Certificates
------------

irken-acme gets certificates from Let's Encrypt with http-01
challenges, which the server answers on port 80 (-acme /var/acme), so
it can renew while the server runs.  Daily from cron:

    /usr/local/bin/irken-acme -challenges /var/acme -days 30 \
        -account /usr/local/etc/ssl/dark/acme-account.key \
        -key /usr/local/etc/ssl/dark/dark.key \
        -cert /usr/local/etc/ssl/dark/dark.chain \
        nightmare.com dark.nightmare.com www.nightmare.com unintuitive.org \
      | grep -q '^wrote' && service irken_h2d reload

[ this probably needs to be changed to use `cert-deploy` ]

irken-acme prints "wrote <cert>" only when it renews; "service
irken_h2d reload" sends the server SIGHUP, which reloads its
certificate and key.  See acme/README.txt.
