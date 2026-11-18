;; -*- Mode: Irken -*-

;; Irken source as HTML, highlighted the way irken.el does it: keywords
;;  (at the head of a form), the names being defined, constructors
;;  (anything with a colon: maybe:yes, :tuple), ->, and the usual
;;  comments, strings, characters and numbers.
;;
;; each top-level definition gets an anchor (#d-<name>), and the uses of
;;  its name link there.  each line gets one too (#L<n>).
;;
;; two passes: (lex s) makes tokens, (classify tokens) decides what each
;;  one is and collects the top-level definitions; then they're rendered.

(datatype tok
  (:comment string)
  (:string string)
  (:char string)   ;; #\a, #\space
  (:open string)   ;; ( [ { #(
  (:close string)
  (:quote string)  ;; ' ` ,
  (:space string)
  (:atom string)   ;; symbols, numbers, #t, #x1f...
  )

(define (char-code ch) (char->int ch))

;; (these aren't written as #\" etc.: the reader's ideas about those
;;  aren't worth testing here.)
(define (delimiter? ch)
  (member? (char-code ch) '(32 9 10 13 40 41 91 93 123 125 34 59 39 96 44) =))

(define (space? ch)
  (member? (char-code ch) '(32 9 10 13 12) =))

(define (lex s)
  (let ((n (string-length s))
        (toks (list:nil)))
    (define (ch i) (char-code (string-ref s i)))
    (define (take kind start end)
      (push! toks (kind (substring s start end))))
    ;; the end of a run of non-delimiters starting at i.
    (define (atom-end i)
      (let loop ((j i))
        (if (and (< j n) (not (delimiter? (string-ref s j)))) (loop (+ j 1)) j)))
    (let loop ((i 0))
      (when (< i n)
        (let ((c (ch i)))
          (cond
           ;; ; comment, to the end of the line
           ((= c 59)
            (let lp ((j i)) (if (and (< j n) (not (= (ch j) 10))) (lp (+ j 1)) (begin (take tok:comment i j) (loop j)))))
           ;; "string", with \ escapes
           ((= c 34)
            (let lp ((j (+ i 1)))
              (cond ((>= j n) (take tok:string i n) (loop n))
                    ((= (ch j) 92) (lp (+ j 2)))
                    ((= (ch j) 34) (take tok:string i (+ j 1)) (loop (+ j 1)))
                    (else (lp (+ j 1))))))
           ((member? c '(40 91 123) =) (take tok:open i (+ i 1)) (loop (+ i 1)))
           ((member? c '(41 93 125) =) (take tok:close i (+ i 1)) (loop (+ i 1)))
           ((member? c '(39 96 44) =) (take tok:quote i (+ i 1)) (loop (+ i 1)))
           ((space? (string-ref s i))
            (let lp ((j i)) (if (and (< j n) (space? (string-ref s j))) (lp (+ j 1)) (begin (take tok:space i j) (loop j)))))
           ;; #\c: at least one character after the backslash, even a
           ;;  delimiter: #\(
           ((and (= c 35) (< (+ i 2) n) (= (ch (+ i 1)) 92))
            (let ((j (atom-end (+ i 3))))
              (take tok:char i j)
              (loop j)))
           ((and (= c 35) (< (+ i 1) n) (= (ch (+ i 1)) 40))
            (take tok:open i (+ i 2)) (loop (+ i 2)))
           (else
            (let ((j (max (+ i 1) (atom-end i))))
              (take tok:atom i j)
              (loop j)))))))
    (reverse toks)))

(define irken-keywords
  '("begin" "call-with-current-continuation" "call/cc" "case" "cond" "vcase"
    "match" "with" "datatype" "defmacro" "else" "if" "lambda" "let" "let*"
    "letrec" "let-values" "define" "set!" "include" "require" "require-ffi"
    "typealias" "letcc" "getcc" "putcc" "let/cc" "make-enum" "try" "except"
    ;; and some of the commonest macros
    "when" "unless" "while" "and" "or" "for" "for-list" "for-range" "for-map"
    "when-maybe" "if-maybe" "makegen" "push!" "pop!" "inc!" "dec!" "raise"))

;; the forms whose second element is a name being defined.
(define definers '("define" "defmacro" "datatype" "make-enum" "typealias"))

(define (number-atom? s)
  (let ((n (string-length s)))
    (and (> n 0)
         (let ((c (char-code (string-ref s 0))))
           (or (and (>= c 48) (<= c 57))
               ;; -1, +2
               (and (> n 1) (member? c '(43 45) =)
                    (let ((d (char-code (string-ref s 1)))) (and (>= d 48) (<= d 57))))
               ;; #x1f #o17 #b101
               (and (= c 35) (> n 1) (member? (string-ref s 1) '(#\x #\X #\o #\O #\b #\B) eq?)))))))

(define (constant-atom? s)
  (member? s '("#t" "#f" "#u") string=?))

;; (list (:tuple class text anchor)) for the tokens: class "" is plain
;;  text; anchor is the top-level name defined there, or "".  and the
;;  top-level names.
(define (classify toks)
  (let ((out (list:nil))
        (defs (list:nil))
        (depth 0)
        (after-open #f)        ;; the last token (not space) was an opener
        (want-name 0)          ;; 1: a definer was just seen; 2: and then "("
        (definer-depth 0))
    (define (emit class text anchor)
      (push! out (:tuple class text anchor)))
    (for-list tk toks
      (match tk with
        (tok:space s) -> (emit "" s "")
        (tok:comment s) -> (begin (emit "c" s "") (set! after-open #f))
        (tok:string s) -> (begin (emit "s" s "") (set! after-open #f) (set! want-name 0))
        (tok:char s) -> (begin (emit "ch" s "") (set! after-open #f) (set! want-name 0))
        (tok:quote s) -> (begin (emit "q" s "") (set! after-open #f))
        (tok:open s)
        -> (begin
             (emit "p" s "")
             (set! depth (+ depth 1))
             ;; (define (name args...)
             (if (= want-name 1) (set! want-name 2) (set! want-name 0))
             (set! after-open #t))
        (tok:close s)
        -> (begin
             (emit "p" s "")
             (set! depth (max 0 (- depth 1)))
             (set! want-name 0)
             (set! after-open #f))
        (tok:atom s)
        -> (begin
             (cond ((> want-name 0)
                    ;; the name being defined.  top level: give it an anchor.
                    (let ((top? (= definer-depth 1)))
                      (when top? (push! defs s))
                      (emit "d" s (if top? s "")))
                    (set! want-name 0))
                   ((and after-open (member? s definers string=?))
                    (emit "k" s "")
                    (set! want-name 1)
                    (set! definer-depth depth))
                   ((and after-open (member? s irken-keywords string=?))
                    (emit "k" s ""))
                   ((string=? s "->") (emit "a" s ""))
                   ((or (number-atom? s) (constant-atom? s)) (emit "nu" s ""))
                   ((>= (string-find ":" s) 0) (emit "t" s ""))
                   (else (emit "" s "")))
             (set! after-open #f))))
    (:tuple (reverse out) defs)))

;; the HTML for <src> (all of it, as a list of strings), and the
;;  top-level names in order.  if <irken?> is false, it's only escaped.
;;  (link-require path) is called for the string after (require: it
;;  returns the URL of that file, or "".
(define (highlight src0 irken? link-require)
  ;; (a newline at the end ends the last line: it doesn't start another.)
  (let ((src (if (ends-with src0 "\n") (substring src0 0 (- (string-length src0) 1)) src0))
        ((classes defs) (if irken?
                            (classify (lex src))
                            (:tuple (list (:tuple "" src "")) (list:nil))))
        (defset (tree/empty))
        (out (list:nil))
        (line 1)
        (last-atom ""))
    (for-list d defs (tree/insert! defset string-cmp d #t))
    (define (start-line)
      (push! out (format "<span class='l' id='L" (int line) "'><a class='n' href='#L" (int line) "'>"
                         (int line) "</a>")))
    ;; (no newline after it: the lines are blocks.)
    (define (end-line)
      (push! out "</span>")
      (set! line (+ line 1)))
    ;; text in a span of <class> (if any), with lines split off.
    (define (put class text anchor href)
      (let ((parts (string-split text #\newline)))
        (let loop ((parts parts) (first? #t))
          (match parts with
            () -> #u
            (part . tl)
            -> (begin
                 (when (not first?) (end-line) (start-line))
                 (when (> (string-length part) 0)
                   (let ((body (html-escape part)))
                     (push! out
                            (cond ((not (string=? anchor ""))
                                   (format "<a class='" class "' id='d-" body "' href='#d-" (url-escape part) "'>" body "</a>"))
                                  ((not (string=? href ""))
                                   (format "<a class='" class "' href='" (html-escape href) "'>" body "</a>"))
                                  ((string=? class "") body)
                                  (else (format "<span class='" class "'>" body "</span>"))))))
                 (loop tl #f))))))
    (start-line)
    (for-list c classes
      (match c with
        (:tuple class text anchor)
        -> (let ((href (cond ((and (string=? class "") (match (tree/member defset string-cmp text) with (maybe:yes _) -> #t (maybe:no) -> #f))
                              (format "#d-" (url-escape text)))
                             ((and (string=? class "s") (string=? last-atom "require"))
                              (link-require (substring text 1 (max 1 (- (string-length text) 1)))))
                             (else ""))))
             (put class text anchor href)
             (when (not (string=? class ""))
               (set! last-atom (if (string=? class "k") text ""))))))
    (end-line)
    (:tuple (reverse out) defs)))
