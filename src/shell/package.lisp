;;;; cl-proteus/shell -- the process that owns the windows, built on cl-iris.

(defpackage #:cl-proteus/shell
  (:use #:cl #:cl-iris #:cl-proteus/core)
  (:export #:make-app-webview
           #:destroy-app-webview
           #:app-webviews
           #:emit-to
           #:*command-caller*
           #:*bridge-script*
           #:to-json
           #:frontend-handler
           #:*scheme*
           #:*mime-types*
           #:mime-type
           #:run-app
           #:stop-app
           #:app-running-p
           #:app-window
           #:app-webview
           #:refresh-app
           #:scheme-handler
           #:view-url
           #:show-view
           #:serve-shell
           #:stop-shell
           #:shell-server
           #:shell-server-path
           #:shell-clients
           #:connection
           #:connection-id
           #:connection-name
           #:connection-open-p
           #:remote-commands
           #:invoke-command
           #:*protocol-version*))
