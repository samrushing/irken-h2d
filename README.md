
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

Privileges
----------

Start the server as root (it binds ports 80 and 443), with -user <name>
(irken_h2d_server_user in rc.conf): once the ports are bound and the log file
and certificates read, it becomes that user, with that user's groups
only, and there's no way back to root.  The certificate, key and users
file must then be readable by that user, for SIGHUP reloads.

Status page and logging
-----------------------

/status/ (basic auth) is enabled with -users <file>, a file of
"name:password" lines kept outside the repo (mode 0600: the server
warns otherwise).  Without -users, /status/ is disabled.

Under daemon(8), the server's output goes to syslog.  It logs only
startup, SIGHUP reloads and errors, as plain lines; -d adds the
(colorful) per-connection debugging output.

The access log (-log, default /var/log/irken-httpd.log) is written by
the server itself, so to rotate it newsyslog renames it and sends
SIGHUP, and the server reopens it.  Since the server is no longer root
by then, newsyslog must create the new file owned by the server's
user.  In /etc/newsyslog.conf.d/irken-h2d.conf (daily at midnight,
keep 7, bzip2'd):

    /var/log/irken-httpd.log  www:www  644  7  *  @T00  JC  /var/run/irken_h2d.child.pid

(the child pid file is the server's own pid; /var/run/irken_h2d.pid is
daemon(8)'s, and daemon doesn't pass SIGHUP on.)  If the server can't
reopen the log, it logs why and keeps writing to the old file.

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

Photo browser
-------------

photos/photos.scm is a second server built on the same parts
(server.scm): it browses a directory tree of photos.  Thumbnails come
straight out of the files (a JPEG's EXIF thumbnail, a HEIC's thumbnail
item), so there's nothing to index and nothing to wait for; a viewer
shows the full images, with a slideshow.

It needs libjpeg (libjpeg-turbo: `pkg install libjpeg-turbo`), for
JPEGs with no EXIF thumbnail.  Generate its interface once (and again
after changing photos/jpegthumb.h), from the top of this tree:

    $ IRKENLIB=<irken tree> <irken tree>/ffi/gen/genffi -gen ffi/jpegthumb.ffi
    $ irken photos/photos.scm
    $ photos/photos 0.0.0.0:8444 -root /photos -users photo-users \
        -cert ... -key ... -cache /var/cache/irken-photos

-users is the same name:password file as for /status/, and then
everything (including /status/) needs a login; -open serves without
one, for a private network only.  One or the other is required.

JPEGs with no EXIF thumbnail (scans, mostly) are decoded at 1/8 scale
(or 1/4, 1/2) by libjpeg, through a small C shim (photos/jpegthumb.c).
The decode is done a chunk of the file at a time, with libjpeg's I/O
suspension, and other connections get their turn in between, so a
directory of big scans doesn't hold the server up.  With -cache, the
results are kept.

Browsers other than Safari can't show HEIC: with -cache <dir>, HEIC
thumbnails and images are converted to JPEG with libheif's heif-dec
(-heif-dec <command>; called as `<command> -q 85 in.heic out.jpg`), and
the results kept in <dir>, which can be emptied at any time.  Without
-cache, HEICs are sent as they are.

The links at the top right, and [ and ], go to the directories before
and after this one.  In the viewer: arrows (or click/swipe) move, space starts and stops the
slideshow, i shows the date, camera and size, f is full screen, and
escape goes back to the thumbnails.  The URL's #name links to an image.

JPEGs whose pixels were rotated by a tool that left the EXIF orientation
alone (the frame is the other way round from PixelX/YDimension) are
sent with the orientation set to 1, so that browsers don't turn them a
second time.
