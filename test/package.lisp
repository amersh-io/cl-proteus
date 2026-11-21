;;;; Test harness for cl-proteus. Run with (asdf:test-system "cl-proteus").

(defpackage #:cl-proteus/test
  (:use #:cl #:cl-iris #:cl-proteus)
  (:export #:run!))

(in-package #:cl-proteus/test)

(defvar *failures* '())
(defvar *passed* 0)

(defun selected-p (name)
  "True unless CL_PROTEUS_TEST_ONLY names text that NAME does not contain."
  (let ((only (sb-ext:posix-getenv "CL_PROTEUS_TEST_ONLY")))
    (or (null only) (search only name))))

(defmacro check (name form)
  "Evaluate FORM as the check NAME, unless it is not selected; record a
failure if it returns NIL or signals an error."
  (let ((n (gensym "NAME")))
    `(let ((,n ,name))
       (when (selected-p ,n)
         (handler-case
             (if ,form
                 (progn (incf *passed*) (format t "~&ok    ~A~%" ,n))
                 (progn (push ,n *failures*) (format t "~&FAIL  ~A~%" ,n)))
           (error (e)
             (push ,n *failures*)
             (format t "~&FAIL  ~A: ~A~%" ,n e)))))))
