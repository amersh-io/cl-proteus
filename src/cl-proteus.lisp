;;;; The CL-PROTEUS package: the core and the shell in one place.

(uiop:define-package #:cl-proteus
  (:use-reexport #:cl-proteus/core #:cl-proteus/shell)
  (:documentation "Everything an application built with cl-proteus usually
needs: the external symbols of CL-PROTEUS/CORE and CL-PROTEUS/SHELL. Windows
and webviews themselves come from cl-iris."))
