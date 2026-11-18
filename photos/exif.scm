;; -*- Mode: Irken -*-

;; just enough EXIF for a photo browser: orientation, date, camera,
;;  pixel size, location (GPS), and the embedded JPEG thumbnail (IFD1).  the TIFF
;;  structure comes from a JPEG's APP1 segment or a HEIF's Exif item
;;  (see heif.scm).
;;
;; any malformation raises (:Exif/Bad why); callers treat that as "no
;;  EXIF", so nothing here has to be careful about anything but bounds.

;; --------------------------------------------------------------------------------
;; bytes in strings

(define (bytes/u8 s i)
  (if (or (< i 0) (>= i (string-length s)))
      (raise (:Exif/Bad "truncated"))
      (char->int (string-ref s i))))

(define (bytes/be16 s i) (logior (<< (bytes/u8 s i) 8) (bytes/u8 s (+ i 1))))
(define (bytes/be32 s i) (logior (<< (bytes/be16 s i) 16) (bytes/be16 s (+ i 2))))
(define (bytes/be64 s i) (logior (<< (bytes/be32 s i) 32) (bytes/be32 s (+ i 4))))
(define (bytes/le16 s i) (logior (bytes/u8 s i) (<< (bytes/u8 s (+ i 1)) 8)))
(define (bytes/le32 s i) (logior (bytes/le16 s i) (<< (bytes/le16 s (+ i 2)) 16)))

;; s[start:start+len], or (:Exif/Bad) if that isn't all there.
(define (bytes/sub s start len)
  (if (or (< start 0) (< len 0) (> (+ start len) (string-length s)))
      (raise (:Exif/Bad "truncated"))
      (substring s start (+ start len))))

;; big-endian integers as strings, for building files.
(define (bytes/u8->string n)
  (char->string (int->char (logand n #xff))))
(define (bytes/u16->string n)
  (string-append (bytes/u8->string (>> n 8)) (bytes/u8->string n)))
(define (bytes/u24->string n)
  (string-append (bytes/u8->string (>> n 16)) (bytes/u16->string n)))
(define (bytes/u32->string n)
  (string-append (bytes/u16->string (>> n 16)) (bytes/u16->string n)))

;; --------------------------------------------------------------------------------
;; TIFF/EXIF

;; orientation-fix: where the orientation is in the file, and the bytes
;;  that would make it 1 (see jpeg/stale-orientation?).
;; gps: "<latitude>,<longitude>" in degrees, or "".
(define (exif/empty)
  {orientation=1 date="" make="" model="" width=0 height=0 thumb=(maybe:no)
   orientation-fix=(maybe:no) stale=#f gps=""})

;; ASCII values are NUL-terminated, and often padded with spaces.
(define (trim-ascii s)
  (let loop ((n (string-length s)))
    (if (and (> n 0)
             (let ((ch (string-ref s (- n 1))))
               (or (eq? ch #\nul) (eq? ch #\space))))
        (loop (- n 1))
        (substring s 0 n))))

;; a TIFF structure at s[base:]: offsets inside it are relative to <base>.
(define (tiff/make s base)
  (let ((order (bytes/sub s base 2)))
    (cond ((string=? order "II") {s=s base=base little=#t})
          ((string=? order "MM") {s=s base=base little=#f})
          (else (raise (:Exif/Bad "byte order"))))))

(define (tiff/u16 t off)
  (if t.little (bytes/le16 t.s (+ t.base off)) (bytes/be16 t.s (+ t.base off))))
(define (tiff/u32 t off)
  (if t.little (bytes/le32 t.s (+ t.base off)) (bytes/be32 t.s (+ t.base off))))

;; the entries of the IFD at <off>.  <at> is the offset of each entry's
;;  4-byte value field, which holds the value if it fits, or else the
;;  value's offset.
(define (tiff/entries t off)
  (let ((n (tiff/u16 t off)))
    (when (> n 1000) (raise (:Exif/Bad "IFD too big")))
    (let loop ((i 0) (acc (list:nil)))
      (if (= i n)
          (reverse acc)
          (let ((e (+ off 2 (* i 12))))
            (loop (+ i 1)
                  (list:cons {tag=(tiff/u16 t e) type=(tiff/u16 t (+ e 2))
                              count=(tiff/u32 t (+ e 4)) at=(+ e 8)}
                             acc)))))))

(define (tiff/next-ifd t off)
  (tiff/u32 t (+ off 2 (* 12 (tiff/u16 t off)))))

;; SHORT (3) or LONG (4).
(define (tiff/int t e)
  (cond ((= e.type 3) (tiff/u16 t e.at))
        ((= e.type 4) (tiff/u32 t e.at))
        (else 0)))

;; ASCII (2).
(define (tiff/ascii t e)
  (if (or (not (= e.type 2)) (> e.count 1000))
      ""
      (let ((off (if (<= e.count 4) e.at (tiff/u32 t e.at))))
        (trim-ascii (bytes/sub t.s (+ t.base off) e.count)))))

;; a GPS latitude or longitude: three RATIONALs (5), degrees, minutes
;;  and seconds (often with the fraction in the minutes, and 0 seconds).
;;  in millionths of a degree, since there are no floats.
(define (tiff/degrees t e)
  (if (or (not (= e.type 5)) (< e.count 3))
      (maybe:no)
      (let ((off (tiff/u32 t e.at)))
        (define (part i div)
          (let ((num (tiff/u32 t (+ off (* 8 i))))
                (den (tiff/u32 t (+ off (* 8 i) 4))))
            (if (= den 0)
                (raise (:Exif/Bad "GPS rational"))
                (/ (* num 1000000) (* den div)))))
        (maybe:yes (+ (part 0 1) (+ (part 1 60) (part 2 3600)))))))

;; millionths of a degree, as a decimal.
(define (micro->string n)
  (let ((a (if (< n 0) (- 0 n) n)))
    (format (if (< n 0) "-" "") (int (/ a 1000000)) "." (zpad 6 (int (mod a 1000000))))))

;; the EXIF in the TIFF structure at s[base:].
(define (exif/parse s base)
  (let ((t (tiff/make s base))
        (info (exif/empty)))

    ;; the Exif sub-IFD: DateTimeOriginal, and the pixel dimensions.
    (define (exif-ifd off)
      (for-list e (tiff/entries t off)
        (cond ((= e.tag #x9003) (set! info.date (tiff/ascii t e)))
              ((= e.tag #xa002) (set! info.width (tiff/int t e)))
              ((= e.tag #xa003) (set! info.height (tiff/int t e)))
              (else #u))))

    ;; the GPS IFD: GPSLatitudeRef (N/S), GPSLatitude, GPSLongitudeRef
    ;;  (E/W), GPSLongitude.  (0,0) is a phone that had no fix.
    (define (gps-ifd off)
      (let ((lat-ref "") (lon-ref "") (lat (maybe:no)) (lon (maybe:no)))
        (for-list e (tiff/entries t off)
          (cond ((= e.tag 1) (set! lat-ref (tiff/ascii t e)))
                ((= e.tag 2) (set! lat (tiff/degrees t e)))
                ((= e.tag 3) (set! lon-ref (tiff/ascii t e)))
                ((= e.tag 4) (set! lon (tiff/degrees t e)))
                (else #u)))
        (match lat lon with
          (maybe:yes a) (maybe:yes b)
          -> (when (not (and (= a 0) (= b 0)))
               (set! info.gps (format (micro->string (if (string=? lat-ref "S") (- 0 a) a)) ","
                                      (micro->string (if (string=? lon-ref "W") (- 0 b) b)))))
          _ _ -> #u)))

    ;; IFD1, the thumbnail's: JPEGInterchangeFormat{,Length}.
    (define (thumb-ifd off)
      (let ((start 0) (len 0))
        (for-list e (tiff/entries t off)
          (cond ((= e.tag #x0201) (set! start (tiff/int t e)))
                ((= e.tag #x0202) (set! len (tiff/int t e)))
                (else #u)))
        (when (and (> start 0) (> len 2))
          (let ((thumb (bytes/sub s (+ base start) len)))
            ;; it should be a JPEG.
            (when (and (= (bytes/u8 thumb 0) #xff) (= (bytes/u8 thumb 1) #xd8))
              (set! info.thumb (maybe:yes thumb)))))))

    (let ((ifd0 (tiff/u32 t 4)))
      (for-list e (tiff/entries t ifd0)
        (cond ((= e.tag #x0112)
               (set! info.orientation (tiff/int t e))
               (when (= e.type 3)
                 (set! info.orientation-fix
                       (maybe:yes (:tuple (+ base e.at) (if t.little "\x01\x00" "\x00\x01"))))))
              ;; DateTime: only if there's no DateTimeOriginal.
              ((= e.tag #x0132) (when (string=? info.date "") (set! info.date (tiff/ascii t e))))
              ((= e.tag #x010f) (set! info.make (tiff/ascii t e)))
              ((= e.tag #x0110) (set! info.model (tiff/ascii t e)))
              ((= e.tag #x8769)
               ;; a bad sub-IFD shouldn't lose the rest.
               (try (exif-ifd (tiff/u32 t e.at)) except (:Exif/Bad _) -> #u))
              ((= e.tag #x8825)
               (try (gps-ifd (tiff/u32 t e.at)) except (:Exif/Bad _) -> #u))
              (else #u)))
      (when (or (< info.orientation 1) (> info.orientation 8))
        (set! info.orientation 1))
      (try
       (let ((ifd1 (tiff/next-ifd t ifd0)))
         (when (> ifd1 0)
           (thumb-ifd ifd1)))
       except
       (:Exif/Bad _) -> #u)
      info)))

;; a minimal EXIF APP1 segment holding only an orientation, so that a
;;  browser shows a thumbnail (which has no EXIF of its own) the right
;;  way up.
(define (exif/orientation-app1 orientation)
  (let ((tiff (string-concat
               (list "MM" (bytes/u16->string 42) (bytes/u32->string 8)
                     (bytes/u16->string 1) ;; one entry:
                     (bytes/u16->string #x0112) (bytes/u16->string 3) (bytes/u32->string 1)
                     (bytes/u16->string orientation) (bytes/u16->string 0)
                     (bytes/u32->string 0))))) ;; no next IFD.
    (string-concat
     (list "\xff\xe1" (bytes/u16->string (+ 2 6 (string-length tiff)))
           "Exif\x00\x00" tiff))))

;; --------------------------------------------------------------------------------
;; JPEG

(datatype jpeg-scan
  (:exif int int) ;; the TIFF header's offset, and the end of the APP1 segment.
  (:more int)     ;; it's further on: read at least this much.
  (:none)
  )

;; find the Exif APP1 segment in the start of a JPEG file.
(define (jpeg/scan s)
  (let ((len (string-length s)))
    (if (not (and (>= len 4) (= (bytes/u8 s 0) #xff) (= (bytes/u8 s 1) #xd8)))
        (jpeg-scan:none)
        (let loop ((pos 2))
          (if (> (+ pos 10) len)
              (jpeg-scan:more (+ pos 65536))
              (let ((m0 (bytes/u8 s pos))
                    (m (bytes/u8 s (+ pos 1))))
                (cond ((not (= m0 #xff)) (jpeg-scan:none))
                      ((= m #xff) (loop (+ pos 1))) ;; fill byte
                      ;; start of scan or end of image: no EXIF.
                      ((or (= m #xda) (= m #xd9)) (jpeg-scan:none))
                      (else
                       (let ((seglen (bytes/be16 s (+ pos 2))))
                         (if (and (= m #xe1) (string=? (substring s (+ pos 4) (+ pos 10)) "Exif\x00\x00"))
                             (jpeg-scan:exif (+ pos 10) (+ pos 2 seglen))
                             (loop (+ pos 2 seglen))))))))))))

;; the size of the image in a JPEG, from its SOF segment.
(define (jpeg/frame-size s)
  (match (jpeg/frame s) with
    (maybe:yes f) -> (maybe:yes (:tuple f.width f.height))
    (maybe:no) -> (maybe:no)))

;; a JPEG's SOF segment: which kind (0 baseline, 1 extended, 2
;;  progressive, 3 lossless...), and the size.
(define (jpeg/frame s)
  (try
   (let loop ((pos 2))
     (if (> (+ pos 9) (string-length s))
         (maybe:no)
         (let ((m (bytes/u8 s (+ pos 1))))
           (cond ((not (= (bytes/u8 s pos) #xff)) (maybe:no))
                 ((= m #xff) (loop (+ pos 1)))
                 ((or (= m #xda) (= m #xd9)) (maybe:no))
                 ;; SOF0..15, except DHT (c4), JPG (c8) and DAC (cc).
                 ((and (>= m #xc0) (<= m #xcf) (not (member? m '(#xc4 #xc8 #xcc) =)))
                  (maybe:yes {sof=(- m #xc0) width=(bytes/be16 s (+ pos 7)) height=(bytes/be16 s (+ pos 5))}))
                 (else (loop (+ pos 2 (bytes/be16 s (+ pos 2)))))))))
   except
   (:Exif/Bad _) -> (maybe:no)))

;; a tool that rotated the pixels of a JPEG but left its orientation tag
;;  alone (common in the early 2000s) leaves a picture that a browser
;;  turns a second time.  that's given away by the size: the frame is
;;  the other way round from EXIF's PixelXDimension/PixelYDimension
;;  (which describe the image as the camera stored it).  <frame> is the
;;  JPEG's size: the main image's, or the thumbnail's.
(define (jpeg/stale-orientation? info frame)
  (match frame with
    (maybe:yes (:tuple w h))
    -> (and (>= info.orientation 5)
            (> info.width 0) (> info.height 0)
            (not (= info.width info.height))
            (not (eq? (> info.width info.height) (> w h))))
    (maybe:no) -> #f))

;; the EXIF of the JPEG file at <path>.
(define (jpeg/read-exif path)
  (try
   (let loop ((n 65536))
     (let ((head (read-head path n))
           (got (string-length head)))
       (match (jpeg/scan head) with
         (jpeg-scan:exif tiff end)
         -> (if (and (> end got) (= got n))
                (loop end) ;; the segment goes on past what we read.
                (let ((info (exif/parse head tiff)))
                  (set! info.stale (jpeg/stale-orientation? info (jpeg/frame-size head)))
                  (maybe:yes info)))
         (jpeg-scan:more want)
         -> (if (and (= got n) (< want (* 4 1024 1024)))
                (loop want)
                (maybe:no))
         (jpeg-scan:none)
         -> (maybe:no))))
   except
   (:Exif/Bad _) -> (maybe:no)))

;; the JPEG's embedded thumbnail, with its orientation, if it has one.
(define (jpeg/thumbnail path)
  (match (jpeg/read-exif path) with
    (maybe:yes info)
    -> (match info.thumb with
         (maybe:yes thumb)
         -> (maybe:yes
             ;; (the thumbnail might have been rotated too.)
             (if (or (= info.orientation 1)
                     (jpeg/stale-orientation? info (jpeg/frame-size thumb)))
                 thumb
                 (jpeg/with-orientation thumb info.orientation)))
         (maybe:no) -> (maybe:no))
    (maybe:no) -> (maybe:no)))

;; <jpeg> (which has no EXIF), with an APP1 holding just <orientation>.
(define (jpeg/with-orientation jpeg orientation)
  (string-concat
   (list "\xff\xd8"
         (exif/orientation-app1 orientation)
         (substring jpeg 2 (string-length jpeg)))))
