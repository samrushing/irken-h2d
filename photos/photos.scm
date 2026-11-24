;; -*- Mode: Irken -*-

;; irken-photos: browse a photo archive over HTTP/2.
;;
;;   /b/<dir>/     a page of thumbnails for <dir>, with a viewer and slideshow
;;   /t/<file>     a thumbnail: a JPEG's EXIF thumbnail (with its
;;                 orientation), or else the JPEG decoded at 1/8 scale
;;                 (photos/jpegscale.scm); a HEIC's thumbnail item; a raw
;;                 file's smallest JPEG preview (photos/raw.scm); or else
;;                 the file
;;   /i/<file>     the file itself (a raw file: its biggest preview)
;;   /x/<file>     what we know about the file, as JSON
;;
;; a directory is listed when it's asked for, and JPEG thumbnails are
;;  read out of the files (a 64k read).  only HEIC conversions (-cache)
;;  are kept on the server.  browsers cache thumbnails and images
;;  (etags, max-age).
;;
;; build from the top of the irken-h2d tree: $ irken photos/photos.scm

(require "server.scm")
(require "webutil.scm")
(require "photos/exif.scm")
(require "photos/heif.scm")
(require "photos/jpegscale.scm")
(require "photos/raw.scm")
(require "photos/page.scm")
(require "lib/codecs/hex.scm")

;; --------------------------------------------------------------------------------
;; paths

(define (jpeg-extension? ext) (member? ext '("jpg" "jpeg" "jpe") string=?))
(define (heif-extension? ext) (member? ext '("heic" "heif") string=?))

(define image-extensions
  (append '("jpg" "jpeg" "jpe" "heic" "heif" "png" "gif" "webp" "avif")
          raw-extensions))

(define (image-name? name)
  (member? (extension name) image-extensions string=?))

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
                 (let (((dirs images) (list-directory dir image-name?))
                       ((prev next) (sibling-dirs root rel))
                       (data (format "{\"dir\":" (json-string rel)
                                     ",\"dirs\":" (json-list dirs)
                                     ",\"images\":" (json-list images)
                                     ",\"prev\":" (json-string prev)
                                     ",\"next\":" (json-string next) "}"))
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

(define (thumbnail path info)
  (let ((ext (extension path)))
    (cond ((jpeg-extension? ext)
           (match (jpeg/thumbnail path) with
             (maybe:yes data) -> (maybe:yes (:tuple "image/jpeg" data))
             (maybe:no) -> (match (scaled-thumbnail path info) with
                             (maybe:yes data) -> (maybe:yes (:tuple "image/jpeg" data))
                             (maybe:no) -> (maybe:no))))
          ((heif-extension? ext)
           (match (heif/thumbnail path) with
             (maybe:yes data) -> (maybe:yes (:tuple "image/heic" data))
             (maybe:no) -> (maybe:no)))
          ((raw-extension? ext)
           (match (raw-thumbnail path info) with
             (maybe:yes data) -> (maybe:yes (:tuple "image/jpeg" data))
             (maybe:no) -> (maybe:no)))
          (else (maybe:no)))))

;; a raw file's smallest preview, if it's small; if not (a NEF's only
;;  preview is full-size), that scaled down.  only previews the shape of
;;  the biggest: Sony's 160x120 thumbnails are 3:2 pictures with black
;;  bars in a 4:3 box.
(define (raw-thumbnail path info)
  (define (same-shape? a b)
    (let ((x (* a.width b.height))
          (y (* b.width a.height)))
      (<= (* 50 (abs (- x y))) x))) ;; within 2%
  (try
   (let ((r (raw/previews path))
         (big (match (reverse r.previews) with (p . _) -> (maybe:yes p) () -> (maybe:no)))
         (usable (match big with
                   (maybe:yes b) -> (filter (lambda (p) (same-shape? p b)) r.previews)
                   (maybe:no) -> (list:nil))))
     (match usable with
       () -> (maybe:no)
       (small . _)
       -> (if (<= (max small.width small.height) 640)
              (maybe:yes (raw/read-jpeg path small r.orientation))
              (cached-thumbnail
               path info
               (lambda ()
                 (match (jpeg/scaled-range path small.offset small.length 320) with
                   (maybe:yes data)
                   -> (maybe:yes (if (= r.orientation 1) data (jpeg/with-orientation data r.orientation)))
                   (maybe:no) -> (maybe:no)))))))
   except
   (:Exif/Bad _) -> (maybe:no)
   (:OSError _) -> (maybe:no)))

;; --------------------------------------------------------------------------------
;; HEIC, for browsers that can't show it (all but Safari): converted to
;;  JPEG by libheif's heif-dec, and kept in the -cache directory, which
;;  can be emptied at any time.  (the conversion holds up the server
;;  while it runs: ~30ms for a thumbnail, ~1s for a full image.)

(define *cache* "")            ;; -cache <dir>: "" means don't convert.
(define *heif-dec* "heif-dec") ;; -heif-dec <command>

(define (caching?) (not (string=? *cache* "")))

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
    (cond ((and (caching?) (heif-extension? ext))
           (send-converted request path info heif-full-jpeg))
          ((jpeg-extension? ext)
           (match (jpeg/read-exif path) with
             (maybe:yes exif)
             -> (match exif.stale exif.orientation-fix with
                  #t (maybe:yes (:tuple offset bytes)) -> (send-patched-file request path info offset bytes)
                  _ _ -> (send-file request path info))
             (maybe:no) -> (send-file request path info)))
          ((raw-extension? ext)
           (send-raw-preview request path info))
          (else (send-file request path info)))))

;; a raw file's biggest preview, with its orientation.  (never the raw
;;  file itself: the browser can't show it.)
(define (send-raw-preview request path info)
  (match (try
          (maybe:yes (raw/previews path))
          except
          (:Exif/Bad _) -> (maybe:no)) with
    (maybe:yes r)
    -> (match (reverse r.previews) with
         (big . _) -> (send-range request path info big.offset big.length (raw/orientation-app1 r.orientation))
         () -> (send-404 request))
    (maybe:no) -> (send-404 request)))

;; the JPEG at path[offset:offset+length], with <app1> (or "") put in
;;  after its SOI.
(define (send-range request path info offset length app1)
  (let ((etag (format "W/\"" (int info.mtime) "." (int info.size) ".p\"")))
    (if (etag-matches? request etag)
        (request.send-headers "304" (list (:tuple "etag" etag) cache-control) #f)
        (let ((fd (open path O_RDONLY 0)))
          (request.send-headers "200"
                                (list (:tuple "content-type" "image/jpeg")
                                      (:tuple "content-length" (int->string (+ length (string-length app1))))
                                      (:tuple "etag" etag)
                                      cache-control)
                                #t)
          (request.send-with-generator
           (makegen emit
             (emit (string-append "\xff\xd8" app1))
             (let loop ((pos (+ offset 2)) (left (- length 2)))
               (when (> left 0)
                 (let ((buf (pread fd (min left 16384) pos)))
                   (when (> (string-length buf) 0)
                     (emit buf)
                     (loop (+ pos (string-length buf)) (- left (string-length buf)))))))
             (close fd)
             #u))))))

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
  (if (and (caching?) (heif-extension? (extension path)))
      (send-converted request path info heif-thumbnail-jpeg)
      (send-native-thumbnail request path info)))

;; a JPEG with no EXIF thumbnail, scaled down (and kept, with -cache).
(define (scaled-thumbnail path info)
  (cached-thumbnail
   path info
   (lambda ()
     (match (jpeg/scaled path 320) with
       (maybe:yes data)
       -> (maybe:yes
           (match (jpeg/read-exif path) with
             (maybe:yes exif)
             -> (if (or (= exif.orientation 1) exif.stale)
                    data
                    (jpeg/with-orientation data exif.orientation))
             (maybe:no) -> data))
       (maybe:no) -> (maybe:no)))))

;; (make) makes a thumbnail: with -cache, it's kept.
(define (cached-thumbnail path info make)
  (if (not (caching?))
      (make)
      (let ((cached (format (cache-name path info "-s") ".jpg")))
        (if (isfile? cached)
            (let ((cinfo (stat cached)))
              (maybe:yes (read-at cached cinfo.size 0)))
            (match (make) with
              (maybe:yes data)
              -> (begin
                   ;; (nothing else runs while this is written: no other
                   ;;  request can see half of it.)
                   (write-file cached data)
                   (maybe:yes data))
              (maybe:no) -> (maybe:no))))))

;; (the "t" keeps a browser from holding on to what it got from /t/
;;  before there were scaled thumbnails: the whole file, with the file's
;;  etag.)
(define (send-native-thumbnail request path info)
  (let ((etag (format "W/\"" (int info.mtime) "." (int info.size) ".t\"")))
    (if (etag-matches? request etag)
        (request.send-headers "304" (list (:tuple "etag" etag) cache-control) #f)
        (match (thumbnail path info) with
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
          ;;  (not a raw file, which it can't show.)
          (maybe:no) -> (if (raw-extension? (extension path))
                            (send-404 request)
                            (send-file request path info))))))

;; a raw file's EXIF (it's TIFF: IFD0 is at the start), with the size of
;;  its biggest preview if EXIF doesn't say.
(define (raw-exif path)
  (try
   (let ((exif (exif/parse (read-head path 65536) 0)))
     (when (= exif.width 0)
       (match (let ((r (raw/previews path))) (reverse r.previews)) with
         (big . _) -> (begin (set! exif.width big.width) (set! exif.height big.height))
         () -> #u))
     (maybe:yes exif))
   except
   (:Exif/Bad _) -> (maybe:no)))

(define (send-info request path info)
  (let ((ext (extension path))
        (mexif (cond ((jpeg-extension? ext) (jpeg/read-exif path))
                     ((heif-extension? ext) (heif/read-exif path))
                     ((raw-extension? ext) (raw-exif path))
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
                       ",\"gps\":" (json-string exif.gps)
                       "}"))))

(define (photo-handler root)
  (define wrap handle-with)
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
   (arg 'passkeys (string ""))
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
          "  [-passkeys <file>] passkeys (see README.md); everything needs a login\n"
          "  [-open]          no login at all (only on a private network!)\n"
          "                   one of -users, -passkeys or -open is required.\n"
          "  [-cache <dir>]   convert HEIC to JPEG (for browsers other than Safari),\n"
          "                   and keep those and scaled-down JPEG thumbnails here\n"
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

(define (main)
  (let ((opts (get-options))
        (addr "127.0.0.1:4433")
        (root "")
        (cert "cert.pem")
        (key  "key.pem")
        (log  "/var/log/irken-photos.log")
        (users (maybe:no))
        (passkeys (maybe:no))
        (open? #f)
        (user (maybe:no)))
    (when-maybe v (get-bool-opt opts 'h) (usage))
    (when-maybe v (get-string-opt opts 'root) (set! root v))
    (when-maybe v (get-string-opt opts 'cert) (set! cert v))
    (when-maybe v (get-string-opt opts 'key)  (set! key v))
    (when-maybe v (get-string-opt opts 'log)  (set! log v))
    (when-maybe v (get-string-opt opts 'addr) (set! addr v))
    (when-maybe v (get-string-opt opts 'users) (when (> (string-length v) 0) (set! users (maybe:yes v))))
    (when-maybe v (get-string-opt opts 'passkeys) (when (> (string-length v) 0) (set! passkeys (maybe:yes v))))
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
    (when (and (eq? users (maybe:no)) (eq? passkeys (maybe:no)) (not open?))
      (printf "one of -users <file>, -passkeys <file> or -open is needed.\n")
      (usage))
    (run-server
     addr opts cert key log user users passkeys "photos" (photo-handler root)
     (lambda ()
       (logf "serving " root)
       (if (caching?)
           (begin
             (make-cache-dirs)
             (logf "converting HEIC with " *heif-dec* ", into " *cache*)
             ;; (under rc(8), PATH may not have /usr/local/bin in it.)
             (when (not (= 0 (system (format "command -v " (sh-quote (first (string-split *heif-dec* #\space))) " >/dev/null"))))
               (logf "warning: can't find " *heif-dec* ": HEIC won't be converted (give -heif-dec a full path?)")))
           (logf "no -cache: HEIC images are sent as they are (only Safari can show them)"))))))

(signal/ignore SIGPIPE)
(main)
