;;;; frontend-dir.lisp -- a front end in its own directory of files.
;;;;
;;;;   qlot exec sbcl --load examples/frontend-dir.lisp
;;;;
;;;; examples/frontend/ holds index.html, style.css and app.js; the app serves
;;;; them at proteus://app/. Edit a file and reload the page (Cmd+R in the
;;;; Web Inspector, or evaluate (cl-iris:reload (app-webview 'main ...))).

(asdf:load-asd (merge-pathnames "../cl-proteus.asd" (or *load-truename* *default-pathname-defaults*)))
(asdf:load-system "cl-proteus")

(defpackage #:cl-proteus.examples.frontend-dir
  (:use #:cl #:cl-proteus)
  (:export #:main))

(in-package #:cl-proteus.examples.frontend-dir)

(define-command lisp-facts ()
  "Facts about the running Lisp, for the page to show."
  (let ((facts (make-hash-table :test 'equal)))
    (setf (gethash "implementation" facts) (lisp-implementation-type)
          (gethash "version" facts) (lisp-implementation-version)
          (gethash "machine" facts) (machine-type)
          (gethash "commands" facts) (coerce (list-commands) 'vector))
    facts))

(define-app frontend-dir
  (:title "Front end")
  (:frontend "frontend/")
  (:window main :title "A front end from files" :width 520 :height 320 :center t
           :page "index.html"))

(defun main (&rest options)
  "Run the app until its window is closed. OPTIONS go to RUN-APP."
  (apply #'run-app 'frontend-dir options))

#-(or cl-proteus-example-test cl-proteus-bundle) (main)
