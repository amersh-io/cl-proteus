;;;; Serving views, and swapping them while pages show them.
;;;;
;;;; proteus://view/NAME/PATH is the file PATH of the view NAME, from memory.
;;;; Every app webview serves views; when a view is defined again with other
;;;; files -- in this image or by a client -- every page showing it is loaded
;;;; again.

(in-package #:cl-proteus/shell)

(defun url-host (url)
  "The host of URL: \"view\" for proteus://view/notes/, or NIL."
  (let ((start (search "://" url)))
    (when start
      (let ((end (or (position-if (lambda (c) (member c '(#\/ #\? #\#))) url :start (+ start 3))
                     (length url))))
        (subseq url (+ start 3) end)))))

(defun view-handler ()
  "A handler for cl-iris's :PROTOCOLS that serves views:
proteus://view/NAME/PATH is the file PATH of the view NAME."
  (lambda (request)
    (if (not (member (request-method request) '("GET" "HEAD") :test #'string-equal))
        (values "Method not allowed" "text/plain; charset=utf-8" 405)
        (let* ((path (url-path (request-url request)))
               (slash (and path (position #\/ path)))
               (view (and path (find-view (subseq path 0 (or slash (length path))))))
               (file (if slash (subseq path (1+ slash)) ""))
               (octets (and view
                           (or (string= file "") (safe-relative-path file))
                           (view-file view file))))
          (when octets
            (let ((name (if (or (string= file "") (char= #\/ (char file (1- (length file)))))
                            "index.html"
                            file)))
              (values octets (mime-type (uiop:parse-unix-namestring name))
                      200 '(("Cache-Control" . "no-cache")))))))))

(defun scheme-handler (&optional frontend)
  "The handler an app webview serves *SCHEME* with: views at
proteus://view/, and FRONTEND's files, if it is a directory, at
proteus://app/."
  (let ((views (view-handler))
        (files (and frontend (frontend-handler frontend))))
    (lambda (request)
      (let ((host (url-host (request-url request))))
        (cond ((equal host "view") (funcall views request))
              ((and files (equal host "app")) (funcall files request)))))))

(defun view-url (name)
  "The URL the view NAME is served at."
  (format nil "~A://view/~A/" *scheme* (cl-proteus/core::view-name-string name)))

(defun show-view (webview name)
  "Load the view NAME, a string or symbol, in WEBVIEW, an app webview."
  (load-url webview (view-url name))
  webview)

(defun reload-view-pages (view)
  "Load again every app webview showing VIEW."
  (let ((prefix (view-url (view-name view))))
    (dolist (webview (app-webviews))
      (handler-case
          (let ((url (webview-url webview)))
            (when (and url (eql 0 (search prefix url)))
              (reload webview)))
        (serious-condition (c)
          (format *error-output* "~&;; cl-proteus: error reloading a view: ~A~%" c))))))

(pushnew 'reload-view-pages *views-changed-hook*)
