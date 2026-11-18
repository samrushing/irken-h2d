;; -*- Mode: Irken -*-

;; things the browsers (photos/, source/) have in common: paths that
;;  can't climb out of the root, directory listings, JSON, responses
;;  (deflated, with etags), and the access log.

;; --------------------------------------------------------------------------------
;; paths

(define (extension name)
  (let ((parts (string-split name #\.)))
    (if (> (length parts) 1)
        (downcase (last parts))
        "")))

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

;; the subdirectories of <dir>, and its files for which (keep? name) is
;;  true, sorted.  (hidden ones aren't.)
(define (list-directory dir keep?)
  (let ((dirs (list:nil))
        (files (list:nil)))
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
            'regular   -> (when (keep? entry.name) (push! files entry.name))
            _          -> #u))))
    (:tuple (sort string<? dirs) (sort string<? files))))

;; the directories before and after <rel> in its parent (by name), as
;;  paths like <rel>'s; "" where there isn't one.
(define (sibling-dirs root rel)
  (let ((parts (string-split rel #\/))
        (n (length parts)))
    (if (string=? rel "")
        (:tuple "" "")
        (let ((parent (string-join (take parts (- n 1)) "/"))
              (name (last parts))
              ((dirs _) (try
                         (list-directory (root-path root parent) (lambda (name) #f))
                         except
                         (:OSError _) -> (:tuple (list:nil) (list:nil))))
              (prev "")
              (next ""))
          (define (path-of d) (if (string=? parent "") d (format parent "/" d)))
          (let loop ((dirs dirs) (before (maybe:no)))
            (match dirs with
              () -> #u
              (d . tl)
              -> (if (string=? d name)
                     (begin
                       (when-maybe b before (set! prev (path-of b)))
                       (match tl with
                         (nx . _) -> (set! next (path-of nx))
                         () -> #u))
                     (loop tl (maybe:yes d)))))
          (:tuple prev next)))))

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

;; --------------------------------------------------------------------------------
;; files

;; the first <n> bytes of the file at <path> (fewer if it's shorter).
(define (read-head path n)
  (read-at path n 0))

;; <n> bytes at <offset> in the file at <path>.
(define (read-at path n offset)
  (let ((fd (open path O_RDONLY 0)))
    (try
     (let ((r (pread fd n offset)))
       (close fd)
       r)
     except
     EXN -> (begin (close fd) (raise EXN)))))

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
  (send-file-as request path info (get-mime-type path)))

(define (send-file-as request path info type)
  (let ((etag (file-etag info)))
    (cond ((etag-matches? request etag)
           (request.send-headers "304" (list (:tuple "etag" etag) cache-control) #f))
          ((= 0 info.size)
           (request.send-headers "200" (list (:tuple "etag" etag)) #f))
          (else
           (request.send-headers "200"
                                 (list (:tuple "content-type" type)
                                       (:tuple "content-length" (int->string info.size))
                                       (:tuple "etag" etag)
                                       cache-control)
                                 #t)
           (request.send-with-generator (file-closing-generator path))))))

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

;; a handler's (maybe fun) for a request: <fun>, with a missing file
;;  (or anything else the OS says no to) as a 404, and logged.
(define (handle-with fun)
  (maybe:yes
   (lambda (request)
     (try
      (fun request)
      except
      (:OSError _) -> (send-404 request))
     (log-request request))))
