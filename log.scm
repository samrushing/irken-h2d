;; -*- Mode: Irken -*-

;; logging.  irken-h2d usually runs under daemon(8), which sends its
;;  output to syslog: so plain text (no ANSI), a line per message, and
;;  flushed at once (stdout into a pipe is otherwise block-buffered).
;;
;; chatter goes through debugf (doom/scheduler.scm), which is off
;;  unless the server is run with -d.

(defmacro logf
  (logf x ...) -> (begin (printf x ...) (printf "\n") (flush) #u))
