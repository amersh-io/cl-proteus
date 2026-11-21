;;;; cl-proteus -- the package most programs use: the core and the shell.

(defpackage #:cl-proteus
  (:use #:cl)
  (:documentation "Everything an application built with cl-proteus usually
needs. Windows and webviews themselves come from cl-iris."))

(in-package #:cl-proteus)

(dolist (package '(#:cl-proteus/core #:cl-proteus/shell))
  (do-external-symbols (symbol package)
    (import symbol)
    (export symbol)))
