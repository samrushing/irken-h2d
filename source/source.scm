;; -*- Mode: Irken -*-

;; irken-source: browse a tree of Irken source over HTTP/2, highlighted.
;;
;;   /s/<dir>/   the directory: its subdirectories and files
;;   /s/<file>   the file, with line numbers: Irken (.scm) highlighted
;;               (source/highlight.scm), with links from the uses of its
;;               top-level definitions to them, and from (require "...")
;;               to the file; other text as it is
;;   /r/<file>   the file itself
;;
;; build from the top of the irken-h2d tree: $ irken source/source.scm

(require "server.scm")
(require "webutil.scm")
(require "source/highlight.scm")

;; bigger files are only offered raw.
(define source/max-size (* 4 1024 1024))

(define (irken-name? name) (string=? (extension name) "scm"))

;; text, if its first 4k has no NULs and few other control characters.
(define (text-file? path info)
  (or (= info.size 0)
      (let ((head (read-head path 4096))
            (odd 0))
        (let/cc return
          (for-range i (string-length head)
            (let ((c (char->int (string-ref head i))))
              (cond ((= c 0) (return #f))
                    ((and (< c 32) (not (member? c '(9 10 12 13 27) =))) (inc! odd))
                    (else #u))))
          (< (* odd 20) (string-length head))))))

;; /s/ (or /r/) and the path, each part escaped.
(define (source-url kind rel)
  (format "/" kind "/" (string-join (map url-escape (string-split rel #\/)) "/")))

(define (dir-url rel)
  (if (string=? rel "") "/s/" (format (source-url "s" rel) "/")))

(define (dirname rel)
  (let ((parts (string-split rel #\/)))
    (string-join (take parts (- (length parts) 1)) "/")))

(define (join-rel a b)
  (if (string=? a "") b (format a "/" b)))

;; --------------------------------------------------------------------------------
;; the page

(define source/css "
:root { color-scheme: dark; }
body { margin: 0; background: #151515; color: #ddd; font: 15px system-ui, sans-serif; }
a { color: #8cf; text-decoration: none; }
header { padding: 10px 14px; position: sticky; top: 0; background: #151515ee; z-index: 1;
         display: flex; flex-wrap: wrap; align-items: baseline; border-bottom: 1px solid #262626; }
header .sep { color: #666; margin: 0 6px; }
header .info { color: #888; font-size: 14px; margin-left: 12px; }
header .right { margin-left: auto; display: flex; gap: 14px; font-size: 15px; }
header .right span { color: #555; }
details.defs { padding: 6px 14px; color: #aaa; font-size: 14px; }
details.defs div { columns: 16em; padding: 6px 0; font: 13px ui-monospace, Menlo, Consolas, monospace; }
details.defs a { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
table.files { border-collapse: collapse; margin: 8px 14px 30px; font-size: 14px; }
table.files td { padding: 3px 14px 3px 0; }
table.files td.size, table.files td.date { color: #888; text-align: right; font-variant-numeric: tabular-nums; }
pre.code { margin: 0; padding: 8px 0 40px; font: 13px/1.45 ui-monospace, Menlo, Consolas, monospace; tab-size: 8; }
.l { display: block; padding-right: 14px; scroll-margin-top: 60px; }
.l:target { background: #3a3520; }
.n { display: inline-block; width: 4em; padding-right: 1.2em; text-align: right; color: #555; user-select: none; }
.n:hover { color: #aaa; }
pre a { color: inherit; scroll-margin-top: 60px; }
pre a:hover { text-decoration: underline; }
pre a:target { background: #4a4520; outline: 1px solid #776; }
.c { color: #7f9870; font-style: italic; }
.s, .ch { color: #d69d85; }
.k, .a, .q { color: #c586c0; }
.k { font-weight: 600; }
pre .d { color: #dcdcaa; font-weight: 600; }
.t { color: #4ec9b0; }
.nu { color: #b5cea8; }
.p { color: #6a6a6a; }
")

;; the header: the path as links (each directory), then <info>, and at
;;  the right <right> (already HTML).  <dir?>: the page is a directory's.
(define (source/header rel dir? info right)
  (let ((parts (if (string=? rel "") (list:nil) (string-split rel #\/)))
        (out (list "<header><a href='/s/'>source</a>"))
        (acc ""))
    (let loop ((parts parts))
      (match parts with
        () -> #u
        (p . tl)
        -> (begin
             (set! acc (join-rel acc p))
             (push! out "<span class='sep'>/</span>")
             ;; the last part is this page: a directory link only if
             ;;  it's one.
             (push! out (if (and (null? tl) (not dir?))
                            (format "<a href='" (html-escape (source-url "s" acc)) "'>" (html-escape p) "</a>")
                            (format "<a href='" (html-escape (dir-url acc)) "'>" (html-escape p) "</a>")))
             (loop tl))))
    (push! out (format "<span class='info'>" info "</span><span class='right'>" right "</span></header>"))
    (string-concat (reverse out))))

(define (source/page title header body)
  (string-concat
   (list "<!doctype html>\n<html><head><meta charset='utf-8'>"
         "<meta name='viewport' content='width=device-width, initial-scale=1'>"
         "<title>" (html-escape title) "</title><link rel='icon' href='/favicon.svg'>"
         "<style>" source/css "</style></head><body>"
         header body "</body></html>\n")))

(define (send-page request title header body)
  (send-body request "200" "text/html; charset=utf-8" (list (:tuple "cache-control" "no-cache"))
             (source/page title header body)))

;; --------------------------------------------------------------------------------
;; directories

(define (format-date time_t)
  (let ((tm (localtime time_t)))
    (format (int tm.year) "-" (zpad 2 (int (+ 1 tm.mon))) "-" (zpad 2 (int tm.mday))
            " " (zpad 2 (int tm.hour)) ":" (zpad 2 (int tm.min)))))

(define (format-size n)
  (cond ((< n 10000) (format (int n)))
        ((< n 10000000) (format (int (/ n 1024)) "k"))
        (else (format (int (/ n 1048576)) "M"))))

(define (send-directory request root rel)
  ;; (not emacs' backups and autosaves: foo.scm~, #foo.scm#)
  (let (((dirs files) (list-directory (root-path root rel)
                                      (lambda (name) (not (or (ends-with name "~") (starts-with name "#"))))))
        ((prev next) (sibling-dirs root rel))
        (rows (list:nil))
        (nscm 0))
    (define (side href label)
      (if (string=? href "")
          (format "<span>" label "</span>")
          (format "<a href='" (html-escape (dir-url href)) "'>" label "</a>")))
    (for-list d dirs
      (push! rows (format "<tr><td><a href='" (html-escape (dir-url (join-rel rel d))) "'>"
                          (html-escape d) "/</a></td><td class='size'></td><td class='date'></td></tr>")))
    (for-list f files
      (let ((frel (join-rel rel f))
            (path (root-path root frel)))
        (try
         (let ((info (stat path))
               (url (if (and (<= info.size source/max-size) (text-file? path info))
                        (source-url "s" frel)
                        (source-url "r" frel))))
           (when (irken-name? f) (inc! nscm))
           (push! rows (format "<tr><td><a href='" (html-escape url) "'>" (html-escape f) "</a></td>"
                               "<td class='size'>" (format-size info.size) "</td>"
                               "<td class='date'>" (format-date info.mtime) "</td></tr>")))
         except
         (:OSError _) -> #u)))
    (send-page request (if (string=? rel "") "source" rel)
               (source/header rel #t
                              (if (> nscm 0) (format (int nscm) " .scm") "")
                              (if (string=? rel "")
                                  ""
                                  (format (side prev (format "&larr; " (html-escape (last (string-split prev #\/)))))
                                          (side next (format (html-escape (last (string-split next #\/))) " &rarr;")))))
               (format "<table class='files'>" (string-concat (reverse rows)) "</table>"))))

;; --------------------------------------------------------------------------------
;; files

;; where (require "<path>") in the file <rel> comes from: the compiler
;;  looks in the directory it's run from, which is usually the top of
;;  the project, so try each directory above the file's (in the root),
;;  and then the -lib directories.
(define (find-require root libs rel path)
  (let/cc return
    (let loop ((dir (dirname rel)))
      (let ((candidate (join-rel dir path)))
        (when (isfile? (root-path root candidate))
          (return (source-url "s" candidate))))
      (when (not (string=? dir ""))
        (loop (dirname dir))))
    (for-list lib libs
      (let ((candidate (join-rel lib path)))
        (when (isfile? (root-path root candidate))
          (return (source-url "s" candidate)))))
    ""))

(define (send-source request root libs rel path info)
  (let ((src (read-at path info.size 0))
        (irken? (irken-name? rel))
        ((lines defs) (highlight src irken? (lambda (p) (find-require root libs rel p))))
        (index (if (null? defs)
                   ""
                   (format "<details class='defs'><summary>" (int (length defs)) " definitions</summary><div>"
                           (string-concat
                            (map (lambda (d) (format "<a href='#d-" (url-escape d) "'>" (html-escape d) "</a>"))
                                 (sort string<? defs)))
                           "</div></details>"))))
    (send-page request (last (string-split rel #\/))
               (source/header rel #f (format (format-size info.size) " bytes")
                              (format "<a href='" (html-escape (source-url "r" rel)) "'>raw</a>"))
               (format index "<pre class='code'>" (string-concat lines) "</pre>"))))

(define (browse-source request root libs parts)
  (match (clean-path parts) with
    (maybe:no) -> (send-404 request)
    (maybe:yes rel)
    -> (let ((path (root-path root rel))
             (slash? (string=? (last parts) "")))
         (cond ((isdir? path)
                (if slash?
                    (send-directory request root rel)
                    (send-redirect request (dir-url rel))))
               ((and (isfile? path) (not slash?))
                (let ((info (stat path)))
                  (if (and (<= info.size source/max-size) (text-file? path info))
                      (send-source request root libs rel path info)
                      (send-plain request path info))))
               (else (send-404 request))))))

;; as text, if it is, or else as a download.
(define (send-plain request path info)
  (send-file-as request path info
                (if (text-file? path info) "text/plain; charset=utf-8" "application/octet-stream")))

(define (send-raw request root parts)
  (match (clean-path parts) with
    (maybe:yes rel)
    -> (let ((path (root-path root rel)))
         (if (isfile? path)
             (send-plain request path (stat path))
             (send-404 request)))
    (maybe:no) -> (send-404 request)))

(define (source-handler root libs)
  (lambda (request)
    (match (unpack-request request) with
      (maybe:yes (:tuple method parts params fragment))
      -> (match method parts with
           "GET" ("" "")       -> (handle-with (lambda (r) (send-redirect r "/s/")))
           "GET" ("" "s" . tl) -> (handle-with (lambda (r) (browse-source r root libs tl)))
           "GET" ("" "r" . tl) -> (handle-with (lambda (r) (send-raw r root tl)))
           _ _ -> (maybe:no))
      (maybe:no) -> (maybe:no))))

;; --------------------------------------------------------------------------------
;; main

(define program-options
  (makeopt
   (arg 'root (string ""))
   (arg 'lib (string ""))
   (arg 'cert (string "cert.pem"))
   (arg 'key  (string "key.pem"))
   (arg 'log  (string "/var/log/irken-source.log"))
   (arg 'users (string ""))
   (arg 'passkeys (string ""))
   (arg 'user (string ""))
   (flag 'open)
   (flag 'd)
   (pos 'addr (string "127.0.0.1:4433"))
   (flag 'h)
   ))

(define (usage)
  (printf "irken-source: browse a tree of Irken source over HTTP/2.\n\n")
  (printf "Usage: " sys.argv[0] " <addr> -root <dir>\n"
          "  -root <dir>      the tree\n"
          "  [-lib <dirs>]    where else (require \"...\") looks: directories in\n"
          "                   the tree, separated by commas (e.g. irken-compiler)\n"
          "  [-cert = cert.pem]\n"
          "  [-key = key.pem]\n"
          "  [-log = /var/log/irken-source.log]\n"
          "  [-users <file>]  name:password lines; everything needs a login\n"
          "  [-passkeys <file>] passkeys (see README.md); everything needs a login\n"
          "  [-open]          no login at all (only on a private network!)\n"
          "                   one of -users, -passkeys or -open is required.\n"
          "  [-user <name>]   after binding the port, run as this user\n"
          "  [-d] print debugging output\n"
          "  [-h] print this usage.\n"
          "\n"
          "example: $ " sys.argv[0] " 0.0.0.0:8445 -root ~/src/irken -lib claude/irken-compiler -open\n"
          "\n")
  (%exit #f -1))

(define (get-options)
  (if (< sys.argc 2)
      (usage)
      (try
       (process-options program-options (rest (vector->list sys.argv)))
       except
       (:Getopt/MissingArg _ _) -> (usage)
       (:Getopt/UnknownArg _ _) -> (usage)
       )))

(define (main)
  (let ((opts (get-options))
        (addr "127.0.0.1:4433")
        (root "")
        (libs (list:nil))
        (cert "cert.pem")
        (key  "key.pem")
        (log  "/var/log/irken-source.log")
        (users (maybe:no))
        (passkeys (maybe:no))
        (open? #f)
        (user (maybe:no)))
    (when-maybe v (get-bool-opt opts 'h) (usage))
    (when-maybe v (get-string-opt opts 'root) (set! root v))
    (when-maybe v (get-string-opt opts 'lib)
      (set! libs (filter (lambda (s) (> (string-length s) 0)) (string-split v #\,))))
    (when-maybe v (get-string-opt opts 'cert) (set! cert v))
    (when-maybe v (get-string-opt opts 'key)  (set! key v))
    (when-maybe v (get-string-opt opts 'log)  (set! log v))
    (when-maybe v (get-string-opt opts 'addr) (set! addr v))
    (when-maybe v (get-string-opt opts 'users) (when (> (string-length v) 0) (set! users (maybe:yes v))))
    (when-maybe v (get-string-opt opts 'passkeys) (when (> (string-length v) 0) (set! passkeys (maybe:yes v))))
    (when-maybe v (get-string-opt opts 'user) (when (> (string-length v) 0) (set! user (maybe:yes v))))
    (when-maybe v (get-bool-opt opts 'open) (set! open? v))
    (set! *debugf* #f)
    (when-maybe v (get-bool-opt opts 'd) (set! *debugf* v))
    (set-verbose-gc *debugf*)
    (while (and (> (string-length root) 1) (ends-with root "/"))
      (set! root (substring root 0 (- (string-length root) 1))))
    (when (not (isdir? root))
      (printf "-root: " (string root) " is not a directory\n")
      (usage))
    (when (and (eq? users (maybe:no)) (eq? passkeys (maybe:no)) (not open?))
      (printf "one of -users <file>, -passkeys <file> or -open is needed.\n")
      (usage))
    (run-server addr opts cert key log user users passkeys "source" (source-handler root libs)
                (lambda ()
                  (logf "serving " root)
                  (for-list lib libs
                    (when (not (isdir? (root-path root lib)))
                      (logf "warning: -lib " lib " is not a directory in " root)))))))

(signal/ignore SIGPIPE)
(main)
