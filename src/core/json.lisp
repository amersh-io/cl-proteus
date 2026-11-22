;;;; JSON text, read and written in Lisp alone.
;;;;
;;;; The shell talks to pages through Foundation; an image that holds no
;;;; Cocoa (a client) still needs JSON for the socket, so this is plain Lisp.
;;;; Values map as they do for pages:
;;;;
;;;;   JSON       Lisp
;;;;   string     string
;;;;   number     integer, or double-float when it has a fraction or exponent
;;;;   true       T
;;;;   false      NIL (written from NIL or :FALSE)
;;;;   null       :NULL
;;;;   array      vector (written from a vector or a list)
;;;;   object     hash table with EQUAL string keys

(in-package #:cl-proteus/core)

;;; Writing

(defun write-json-string (string stream)
  (write-char #\" stream)
  (loop for char across string
        for code = (char-code char)
        do (case char
             (#\" (write-string "\\\"" stream))
             (#\\ (write-string "\\\\" stream))
             (t (cond ((= code 8) (write-string "\\b" stream))
                      ((= code 9) (write-string "\\t" stream))
                      ((= code 10) (write-string "\\n" stream))
                      ((= code 12) (write-string "\\f" stream))
                      ((= code 13) (write-string "\\r" stream))
                      ((or (< code 32) (= code #x2028) (= code #x2029))
                       (format stream "\\u~4,'0X" code))
                      (t (write-char char stream))))))
  (write-char #\" stream))

(defun write-json-number (number stream)
  (if (integerp number)
      (format stream "~D" number)
      (let ((float (float number 1d0)))
        (when (or (sb-ext:float-infinity-p float) (sb-ext:float-nan-p float))
          (error "~S cannot be written as JSON." number))
        (let ((*read-default-float-format* 'double-float))
          (prin1 float stream)))))

(defun write-json-value (value stream)
  (etypecase value
    (null (write-string "false" stream))
    ((eql t) (write-string "true" stream))
    ((eql :false) (write-string "false" stream))
    ((eql :null) (write-string "null" stream))
    (string (write-json-string value stream))
    (real (write-json-number value stream))
    ((or vector cons)
     (write-char #\[ stream)
     (let ((first t))
       (map nil (lambda (element)
                  (unless first (write-char #\, stream))
                  (setf first nil)
                  (write-json-value element stream))
            value))
     (write-char #\] stream))
    (hash-table
     (write-char #\{ stream)
     (let ((first t))
       (maphash (lambda (key element)
                  (unless first (write-char #\, stream))
                  (setf first nil)
                  (write-json-string (if (stringp key) key (princ-to-string key)) stream)
                  (write-char #\: stream)
                  (write-json-value element stream))
                value))
     (write-char #\} stream))))

(defun write-json (value &optional stream)
  "Write VALUE, a JSON-like Lisp value, as JSON text to STREAM, or return the
text as a string when STREAM is NIL. The text has no newline in it: a newline
inside a string is written as \\n."
  (if stream
      (progn (write-json-value value stream) value)
      (with-output-to-string (out) (write-json-value value out))))

;;; Reading

(define-condition json-error (error)
  ((message :initarg :message :reader json-error-message))
  (:report (lambda (condition stream)
             (format stream "Malformed JSON: ~A" (json-error-message condition))))
  (:documentation "READ-JSON was given text that is not JSON."))

(setf (documentation 'json-error-message 'function) "What was wrong with the JSON text.")

(defun json-fail (control &rest arguments)
  (error 'json-error :message (apply #'format nil control arguments)))

(defun skip-whitespace (text position)
  (or (position-if-not (lambda (char) (member char '(#\Space #\Tab #\Newline #\Return)))
                       text :start position)
      (length text)))

(defun expect-char (text position char)
  (unless (and (< position (length text)) (char= (char text position) char))
    (json-fail "expected ~S at ~D" char position))
  (1+ position))

(defun read-hex4 (text position)
  (let ((code (and (<= (+ position 4) (length text))
                   (every (lambda (char) (digit-char-p char 16))
                          (subseq text position (+ position 4)))
                   (parse-integer text :start position :end (+ position 4) :radix 16))))
    (or code (json-fail "bad \\u escape at ~D" position))))

(defun read-json-string (text position)
  "The string starting at the quote at POSITION, and the position after it."
  (let ((out (make-string-output-stream))
        (i (1+ position)))
    (loop
      (when (>= i (length text)) (json-fail "unterminated string"))
      (let ((char (char text i)))
        (cond ((char= char #\") (return (values (get-output-stream-string out) (1+ i))))
              ((char= char #\\)
               (when (>= (1+ i) (length text)) (json-fail "unterminated string"))
               (let ((escape (char text (1+ i))))
                 (incf i 2)
                 (case escape
                   (#\" (write-char #\" out))
                   (#\\ (write-char #\\ out))
                   (#\/ (write-char #\/ out))
                   (#\b (write-char (code-char 8) out))
                   (#\f (write-char (code-char 12) out))
                   (#\n (write-char (code-char 10) out))
                   (#\r (write-char (code-char 13) out))
                   (#\t (write-char (code-char 9) out))
                   (#\u
                    (let ((code (read-hex4 text i)))
                      (incf i 4)
                      (when (and (<= #xD800 code #xDBFF)
                                 (< (1+ i) (length text))
                                 (char= (char text i) #\\) (char= (char text (1+ i)) #\u))
                        (let ((low (read-hex4 text (+ i 2))))
                          (when (<= #xDC00 low #xDFFF)
                            (setf code (+ #x10000 (ash (- code #xD800) 10) (- low #xDC00)))
                            (incf i 6))))
                      (write-char (code-char code) out)))
                   (t (json-fail "bad escape \\~A" escape)))))
              ((< (char-code char) 32) (json-fail "control character in a string at ~D" i))
              (t (write-char char out) (incf i)))))))

(defun read-json-number (text position)
  (let* ((end (or (position-if-not (lambda (char) (find char "+-0123456789.eE"))
                                   text :start position)
                  (length text)))
         (token (subseq text position end)))
    (unless (and (plusp (length token))
                 (or (digit-char-p (char token 0))
                     (and (char= (char token 0) #\-) (> (length token) 1)
                          (digit-char-p (char token 1)))))
      (json-fail "bad number at ~D" position))
    (values (if (find-if (lambda (char) (find char ".eE")) token)
                (let ((*read-default-float-format* 'double-float)
                      (*read-eval* nil))
                  (let ((value (handler-case (read-from-string token)
                                 (error () (json-fail "bad number ~S" token)))))
                    (unless (realp value) (json-fail "bad number ~S" token))
                    (float value 1d0)))
                (handler-case (parse-integer token)
                  (error () (json-fail "bad number ~S" token))))
            end)))

(defun read-json-value (text position)
  "The value starting at POSITION in TEXT, and the position after it."
  (let ((position (skip-whitespace text position)))
    (when (>= position (length text)) (json-fail "unexpected end"))
    (let ((char (char text position)))
      (case char
        (#\" (read-json-string text position))
        (#\{
         (let ((table (make-hash-table :test 'equal))
               (i (skip-whitespace text (1+ position))))
           (if (and (< i (length text)) (char= (char text i) #\}))
               (values table (1+ i))
               (loop
                 (setf i (skip-whitespace text i))
                 (unless (and (< i (length text)) (char= (char text i) #\"))
                   (json-fail "expected a key at ~D" i))
                 (multiple-value-bind (key after) (read-json-string text i)
                   (setf i (expect-char text (skip-whitespace text after) #\:))
                   (multiple-value-bind (value after) (read-json-value text i)
                     (setf (gethash key table) value
                           i (skip-whitespace text after))))
                 (cond ((and (< i (length text)) (char= (char text i) #\,)) (incf i))
                       ((and (< i (length text)) (char= (char text i) #\}))
                        (return (values table (1+ i))))
                       (t (json-fail "expected , or } at ~D" i)))))))
        (#\[
         (let ((elements '())
               (i (skip-whitespace text (1+ position))))
           (if (and (< i (length text)) (char= (char text i) #\]))
               (values (vector) (1+ i))
               (loop
                 (multiple-value-bind (value after) (read-json-value text i)
                   (push value elements)
                   (setf i (skip-whitespace text after)))
                 (cond ((and (< i (length text)) (char= (char text i) #\,)) (incf i))
                       ((and (< i (length text)) (char= (char text i) #\]))
                        (return (values (coerce (nreverse elements) 'vector) (1+ i))))
                       (t (json-fail "expected , or ] at ~D" i)))))))
        (t
         (flet ((word (word value)
                  (if (and (<= (+ position (length word)) (length text))
                           (string= word text :start2 position :end2 (+ position (length word))))
                      (values value (+ position (length word)))
                      (json-fail "unexpected ~S at ~D" char position))))
           (case char
             (#\t (word "true" t))
             (#\f (word "false" nil))
             (#\n (word "null" :null))
             (t (read-json-number text position)))))))))

(defun read-json (text)
  "The Lisp value of the JSON TEXT, a string holding one JSON value. Signals
JSON-ERROR if TEXT is not JSON."
  (multiple-value-bind (value end) (read-json-value text 0)
    (unless (= (skip-whitespace text end) (length text))
      (json-fail "text after the value at ~D" end))
    value))
