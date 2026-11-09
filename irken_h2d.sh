#!/bin/sh
#
# PROVIDE: irken_h2d
# REQUIRE: LOGIN NETWORKING
# KEYWORD: shutdown
#
# Add these lines to /etc/rc.conf to enable irken-h2d:
#
# irken_h2d_enable (bool):   Set to "YES" to enable. Default "NO".
# irken_h2d_binary (path):  Server binary. Default /usr/local/sbin/irken-h2d.
# irken_h2d_addr (str):      Address to listen on. Default "0.0.0.0:443".
# irken_h2d_root (path):     Site root (one subdir per hostname).
#                            Default /usr/local/www/data/.
# irken_h2d_cert (path):     Certificate chain.
#                            Default /usr/local/etc/ssl/dark/dark.chain.
# irken_h2d_key (path):      Private key.
#                            Default /usr/local/etc/ssl/dark/dark.key.
# irken_h2d_acme (path):     Directory of ACME http-01 challenge tokens,
#                            served on port 80. Default /var/acme.
#                            Set to "" to disable.
# irken_h2d_users (path):    Users for /status (basic auth): "name:password"
#                            lines, mode 0600.  Default "": /status disabled.
# irken_h2d_log (path):      Server log file. Default "" (server's default).
# irken_h2d_args (str):      Any extra server arguments (e.g. "-r",
#                            "-http 8080", or "-d" for debugging output).
#                            Default "".
#                            (irken_h2d_flags, if set, goes to daemon(8).)
# irken_h2d_runas (str):     User the server runs as (via daemon -u).
#                            Default "root".
# irken_h2d_restart (int):   Seconds to wait before restarting after a crash.
#                            Default 5. Set to "" to disable auto-restart.
#
# "service irken_h2d reload" sends SIGHUP, which makes the server re-read
# its certificate and key without dropping connections.

. /etc/rc.subr

name=irken_h2d
rcvar=irken_h2d_enable
desc="Irken HTTP/2 server"

load_rc_config $name

: ${irken_h2d_enable:="NO"}
: ${irken_h2d_binary:="/usr/local/sbin/irken-h2d"}
: ${irken_h2d_addr:="0.0.0.0:443"}
: ${irken_h2d_root:="/usr/local/www/data/"}
: ${irken_h2d_cert:="/usr/local/etc/ssl/dark/dark.chain"}
: ${irken_h2d_key:="/usr/local/etc/ssl/dark/dark.key"}
: ${irken_h2d_acme="/var/acme"}
: ${irken_h2d_users=""}
: ${irken_h2d_log=""}
: ${irken_h2d_args:=""}
: ${irken_h2d_runas:="root"}
: ${irken_h2d_restart="5"}

pidfile="/var/run/${name}.pid"
childpidfile="/var/run/${name}.child.pid"

_server_args="-root ${irken_h2d_root} -cert ${irken_h2d_cert} -key ${irken_h2d_key}"
[ -n "${irken_h2d_acme}" ] && _server_args="${_server_args} -acme ${irken_h2d_acme}"
[ -n "${irken_h2d_users}" ] && _server_args="${_server_args} -users ${irken_h2d_users}"
[ -n "${irken_h2d_log}" ]  && _server_args="${_server_args} -log ${irken_h2d_log}"
_server_args="${_server_args} ${irken_h2d_args} ${irken_h2d_addr}"

_restart_args=""
[ -n "${irken_h2d_restart}" ] && _restart_args="-R ${irken_h2d_restart}"

# Run the server under daemon(8): it detaches, records pids, drops to the
# configured user, sends stdout/stderr (e.g. crash output) to syslog, and
# optionally restarts the server if it dies.
command="/usr/sbin/daemon"
procname="daemon"
command_args="-P ${pidfile} -p ${childpidfile} ${_restart_args} \
    -S -T irken-h2d -u ${irken_h2d_runas} \
    ${irken_h2d_binary} ${_server_args}"

required_files="${irken_h2d_binary} ${irken_h2d_cert} ${irken_h2d_key}"
required_dirs="${irken_h2d_root} ${irken_h2d_acme}"

# "reload": SIGHUP makes the server re-read its cert and key.
# Signal the server (child) itself, not daemon(8): the supervisor
# doesn't forward SIGHUP.
extra_commands="reload"
reload_cmd="${name}_reload"

irken_h2d_reload()
{
    local pid
    pid=$(check_pidfile ${childpidfile} ${irken_h2d_binary})
    if [ -z "${pid}" ]; then
        echo "${name} not running? (check ${childpidfile})."
        return 1
    fi
    echo "Reloading ${name}."
    kill -HUP ${pid}
}

run_rc_command "$1"
