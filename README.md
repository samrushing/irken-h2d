
 Irken HTTP/2 Server
=====================

To build:

    $ irken serve.scm
    $ irken acme/acme.scm

For cron:

[ this probably needs to be changed to use `cert-deploy` ]

    cd /usr/local/etc/irken-httpd && \
      /usr/local/bin/acme -challenges /var/acme -days 30 \
        nightmare.com dark.nightmare.com www.nightmare.com \
      | grep -q '^wrote' && pkill -HUP -x serve

