;; -*- Mode: Irken -*-

;; HEIF (ISO/IEC 23008-12), as iPhones write it: enough to find the
;;  primary image's size, its EXIF, and its thumbnail.
;;
;; browsers can't show a HEIF item on its own, so the thumbnail is
;;  served as a small HEIF file of its own: the thumbnail item's coded
;;  data and properties (hvcC, ispe, colr, irot...) in a new container.
;;  only browsers that decode HEIC (Safari) can show those, as with the
;;  full images.

;; --------------------------------------------------------------------------------
;; boxes

;; the box at s[off:], which must end by <end>.  start/end: the box's
;;  bounds in <s>; body: where its contents start.
(define (box/at s off end)
  (let ((size0 (bytes/be32 s off))
        (type (bytes/sub s (+ off 4) 4)))
    (let (((size hdr)
           (cond ((= size0 1) (:tuple (bytes/be64 s (+ off 8)) 16)) ;; 64-bit size
                 ((= size0 0) (:tuple (- end off) 8))                ;; to the end
                 (else        (:tuple size0 8)))))
      (when (or (< size hdr) (> (+ off size) end))
        (raise (:Exif/Bad "bad box size")))
      {type=type start=off body=(+ off hdr) end=(+ off size)})))

;; the boxes in s[start:end].
(define (box/list s start end)
  (let loop ((off start) (acc (list:nil)))
    (if (>= (+ off 8) end)
        (reverse acc)
        (let ((box (box/at s off end)))
          (loop box.end (list:cons box acc))))))

(define (box/find boxes type)
  (let loop ((boxes boxes))
    (match boxes with
      () -> (maybe:no)
      (box . tl) -> (if (string=? box.type type) (maybe:yes box) (loop tl)))))

;; a FullBox's version: its contents start 4 bytes on.
(define (box/version s box)
  (bytes/u8 s box.body))

;; an unsigned integer of <size> bytes (0, 4 or 8), for iloc's fields.
(define (bytes/uint s off size)
  (cond ((= size 0) 0)
        ((= size 4) (bytes/be32 s off))
        ((= size 8) (bytes/be64 s off))
        (else (raise (:Exif/Bad "iloc field size")))))

;; --------------------------------------------------------------------------------
;; the meta box

;; s: the file's meta box (at s[0:]).  fields:
;;  primary: the primary item's ID
;;  items: (list {id type})
;;  locs:  (list {id method base extents=(list (:tuple offset length))})
;;  refs:  (list {type from to=(list int)})
;;  props: the property boxes (vector, numbered from 1 in ipma)
;;  assocs: (list {id props=(list int)})
;;  idat: the idat box, for construction_method 1.
(define (heif/parse-meta s)
  (let ((meta (box/at s 0 (string-length s)))
        (children (box/list s (+ meta.body 4) meta.end))
        (info {primary=0 items=(list:nil) locs=(list:nil) refs=(list:nil)
               props=(list->vector (list:nil)) assocs=(list:nil) idat=(maybe:no)}))

    (define (parse-pitm box)
      (set! info.primary
            (if (= 0 (box/version s box))
                (bytes/be16 s (+ box.body 4))
                (bytes/be32 s (+ box.body 4)))))

    (define (parse-iinf box)
      (let ((v (box/version s box))
            (first (+ box.body (if (= v 0) 6 8))))
        (for-list infe (box/list s first box.end)
          (when (string=? infe.type "infe")
            (let ((iv (box/version s infe))
                  (p (+ infe.body 4)))
              ;; versions 2 and 3 have the item type (0 and 1 don't).
              (cond ((= iv 2)
                     (push! info.items {id=(bytes/be16 s p) type=(bytes/sub s (+ p 4) 4)}))
                    ((= iv 3)
                     (push! info.items {id=(bytes/be32 s p) type=(bytes/sub s (+ p 6) 4)}))
                    (else #u)))))))

    (define (parse-iloc box)
      (let ((v (box/version s box))
            (p (+ box.body 4))
            (sizes (bytes/be16 s p))
            (offset-size (>> sizes 12))
            (length-size (logand (>> sizes 8) 15))
            (base-size (logand (>> sizes 4) 15))
            (index-size (if (> v 0) (logand sizes 15) 0))
            (count (if (< v 2) (bytes/be16 s (+ p 2)) (bytes/be32 s (+ p 2))))
            (pos (+ p (if (< v 2) 4 6))))
        (define (take n)
          (let ((r pos)) (set! pos (+ pos n)) r))
        (for-range i count
          (let ((id (if (< v 2) (bytes/be16 s (take 2)) (bytes/be32 s (take 4))))
                (method (if (> v 0) (logand (bytes/be16 s (take 2)) 15) 0))
                (dref (bytes/be16 s (take 2)))
                (base (bytes/uint s (take base-size) base-size))
                (nextents (bytes/be16 s (take 2)))
                (extents (list:nil)))
            (for-range j nextents
              (take index-size)
              (let ((off (bytes/uint s (take offset-size) offset-size))
                    (len (bytes/uint s (take length-size) length-size)))
                (push! extents (:tuple off len))))
            (push! info.locs {id=id method=method base=base extents=(reverse extents)})))))

    (define (parse-iref box)
      (let ((v (box/version s box))
            (idsize (if (= v 0) 2 4)))
        (define (get-id off)
          (if (= idsize 2) (bytes/be16 s off) (bytes/be32 s off)))
        (for-list ref (box/list s (+ box.body 4) box.end)
          (let ((from (get-id ref.body))
                (n (bytes/be16 s (+ ref.body idsize)))
                (to (list:nil)))
            (for-range i n
              (push! to (get-id (+ ref.body idsize 2 (* i idsize)))))
            (push! info.refs {type=ref.type from=from to=(reverse to)})))))

    (define (parse-iprp box)
      (let ((kids (box/list s box.body box.end)))
        (when-maybe ipco (box/find kids "ipco")
          (set! info.props (list->vector (box/list s ipco.body ipco.end))))
        (for-list ipma kids
          (when (string=? ipma.type "ipma")
            (let ((v (box/version s ipma))
                  (flags (logand (bytes/be32 s ipma.body) #xffffff))
                  (count (bytes/be32 s (+ ipma.body 4)))
                  (pos (+ ipma.body 8)))
              (for-range i count
                (let ((id (if (< v 1) (bytes/be16 s pos) (bytes/be32 s pos)))
                      (_ (set! pos (+ pos (if (< v 1) 2 4))))
                      (n (bytes/u8 s pos))
                      (props (list:nil)))
                  (set! pos (+ pos 1))
                  (for-range j n
                    ;; the top bit is "essential": we want the index.
                    (if (= 1 (logand flags 1))
                        (begin (push! props (logand (bytes/be16 s pos) #x7fff)) (set! pos (+ pos 2)))
                        (begin (push! props (logand (bytes/u8 s pos) #x7f)) (set! pos (+ pos 1)))))
                  (push! info.assocs {id=id props=(reverse props)}))))))))

    (for-list box children
      (match box.type with
        "pitm" -> (parse-pitm box)
        "iinf" -> (parse-iinf box)
        "iloc" -> (parse-iloc box)
        "iref" -> (parse-iref box)
        "iprp" -> (parse-iprp box)
        "idat" -> (set! info.idat (maybe:yes box))
        _      -> #u))
    info))

;; the meta box of the HEIF file at <path>, as a string.
(define (heif/read-meta path)
  (let ((head (read-head path 65536))
        (len (string-length head)))
    (when (not (and (> len 12) (string=? (substring head 4 8) "ftyp")))
      (raise (:Exif/Bad "not a HEIF file")))
    ;; walk the top-level boxes for meta: it's normally right after ftyp.
    ;;  (only the box headers have to be in <head>.)
    (let loop ((off 0))
      (when (> (+ off 16) len)
        (raise (:Exif/Bad "no meta box")))
      (let ((size0 (bytes/be32 head off))
            (type (substring head (+ off 4) (+ off 8)))
            (size (if (= size0 1) (bytes/be64 head (+ off 8)) size0)))
        (cond ((string=? type "meta")
               (when (> size (* 4 1024 1024)) (raise (:Exif/Bad "meta box too big")))
               (if (<= (+ off size) len)
                   (substring head off (+ off size))
                   (let ((meta (read-at path size off)))
                     (when (< (string-length meta) size) (raise (:Exif/Bad "truncated")))
                     meta)))
              ((< size 8) (raise (:Exif/Bad "no meta box")))
              (else (loop (+ off size))))))))

;; --------------------------------------------------------------------------------
;; items

(define (heif/item-type info id)
  (let loop ((items info.items))
    (match items with
      () -> ""
      (item . tl) -> (if (= item.id id) item.type (loop tl)))))

(define (heif/item-props info id)
  (let loop ((assocs info.assocs))
    (match assocs with
      () -> (list:nil)
      (a . tl) -> (if (= a.id id) a.props (loop tl)))))

;; the property box numbered <n> (from 1), as a string.
(define (heif/prop meta info n)
  (if (or (< n 1) (> n (vector-length info.props)))
      (raise (:Exif/Bad "bad property index"))
      (let ((box info.props[(- n 1)]))
        (substring meta box.start box.end))))

(define (heif/prop-type info n)
  (if (or (< n 1) (> n (vector-length info.props)))
      ""
      (let ((box info.props[(- n 1)]))
        box.type)))

;; the items whose <type> reference points at <to>.
(define (heif/refs-to info type to)
  (let ((r (list:nil)))
    (for-list ref info.refs
      (when (and (string=? ref.type type) (member? to ref.to =))
        (push! r ref.from)))
    (reverse r)))

;; the data of item <id>, read from the file at <path>.
(define (heif/item-data path meta info id)
  (let loop ((locs info.locs))
    (match locs with
      () -> (raise (:Exif/Bad "no location for item"))
      (loc . tl)
      -> (if (not (= loc.id id))
             (loop tl)
             (let ((parts (list:nil)))
               (for-list ext loc.extents
                 (match ext with
                   (:tuple off len)
                   -> (begin
                        (when (or (= len 0) (> len (* 16 1024 1024)))
                          (raise (:Exif/Bad "bad extent")))
                        (push! parts
                               (cond ((= loc.method 0)
                                      (let ((data (read-at path len (+ loc.base off))))
                                        (when (< (string-length data) len) (raise (:Exif/Bad "truncated")))
                                        data))
                                     ((= loc.method 1)
                                      (match meta info.idat with
                                        m (maybe:yes idat) -> (bytes/sub m (+ idat.body loc.base off) len)
                                        _ (maybe:no) -> (raise (:Exif/Bad "no idat"))))
                                     (else (raise (:Exif/Bad "unsupported construction method"))))))))
               (string-concat (reverse parts)))))))

(define (heif/read path)
  (let ((meta (heif/read-meta path)))
    (:tuple meta (heif/parse-meta meta))))

;; --------------------------------------------------------------------------------
;; EXIF

;; an Exif item starts with the offset of the TIFF header after it.
(define (heif/exif path meta info)
  (let loop ((items info.items))
    (match items with
      () -> (maybe:no)
      (item . tl)
      -> (if (string=? item.type "Exif")
             (let ((data (heif/item-data path meta info item.id))
                   (skip (bytes/be32 data 0)))
               (maybe:yes (exif/parse data (+ 4 skip))))
             (loop tl)))))

;; the primary item's size, from its ispe property.
(define (heif/size meta info id)
  (let loop ((props (heif/item-props info id)))
    (match props with
      () -> (:tuple 0 0)
      (n . tl)
      -> (if (string=? (heif/prop-type info n) "ispe")
             (let ((box info.props[(- n 1)]))
               (:tuple (bytes/be32 meta (+ box.body 4)) (bytes/be32 meta (+ box.body 8))))
             (loop tl)))))

(define (heif/read-exif path)
  (try
   (let (((meta info) (heif/read path))
         (r (match (heif/exif path meta info) with
              (maybe:yes exif) -> exif
              (maybe:no) -> (exif/empty))))
     ;; the size is the image's, after any transformations except irot:
     ;;  report it as stored, like EXIF's PixelXDimension.
     (match (heif/size meta info info.primary) with
       (:tuple w h) -> (when (> w 0) (set! r.width w) (set! r.height h)))
     (maybe:yes r))
   except
   (:Exif/Bad _) -> (maybe:no)))

;; --------------------------------------------------------------------------------
;; thumbnails

(define (bytes/box type payload)
  (string-concat (list (bytes/u32->string (+ 8 (string-length payload))) type payload)))

(define (bytes/fullbox type version flags payload)
  (bytes/box type (string-concat (list (bytes/u8->string version) (bytes/u24->string flags) payload))))

;; a HEIF file holding just one coded image: <props> are its property
;;  boxes (as strings), <data> its coded data.
(define (heif/make-single item-type props data)
  (let ((ftyp (bytes/box "ftyp" "heic\x00\x00\x00\x00mif1heic"))
        (hdlr (bytes/fullbox "hdlr" 0 0
                             (string-concat (list (bytes/u32->string 0) "pict"
                                                  (bytes/u32->string 0) (bytes/u32->string 0) (bytes/u32->string 0)
                                                  "\x00"))))
        (pitm (bytes/fullbox "pitm" 0 0 (bytes/u16->string 1)))
        (infe (bytes/fullbox "infe" 2 0
                             (string-concat (list (bytes/u16->string 1) (bytes/u16->string 0) item-type "\x00"))))
        (iinf (bytes/fullbox "iinf" 0 0 (string-append (bytes/u16->string 1) infe)))
        (nprops (length props))
        (indexes (map-range i nprops
                   ;; the decoder configuration and the transformations
                   ;;  are "essential": a reader must understand them.
                   (let ((type (substring (nth props i) 4 8)))
                     (bytes/u8->string
                      (logior (+ i 1)
                              (if (member? type '("hvcC" "irot" "imir" "clap") string=?) #x80 0))))))
        (ipma (bytes/fullbox "ipma" 0 0
                             (string-concat
                              (append (list (bytes/u32->string 1) (bytes/u16->string 1) (bytes/u8->string nprops))
                                      indexes))))
        (iprp (bytes/box "iprp" (string-append (bytes/box "ipco" (string-concat props)) ipma)))
        ;; iloc v0: 4-byte offsets and lengths, no base offset.  it's a
        ;;  fixed 30 bytes, so the data's offset is known before it's built.
        (meta-len (+ 12 (string-length hdlr) (string-length pitm) (string-length iinf)
                     (string-length iprp) 30))
        (data-offset (+ (string-length ftyp) meta-len 8))
        (iloc (bytes/fullbox "iloc" 0 0
                             (string-concat
                              (list (bytes/u8->string #x44) (bytes/u8->string 0)
                                    (bytes/u16->string 1)    ;; one item:
                                    (bytes/u16->string 1)    ;;  ID 1
                                    (bytes/u16->string 0)    ;;  in this file
                                    (bytes/u16->string 1)    ;;  one extent
                                    (bytes/u32->string data-offset)
                                    (bytes/u32->string (string-length data))))))
        (meta (bytes/fullbox "meta" 0 0 (string-concat (list hdlr pitm iinf iprp iloc)))))
    (assert (= (string-length meta) meta-len))
    (string-concat (list ftyp meta (bytes/box "mdat" data)))))

;; the thumbnail of the HEIF file at <path>, as a HEIF file of its own.
(define (heif/thumbnail path)
  (try
   (let (((meta info) (heif/read path)))
     (match (heif/refs-to info "thmb" info.primary) with
       () -> (maybe:no)
       (thumb . _)
       -> (let ((type (heif/item-type info thumb))
                (own (heif/item-props info thumb))
                (own-types (map (lambda (n) (heif/prop-type info n)) own))
                (extra (list:nil)))
            ;; the thumbnail may not carry the primary image's rotation or
            ;;  mirroring itself: if not, give it the primary's.
            (for-list n (heif/item-props info info.primary)
              (let ((t (heif/prop-type info n)))
                (when (and (or (string=? t "irot") (string=? t "imir"))
                           (not (member? t own-types string=?)))
                  (push! extra n))))
            (if (not (string=? type "hvc1"))
                (maybe:no)
                (maybe:yes
                 (heif/make-single
                  type
                  (map (lambda (n) (heif/prop meta info n)) (append own (reverse extra)))
                  (heif/item-data path meta info thumb)))))))
   except
   (:Exif/Bad _) -> (maybe:no)))
