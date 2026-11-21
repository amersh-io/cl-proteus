;;;; cl-proteus/core -- what an application is made of, apart from any window.
;;;;
;;;; This system does not load cl-iris or touch Cocoa, so an image that only
;;;; defines commands and views can load it without AppKit.

(defpackage #:cl-proteus/core
  (:use #:cl)
  (:export #:define-command
           #:register-command
           #:unregister-command
           #:find-command
           #:list-commands
           #:call-command
           #:command
           #:command-name
           #:command-function
           #:command-parameters
           #:command-documentation
           #:command-error
           #:command-error-command
           #:command-error-message
           #:js-name
           #:*commands*))
