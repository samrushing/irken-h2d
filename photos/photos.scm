;; -*- Mode: Irken -*-

;; irken-photos: browse a photo archive over HTTP/2.
;;
;;   /b/<dir>/     a page of thumbnails for <dir>, with a viewer and slideshow
;;   /t/<file>     a thumbnail: a JPEG's EXIF thumbnail (with its
;;                 orientation), a HEIC's thumbnail item, or else the file
;;   /i/<file>     the file itself
;;   /x/<file>     what we know about the file, as JSON
;;
;; a directory is listed when it's asked for, and JPEG thumbnails are
;;  read out of the files (a 64k read).  only HEIC conversions (-cache)
;;  are kept on the server.  browsers cache thumbnails and images
;;  (etags, max-age).
;;
;; build from the top of the irken-h2d tree: $ irken photos/photos.scm

(require "server.scm")
(require "photos/exif.scm")
(require "photos/heif.scm")
(require "photos/page.scm")
(require "lib/codecs/hex.scm")

;; --------------------------------------------------------------------------------
;; paths

(define (extension name)
  (let ((parts (string-split name #\.)))
    (if (> (length parts) 1)
        (downcase (last parts))
        "")))

(define (jpeg-extension? ext) (member? ext '("jpg" "jpeg" "jpe") string=?))
(define (heif-extension? ext) (member? ext '("heic" "heif") string=?))

(define image-extensions
  '("jpg" "jpeg" "jpe" "heic" "heif" "png" "gif" "webp" "avif"))

(define (image-name? name)
  (member? (extension name) image-extensions string=?))

(define (hidden? name)
  (and (> (string-length name) 0) (eq? (string-ref name 0) #\.)))

;; the path (relative to the root) that the URL path <parts> names, or
;;  (maybe:no) if it climbs out, or into a hidden file or directory.
(define (clean-path parts)
  (let ((norm (remove-dot-segments parts)))
    (if (any? hidden? norm)
        (maybe:no)
        (maybe:yes (string-join (filter (lambda (p) (> (string-length p) 0)) norm) "/")))))

(define (root-path root rel)
  (if (string=? rel "") root (format root "/" rel)))

;; the subdirectories and the images in <dir>, sorted.
(define (list-directory dir)
  (let ((dirs (list:nil))
        (images (list:nil)))
    (for-list entry (listdir dir)
      (when (not (hidden? entry.name))
        (let ((kind (match entry.kind with
                      'directory -> 'directory
                      'regular   -> 'regular
                      ;; a symlink, or a filesystem that doesn't say.
                      _ -> (let ((path (format dir "/" entry.name)))
                             (cond ((isdir? path) 'directory)
                                   ((isfile? path) 'regular)
                                   (else 'other))))))
          (match kind with
            'directory -> (push! dirs entry.name)
            'regular   -> (when (image-name? entry.name) (push! images entry.name))
            _          -> #u))))
    (:tuple (sort string<? dirs) (sort string<? images))))

;; --------------------------------------------------------------------------------
;; JSON

(define (json-string s)
  (let ((out (list:nil))
        (start 0)
        (len (string-length s)))
    ;; copy runs of ordinary bytes; escape quotes, backslashes and
    ;;  control characters, and <>& so that it's safe inside <script>.
    (for-range i len
      (let ((n (char->int (string-ref s i))))
        (when (or (< n 32) (= n 34) (= n 92) (= n 60) (= n 62) (= n 38))
          (push! out (substring s start i))
          (push! out (format "\\u00" (zpad 2 (hex n))))
          (set! start (+ i 1)))))
    (push! out (substring s start len))
    (string-concat (list "\"" (string-concat (reverse out)) "\""))))

(define (json-list strings)
  (format "[" (join "," (map json-string strings)) "]"))

;; --------------------------------------------------------------------------------
;; responses

(define cache-control (:tuple "cache-control" "private, max-age=86400"))

(define (file-etag info)
  (format "W/\"" (int info.mtime) "." (int info.size) "\""))

(define (etag-matches? request etag)
  (match (lookup-header "if-none-match" request.headers) with
    (maybe:yes inm) -> (member? etag (map string-trim-both (string-split inm #\,)) string=?)
    (maybe:no) -> #f))

;; <body>, deflated if it's worth it.
(define (send-body request status type headers body)
  (cond ((= 0 (string-length body))
         (request.send-headers status (list:cons (:tuple "content-type" type) headers) #f))
        ((> (string-length body) 1024)
         (request.send-headers status
                               (append (list (:tuple "content-type" type)
                                             (:tuple "content-encoding" "deflate"))
                                       headers)
                               #t)
         (request.send-with-generator (apply-zlib-encoding (makegen emit (emit body)))))
        (else
         (request.send-headers status
                               (append (list (:tuple "content-type" type)
                                             (:tuple "content-length" (int->string (string-length body))))
                                       headers)
                               #t)
         (request.send-data body #t))))

(define (send-redirect request location)
  (request.send-headers "302" (list (:tuple "location" location)) #f))

(define (send-file request path info)
  (let ((etag (file-etag info)))
    (cond ((etag-matches? request etag)
           (request.send-headers "304" (list (:tuple "etag" etag) cache-control) #f))
          ((= 0 info.size)
           (request.send-headers "200" (list (:tuple "etag" etag)) #f))
          (else
           (request.send-headers "200"
                                 (list (:tuple "content-type" (get-mime-type path))
                                       (:tuple "content-length" (int->string info.size))
                                       (:tuple "etag" etag)
                                       cache-control)
                                 #t)
           (request.send-with-generator (file-closing-generator path))))))

;; --------------------------------------------------------------------------------
;; the handlers

(define (browse request root parts)
  ;; directories' URLs end in a slash, so that relative links work.
  (if (not (string=? (last parts) ""))
      (send-redirect request (format "/b/" (join "/" (map url-escape parts)) "/"))
      (match (clean-path parts) with
        (maybe:no) -> (send-404 request)
        (maybe:yes rel)
        -> (let ((dir (root-path root rel)))
             (if (not (isdir? dir))
                 (send-404 request)
                 (let (((dirs images) (list-directory dir))
                       (data (format "{\"dir\":" (json-string rel)
                                     ",\"dirs\":" (json-list dirs)
                                     ",\"images\":" (json-list images) "}"))
                       (title (if (string=? rel "") "photos" rel)))
                   (send-body request "200" "text/html; charset=utf-8"
                              (list (:tuple "cache-control" "no-cache"))
                              (photos/page title data))))))))

;; call (fun path stat) for the image file that <parts> names.
(define (with-image request root parts fun)
  (match (clean-path parts) with
    (maybe:yes rel)
    -> (let ((path (root-path root rel)))
         (if (and (not (string=? rel "")) (image-name? rel) (isfile? path))
             (fun path (stat path))
             (send-404 request)))
    (maybe:no) -> (send-404 request)))

(define (thumbnail path)
  (let ((ext (extension path)))
    (cond ((jpeg-extension? ext)
           (match (jpeg/thumbnail path) with
             (maybe:yes data) -> (maybe:yes (:tuple "image/jpeg" data))
             (maybe:no) -> (maybe:no)))
          ((heif-extension? ext)
           (match (heif/thumbnail path) with
             (maybe:yes data) -> (maybe:yes (:tuple "image/heic" data))
             (maybe:no) -> (maybe:no)))
          (else (maybe:no)))))

;; --------------------------------------------------------------------------------
;; HEIC, for browsers that can't show it (all but Safari): converted to
;;  JPEG by libheif's heif-dec, and kept in the -cache directory, which
;;  can be emptied at any time.  (the conversion holds up the server
;;  while it runs: ~30ms for a thumbnail, ~1s for a full image.)

(define *cache* "")            ;; -cache <dir>: "" means don't convert.
(define *heif-dec* "heif-dec") ;; -heif-dec <command>

(define (convert-heif?) (not (string=? *cache* "")))

;; quoted for /bin/sh.
(define (sh-quote s)
  (format "'" (string-join (string-split s (int->char 39)) "'\"'\"'") "'"))

;; the subdirectories 00..ff of the cache.
(define (make-cache-dirs)
  (let ((names (map-range i 256 (sh-quote (format *cache* "/" (zpad 2 (hex i)))))))
    (when (not (= 0 (system (format "mkdir -p " (string-join names " ")))))
      (logf "can't make the cache directories in " *cache*)
      (%exit #f 1))))

;; where the converted forms of the file at <path> go: <suffix> is
;;  "-t" (the thumbnail) or "-f" (the full image).
(define (cache-name path info suffix)
  (let ((key (string->hex (sha256 (format path "|" (int info.mtime) "|" (int info.size))))))
    (format *cache* "/" (substring key 0 2) "/" key suffix)))

(define (write-file path data)
  (let ((fd (open path (logior O_WRONLY (logior O_CREAT O_TRUNC)) #o644)))
    (write fd data)
    (close fd)
    #u))

;; convert HEIF <src> to JPEG <dst> (unless that's been done), via a
;;  temporary name, so that a failure doesn't leave half a file.
(define (heif->jpeg src dst)
  (or (isfile? dst)
      (let ((tmp (format dst ".tmp.jpg")))
        (try
         (= 0 (system (format *heif-dec* " -q 85 " (sh-quote src) " " (sh-quote tmp) " >/dev/null 2>&1"
                              " && mv " (sh-quote tmp) " " (sh-quote dst)
                              " || rm -f " (sh-quote tmp))))
         except
         (:OSError _) -> #f))))

(define (heif-full-jpeg path info)
  (let ((dst (format (cache-name path info "-f") ".jpg")))
    (if (heif->jpeg path dst) (maybe:yes dst) (maybe:no))))

;; the thumbnail item, converted; or if there isn't one, the full image.
(define (heif-thumbnail-jpeg path info)
  (let ((base (cache-name path info "-t"))
        (dst (format base ".jpg")))
    (if (isfile? dst)
        (maybe:yes dst)
        (match (heif/thumbnail path) with
          (maybe:yes data)
          -> (let ((src (format base ".heic")))
               (write-file src data)
               (let ((ok (heif->jpeg src dst)))
                 (unlink src)
                 (if ok (maybe:yes dst) (maybe:no))))
          (maybe:no)
          -> (heif-full-jpeg path info)))))

(define (send-converted request path info convert)
  (match (convert path info) with
    (maybe:yes jpg) -> (send-file request jpg (stat jpg))
    ;; couldn't convert it: the browser can try.
    (maybe:no) -> (send-file request path info)))

(define (send-image request path info)
  (let ((ext (extension path)))
    (cond ((and (convert-heif?) (heif-extension? ext))
           (send-converted request path info heif-full-jpeg))
          ((jpeg-extension? ext)
           (match (jpeg/read-exif path) with
             (maybe:yes exif)
             -> (match exif.stale exif.orientation-fix with
                  #t (maybe:yes (:tuple offset bytes)) -> (send-patched-file request path info offset bytes)
                  _ _ -> (send-file request path info))
             (maybe:no) -> (send-file request path info)))
          (else (send-file request path info)))))

;; the file, with s[offset:offset+len(bytes)] replaced by <bytes>.
(define (patched-file-generator path offset bytes)
  (let ((ifile (file/open-read path))
        (pos 0))
    (makegen emit
      (let loop ((buf (file/read-buffer ifile)))
        (let ((len (string-length buf)))
          (when (> len 0)
            (for-range i (string-length bytes)
              (let ((at (- (+ offset i) pos)))
                (when (and (>= at 0) (< at len))
                  (string-set! buf at (string-ref bytes i)))))
            (set! pos (+ pos len))
            (emit buf)
            (loop (file/read-buffer ifile)))))
      (file/close ifile))))

;; a JPEG whose orientation tag is stale (see jpeg/stale-orientation?):
;;  sent with the tag set to 1.
(define (send-patched-file request path info offset bytes)
  (let ((etag (format "W/\"" (int info.mtime) "." (int info.size) ".o1\"")))
    (if (etag-matches? request etag)
        (request.send-headers "304" (list (:tuple "etag" etag) cache-control) #f)
        (begin
          (request.send-headers "200"
                                (list (:tuple "content-type" "image/jpeg")
                                      (:tuple "content-length" (int->string info.size))
                                      (:tuple "etag" etag)
                                      cache-control)
                                #t)
          (request.send-with-generator (patched-file-generator path offset bytes))))))

(define (send-thumbnail request path info)
  (if (and (convert-heif?) (heif-extension? (extension path)))
      (send-converted request path info heif-thumbnail-jpeg)
      (send-native-thumbnail request path info)))

(define (send-native-thumbnail request path info)
  (let ((etag (file-etag info)))
    (if (etag-matches? request etag)
        (request.send-headers "304" (list (:tuple "etag" etag) cache-control) #f)
        (match (thumbnail path) with
          (maybe:yes (:tuple type data))
          -> (begin
               (request.send-headers "200"
                                     (list (:tuple "content-type" type)
                                           (:tuple "content-length" (int->string (string-length data)))
                                           (:tuple "etag" etag)
                                           cache-control)
                                     #t)
               (request.send-data data #t))
          ;; no thumbnail: the browser will have to shrink the image.
          (maybe:no) -> (send-file request path info)))))

(define (send-info request path info)
  (let ((ext (extension path))
        (mexif (cond ((jpeg-extension? ext) (jpeg/read-exif path))
                     ((heif-extension? ext) (heif/read-exif path))
                     (else (maybe:no))))
        (exif (match mexif with (maybe:yes e) -> e (maybe:no) -> (exif/empty)))
        (has-thumb (match exif.thumb with (maybe:yes _) -> #t (maybe:no) -> #f)))
    (send-body request "200" "application/json" (list (:tuple "cache-control" "no-cache"))
               (format "{\"size\":" (int info.size)
                       ",\"mtime\":" (int info.mtime)
                       ",\"exif\":" (if (eq? mexif (maybe:no)) "false" "true")
                       ",\"date\":" (json-string exif.date)
                       ",\"make\":" (json-string exif.make)
                       ",\"model\":" (json-string exif.model)
                       ",\"width\":" (int exif.width)
                       ",\"height\":" (int exif.height)
                       ",\"orientation\":" (int exif.orientation)
                       ",\"stale\":" (if exif.stale "true" "false")
                       ",\"thumb\":" (if has-thumb "true" "false")
                       "}"))))

;; percent-encode a path segment (for redirects).
(define (url-escape s)
  (let ((out (list:nil)))
    (for-range i (string-length s)
      (let ((ch (string-ref s i))
            (n (char->int ch)))
        (push! out
               (if (or (and (>= n 48) (<= n 57)) (and (>= n 65) (<= n 90)) (and (>= n 97) (<= n 122))
                       (member? n '(45 46 95 126) =))
                   (char->string ch)
                   (format "%" (zpad 2 (hex n)))))))
    (string-concat (reverse out))))

(define (log-request request)
  (when-maybe log *logfile*
    (let ((info (request.get-info))
          (now (clock-gettime CLOCK_REALTIME))
          (tm (localtime now.sec)))
      (file/write log (format (int tm.year) "-" (zpad 2 (int (+ 1 tm.mon))) "-" (zpad 2 (int tm.mday))
                              " " (zpad 2 (int tm.hour)) ":" (zpad 2 (int tm.min)) ":" (zpad 2 (int tm.sec))
                              " " info.addr
                              " P" (if-maybe p (lookup-header ":path" request.headers) p "none")
                              " S" info.status
                              " T" (int info.elapsed)
                              " B" (int info.bytes)
                              "\n"))
      (file/flush log))))

(define (photo-handler root)
  (define (wrap fun)
    (maybe:yes
     (lambda (request)
       (try
        (fun request)
        except
        (:OSError _) -> (send-404 request))
       (log-request request))))
  (lambda (request)
    (match (unpack-request request) with
      (maybe:yes (:tuple method parts params fragment))
      -> (match method parts with
           "GET" ("" "")       -> (wrap (lambda (r) (send-redirect r "/b/")))
           "GET" ("" "b" . tl) -> (wrap (lambda (r) (browse r root tl)))
           "GET" ("" "t" . tl) -> (wrap (lambda (r) (with-image r root tl (lambda (path info) (send-thumbnail r path info)))))
           "GET" ("" "i" . tl) -> (wrap (lambda (r) (with-image r root tl (lambda (path info) (send-image r path info)))))
           "GET" ("" "x" . tl) -> (wrap (lambda (r) (with-image r root tl (lambda (path info) (send-info r path info)))))
           _ _ -> (maybe:no))
      (maybe:no) -> (maybe:no))))

;; --------------------------------------------------------------------------------
;; main

(define program-options
  (makeopt
   (arg 'root (string ""))
   (arg 'cert (string "cert.pem"))
   (arg 'key  (string "key.pem"))
   (arg 'log  (string "/var/log/irken-photos.log"))
   (arg 'users (string ""))
   (arg 'user (string ""))
   (arg 'cache (string ""))
   (arg 'heif-dec (string "heif-dec"))
   (flag 'open)
   (flag 'd)
   (pos 'addr (string "127.0.0.1:4433"))
   (flag 'h)
   ))

(define (usage)
  (printf "irken-photos: browse a photo archive over HTTP/2.\n\n")
  (printf "Usage: " sys.argv[0] " <addr> -root <dir>\n"
          "  -root <dir>      the photo archive\n"
          "  [-cert = cert.pem]\n"
          "  [-key = key.pem]\n"
          "  [-log = /var/log/irken-photos.log]\n"
          "  [-users <file>]  name:password lines; everything needs a login\n"
          "  [-open]          no login at all (only on a private network!)\n"
          "                   one of -users or -open is required.\n"
          "  [-cache <dir>]   convert HEIC to JPEG (for browsers other than Safari),\n"
          "                   keeping the results here\n"
          "  [-heif-dec = heif-dec]  the converter (libheif's), run as\n"
          "                   <command> -q 85 <in.heic> <out.jpg>\n"
          "  [-user <name>]   after binding the port, run as this user\n"
          "  [-d] print debugging output\n"
          "  [-h] print this usage.\n"
          "\n"
          "example: $ " sys.argv[0] " 0.0.0.0:8444 -root /photos -users photo-users\n"
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

(define (split-addr addr)
  (match (string-split addr #\:) with
    (ip port) -> (:tuple ip (string->int port))
    (ip)      -> (:tuple ip 443)
    _         -> (usage)
    ))

(define (main)
  (let ((opts (get-options))
        (addr "127.0.0.1:4433")
        (root "")
        (cert "cert.pem")
        (key  "key.pem")
        (log  "/var/log/irken-photos.log")
        (users (maybe:no))
        (open? #f)
        (user (maybe:no)))
    (when-maybe v (get-bool-opt opts 'h) (usage))
    (when-maybe v (get-string-opt opts 'root) (set! root v))
    (when-maybe v (get-string-opt opts 'cert) (set! cert v))
    (when-maybe v (get-string-opt opts 'key)  (set! key v))
    (when-maybe v (get-string-opt opts 'log)  (set! log v))
    (when-maybe v (get-string-opt opts 'addr) (set! addr v))
    (when-maybe v (get-string-opt opts 'users) (when (> (string-length v) 0) (set! users (maybe:yes v))))
    (when-maybe v (get-string-opt opts 'user) (when (> (string-length v) 0) (set! user (maybe:yes v))))
    (when-maybe v (get-bool-opt opts 'open) (set! open? v))
    (when-maybe v (get-string-opt opts 'cache) (set! *cache* v))
    (when-maybe v (get-string-opt opts 'heif-dec) (set! *heif-dec* v))
    (set! *debugf* #f)
    (when-maybe v (get-bool-opt opts 'd) (set! *debugf* v))
    (set-verbose-gc *debugf*)
    ;; a trailing slash would make "//" in paths.
    (while (and (> (string-length root) 1) (ends-with root "/"))
      (set! root (substring root 0 (- (string-length root) 1))))
    (when (not (isdir? root))
      (printf "-root: " (string root) " is not a directory\n")
      (usage))
    (when (and (eq? users (maybe:no)) (not open?))
      (printf "one of -users <file> or -open is needed.\n")
      (usage))
    (let ((creds (try
                  (load-creds cert key)
                  except
                  (:Serve/BadCreds why) -> (startup-failed why)))
          ((ip port) (split-addr addr))
          ;; /status/ (which can shut the server down) only with a login.
          (handlers (multi-handler
                     (append (if (eq? users (maybe:no)) (list:nil) (list (status-handler addr opts)))
                             (list favicon-handler (photo-handler root)))))
          (handler (h2-handler
                    (match users with
                      (maybe:yes path) -> (basic-auth-wrapper (load-users path) "photos" "/" handlers)
                      (maybe:no) -> (begin (logf "-open: no login needed") handlers)))))
      (set! *logfile* (maybe:yes (open-log log)))
      (logf "serving " root)
      (if (convert-heif?)
          (begin
            (make-cache-dirs)
            (logf "converting HEIC with " *heif-dec* ", into " *cache*)
            ;; (under rc(8), PATH may not have /usr/local/bin in it.)
            (when (not (= 0 (system (format "command -v " (sh-quote (first (string-split *heif-dec* #\space))) " >/dev/null"))))
              (logf "warning: can't find " *heif-dec* ": HEIC won't be converted (give -heif-dec a full path?)")))
          (logf "no -cache: HEIC images are sent as they are (only Safari can show them)"))
      (let ((sock (listen-on ip port)))
        (logf "listening on " addr)
        (when-maybe name user
          (try
           (begin
             (drop-privileges name)
             (logf "running as " name))
           except
           (:OSError e) -> (begin (logf "can't run as " name ": " (strerror e)) (%exit #f 1))
           (:Posix/NoSuchUser _) -> (begin (logf "no such user: " name) (%exit #f 1))
           (:Posix/StillRoot _) -> (begin (logf "still root after becoming " name) (%exit #f 1))))
        (reload-on-sighup creds cert key log)
        (serve sock (h2-channel handler creds '("h2"))))
      (poller/wait-and-schedule))))

(signal/ignore SIGPIPE)
(main)
