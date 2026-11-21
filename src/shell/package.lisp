;;;; cl-proteus/shell -- the process that owns the windows, built on cl-iris.

(defpackage #:cl-proteus/shell
  (:use #:cl #:cl-iris #:cl-proteus/core)
  (:export #:make-app-webview
           #:*bridge-script*))
