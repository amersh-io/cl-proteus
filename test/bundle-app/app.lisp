;;;; The application the bundle test builds. It runs out of sight, prints
;;;; what it can see of its bundle, and quits by itself.

(defpackage #:cl-proteus.test.bundle-app
  (:use #:cl #:cl-proteus))

(in-package #:cl-proteus.test.bundle-app)

(define-command bundle-facts ()
  "Something only the Lisp side knows."
  (format nil "by ~A" (lisp-implementation-type)))

(define-app bundle-app
  (:title "Bundle Test")
  (:frontend "frontend/")
  (:window main :title "bundled" :width 300 :height 200 :page "index.html"))

(defun main-bundle-identifier ()
  (cl-iris/objc:lisp-string
   (cl-iris/objc:send (cl-iris/objc:send (cl-iris/objc:find-class* "NSBundle") "mainBundle")
                      "bundleIdentifier")))

(defun probe ()
  "Report the page's title, the bundle and the front end in use, then quit."
  (unwind-protect
       (handler-case
           (progn
             (loop until (and (cl-iris:application-running-p) (app-webviews))
                   repeat 200 do (sleep 0.05))
             (let ((webview (first (app-webviews))))
               (flet ((title () (cl-iris:eval-js webview "document.title" :timeout 5)))
                 (loop repeat 200 until (search "bundled" (title)) do (sleep 0.05))
                 (format t "~&BUNDLE-TITLE ~A~%" (title))))
             (format t "~&BUNDLE-IDENTIFIER ~A~%" (main-bundle-identifier))
             (format t "~&BUNDLE-FRONTEND ~A~%" (app-frontend (find-app 'bundle-app))))
         (error (e) (format t "~&BUNDLE-ERROR ~A~%" e)))
    (finish-output)
    (stop-app)))

;; Out of sight, like every test window, and probed once the image starts.
(setf cl-iris:*window-defaults* '(:alpha 0 :activate nil))
(push (lambda () (sb-thread:make-thread #'probe :name "bundle probe"))
      sb-ext:*init-hooks*)
