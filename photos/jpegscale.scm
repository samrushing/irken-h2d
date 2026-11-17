;; -*- Mode: Irken -*-

;; thumbnails for JPEGs that have none in their EXIF (scans, mostly):
;;  decoded at 1/8 (or 1/4, 1/2) scale by libjpeg, via photos/jpegthumb.c.
;;
;; the decode runs a few rows at a time.  between steps the thread
;;  sleeps for 0ms rather than calling poller/yield: poller/yield only
;;  lets the other runnable threads run, and the poller checks the
;;  sockets (kevent/epoll) only once nothing is runnable.  a sleep goes
;;  through the timer queue, so waiting connections get their turn.

(require-ffi 'jpegthumb)

(define jpeg/rows-per-step 32)

;; a JPEG whose long side is at least <target> pixels (if the image is
;;  that big), made from the JPEG at <path>.
(define (jpeg/scaled path target)
  (jpeg/scaled-range path 0 -1 target))

;; the same, for the JPEG at path[offset:offset+length] (length -1: to
;;  the end), e.g. a raw file's preview.
(define (jpeg/scaled-range path offset length target)
  (let ((h (jpegthumb/jt_open_range (cstring path) offset length target)))
    (if (cref-null? h)
        (maybe:no) ;; out of memory
        (let loop ()
          (let ((r (jpegthumb/jt_step h jpeg/rows-per-step)))
            (cond ((= r 1)
                   (timeq/sleep 0)
                   (loop))
                  ((= r 0)
                   (let ((size (jpegthumb/jt_size h))
                         (data (make-string size)))
                     ;; (no yielding here: the GC mustn't move <data> while
                     ;;  C is writing into it.)
                     (jpegthumb/jt_copy h (%string->cref #f data))
                     (jpegthumb/jt_close h)
                     (maybe:yes data)))
                  (else
                   (let ((msg (jpegthumb/jt_error h)))
                     (debugf "jpeg/scaled " path ": " (%cref->string #f msg (libc/strlen msg)) "\n"))
                   (jpegthumb/jt_close h)
                   (maybe:no))))))))
