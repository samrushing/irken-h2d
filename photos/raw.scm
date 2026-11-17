;; -*- Mode: Irken -*-

;; raw files that are TIFF inside (NEF, ARW, CR2, DNG): browsers can't
;;  show them, but they carry JPEG previews, made by the camera.  where,
;;  varies:
;;
;;   ARW  IFD1: a 160x120 thumbnail; IFD0: a ~1600x1080 preview
;;   NEF  SubIFD0: a full-size preview (IFD0 is a 160x120 RGB strip)
;;   CR2  IFD1: a 160x120 thumbnail; IFD0's strip: a 1600x1200 preview
;;        (IFD2 says it's JPEG but isn't, and IFD3 is the raw data, as
;;        lossless JPEG)
;;
;; so: every JPEG that any IFD (or SubIFD) points at, by
;;  JPEGInterchangeFormat or by a single JPEG-compressed strip, that
;;  starts like a JPEG and is one a browser can decode (SOF0..2).  the
;;  smallest is the thumbnail, the biggest is what the viewer shows.
;;  neither has EXIF of its own: the orientation comes from IFD0.

(define raw-extensions '("nef" "arw" "cr2" "dng"))

(define (raw-extension? ext) (member? ext raw-extensions string=?))

;; <n> bytes at <off> in the file: from <head> if they're in it, or else
;;  read.
(define (raw/bytes path head off n)
  (if (<= (+ off n) (string-length head))
      (substring head off (+ off n))
      (let ((s (read-at path n off)))
        (when (< (string-length s) n) (raise (:Exif/Bad "truncated")))
        s)))

;; {orientation previews=(list {offset length width height})}, the
;;  previews smallest first.
(define (raw/previews path)
  (let ((head (read-head path 65536))
        (little (cond ((string=? (bytes/sub head 0 2) "II") #t)
                      ((string=? (bytes/sub head 0 2) "MM") #f)
                      (else (raise (:Exif/Bad "not TIFF")))))
        (orientation 1)
        (found (list:nil))
        (seen (list:nil)))

    (define (u16 s i) (if little (bytes/le16 s i) (bytes/be16 s i)))
    (define (u32 s i) (if little (bytes/le32 s i) (bytes/be32 s i)))

    ;; a candidate: keep it if it's a JPEG a browser can decode.
    (define (candidate offset length)
      (when (and (> offset 0) (> length 100))
        (let ((start (raw/bytes path head offset (min length 65536))))
          (when (and (= (bytes/u8 start 0) #xff) (= (bytes/u8 start 1) #xd8))
            (match (jpeg/frame start) with
              (maybe:yes f)
              -> (when (and (<= f.sof 2) (> f.width 0))
                   (push! found {offset=offset length=length width=f.width height=f.height}))
              (maybe:no) -> #u)))))

    ;; the IFD at <off>, its SubIFDs, and (if <chain>) the IFDs after it.
    (define (walk off depth chain)
      (when (and (> off 0) (< depth 4) (not (member? off seen =)) (< (length seen) 32))
        (push! seen off)
        (let ((n (u16 (raw/bytes path head off 2) 0))
              (block (raw/bytes path head (+ off 2) (+ 4 (* 12 n))))
              (jif 0) (jlen 0) (comp 0) (strip 0) (nstrips 0) (strip-len 0)
              (subs (list:nil)))
          (when (> n 1000) (raise (:Exif/Bad "IFD too big")))
          (for-range i n
            (let ((e (* 12 i))
                  (tag (u16 block e))
                  (type (u16 block (+ e 2)))
                  (count (u32 block (+ e 4)))
                  (value (if (= type 3) (u16 block (+ e 8)) (u32 block (+ e 8)))))
              (cond ((= tag #x0112) (when (and (= off (u32 head 4)) (>= value 1) (<= value 8))
                                      (set! orientation value)))
                    ((= tag #x0201) (set! jif value))
                    ((= tag #x0202) (set! jlen value))
                    ((= tag #x0103) (set! comp value))
                    ((= tag #x0111) (set! strip value) (set! nstrips count))
                    ((= tag #x0117) (set! strip-len value))
                    ((= tag #x014a)
                     ;; SubIFDs: one offset in the entry, or an array of them.
                     (if (= count 1)
                         (push! subs value)
                         (let ((arr (raw/bytes path head value (* 4 (min count 8)))))
                           (for-range j (min count 8)
                             (push! subs (u32 arr (* 4 j)))))))
                    (else #u))))
          (try (candidate jif jlen) except (:Exif/Bad _) -> #u)
          (when (and (= comp 6) (= nstrips 1))
            (try (candidate strip strip-len) except (:Exif/Bad _) -> #u))
          (for-list sub (reverse subs)
            (try (walk sub (+ depth 1) #f) except (:Exif/Bad _) -> #u))
          (when chain
            (walk (u32 block (* 12 n)) depth #t)))))

    (walk (u32 head 4) 0 #t)
    {orientation=orientation
     previews=(sort (lambda (a b) (< (* a.width a.height) (* b.width b.height))) found)}))

;; with its orientation, if it needs one: the APP1 to put after SOI.
(define (raw/orientation-app1 orientation)
  (if (= orientation 1) "" (exif/orientation-app1 orientation)))

;; a preview (or the thumbnail) from the file, with the orientation.
(define (raw/read-jpeg path p orientation)
  (let ((data (read-at path p.length p.offset)))
    (if (= orientation 1)
        data
        (jpeg/with-orientation data orientation))))
