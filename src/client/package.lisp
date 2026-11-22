;;;; cl-proteus/client -- what an image that holds no window loads to put its
;;;; commands, events and views in a shell's windows.
;;;;
;;;; It needs neither cl-iris nor Cocoa, so the image can fork, or save itself
;;;; with save-lisp-and-die, while a shell keeps the windows up.

(defpackage #:cl-proteus/client
  (:use #:cl #:cl-proteus/core)
  (:export #:connect-shell
           #:disconnect-shell
           #:with-shell
           #:*shell*
           #:shell-connection
           #:shell-connection-path
           #:shell-connected-p))
