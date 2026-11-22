;;;; cl-proteus/bundle -- building a macOS application bundle from an app.
;;;;
;;;; Loaded in the Lisp that builds, never in the application: it needs
;;;; neither cl-iris nor Cocoa, and the image it makes does not contain it.

(defpackage #:cl-proteus/bundle
  (:use #:cl #:cl-proteus/core)
  (:export #:bundle-app
           #:bundle-error
           #:bundle-error-output
           #:*entitlements*
           #:*minimum-system-version*))
