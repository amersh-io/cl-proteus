;;;; The client image the remote tests start: a Lisp with no window that
;;;; connects to the shell on the socket named after --end-toplevel-options,
;;;; and exits when the shell drops it (or after two minutes).

(asdf:load-asd (merge-pathnames "../cl-proteus.asd" *load-truename*))
(asdf:load-system "cl-proteus/client")

(defpackage #:cl-proteus.test.remote-client
  (:use #:cl #:cl-proteus/core #:cl-proteus/client))

(in-package #:cl-proteus.test.remote-client)

(defvar *heard* :null
  "The payload of the last to-client event.")

(define-command remote-add (a b)
  (+ a b))

(define-command remote-slow (seconds)
  (sleep seconds)
  seconds)

(define-command remote-emit (event payload)
  (emit event payload)
  t)

(define-command remote-heard ()
  *heard*)

(define-command remote-cl-iris-p ()
  (and (find-package "CL-IRIS") t))

(defun page (title)
  (format nil "<!doctype html><title>~A</title><script src=app.js></script>" title))

(define-view remote-notes
  :files ("index.html" (page "v1")
          "app.js" "window.viewScript = 'loaded';"))

(define-command swap-view (title)
  (define-view remote-notes
    :files ("index.html" (page title)
            "app.js" "window.viewScript = 'loaded';"))
  title)

(listen-event "to-client" (lambda (payload) (setf *heard* payload)))

(connect-shell (car (last sb-ext:*posix-argv*)) :name "test client")
(format t "~&CLIENT-CONNECTED~%")
(finish-output)
(loop repeat 1200 while (shell-connected-p) do (sleep 0.1))
(format t "~&CLIENT-DONE~%")
