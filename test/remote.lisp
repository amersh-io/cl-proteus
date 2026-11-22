;;;; Tests for the socket between a shell and a client image: JSON, views, the
;;;; server's socket, and a page in this shell calling commands of a child
;;;; Lisp that holds no window -- through its death and its successor.

(in-package #:cl-proteus/test)

;;; Without a window

(defun json-checks ()
  (check "JSON written and read back keeps strings, numbers, booleans and null"
         (let* ((table (let ((h (make-hash-table :test 'equal)))
                         (setf (gethash "a" h) (vector 1 -2 2.5d0 "x\"y\\z
w" t nil :null)
                               (gethash "b" h) (list "é ✓ 😀"))
                         h))
                (back (read-json (write-json table))))
           (and (equalp (gethash "a" back) (vector 1 -2 2.5d0 "x\"y\\z
w" t nil :null))
                (equalp (gethash "b" back) (vector "é ✓ 😀")))))
  (check "written JSON is one line"
         (not (find #\Newline (write-json (vector "a
b")))))
  (check "JSON escapes and surrogate pairs are read"
         (equal (format nil "a/b~C~A" (code-char 9) (string (code-char #x1F600)))
                (read-json "\"a\\/b\\t\\ud83d\\ude00\"")))
  (check "JSON numbers with a fraction or exponent read as doubles"
         (equalp (vector 1 1000.0d0 -0.5d0 12) (read-json "[1, 1e3, -0.5, 12]")))
  (check "malformed JSON signals json-error"
         (every (lambda (text) (handler-case (progn (read-json text) nil)
                                 (json-error () t)))
                '("[1,]" "{\"a\" 1}" "\"open" "tru" "1 2" "" "-" "[1"))))

(defun view-checks ()
  (let ((view (ensure-view "test-view" :files '("index.html" "<title>t</title>"
                                                "css/site.css" "body{}"))))
    (check "a view keeps its files as octets"
           (and (equal "test-view" (view-name view))
                (equalp (sb-ext:string-to-octets "body{}") (view-file view "css/site.css"))))
    (check "a view's empty path is its index.html"
           (equalp (view-file view "") (view-file view "index.html")))
    (check "define-view takes files written out and evaluates their contents"
           (progn (eval '(define-view test-view-2 :files ("a.txt" (format nil "~A" 42))))
                  (equalp (sb-ext:string-to-octets "42")
                          (view-file (find-view 'test-view-2) "a.txt"))))
    (check "a view is served at proteus://view/name/"
           (let ((handler (scheme-handler)))
             (multiple-value-bind (body type status) (serve handler "proteus://view/test-view/css/site.css")
               (and (equal "body{}" body) (search "text/css" type) (eql 200 status)))))
    (check "a view's root is served as HTML"
           (let ((handler (scheme-handler)))
             (multiple-value-bind (body type) (serve handler "proteus://view/test-view/")
               (and (equal "<title>t</title>" body) (search "text/html" type)))))
    (check "a missing view or file answers 404, and .. is refused"
           (let ((handler (scheme-handler)))
             (every (lambda (url) (null (serve handler url)))
                    '("proteus://view/nope/" "proteus://view/test-view/missing.js"
                      "proteus://view/test-view/../test-view-2/a.txt"
                      "proteus://app/index.html"))))
    (check "a window spec's :view is the view's URL"
           (equal "proteus://view/notes/" (cl-proteus/shell::page-url '(main :view notes))))
    (check "defining a view again unchanged does not call the views hook"
           (let* ((heard 0)
                  (*views-changed-hook* (list (lambda (view) (declare (ignore view)) (incf heard)))))
             (ensure-view "test-view" :files '("index.html" "<title>t</title>"
                                               "css/site.css" "body{}"))
             (= 0 heard)))
    (check "the views hook hears a definition"
           (let* ((heard nil)
                  (*views-changed-hook* (list (lambda (view) (setf heard (view-name view))))))
             (ensure-view "test-view-3" :files '("index.html" "x"))
             (equal "test-view-3" heard)))))

(defun commands-hook-checks ()
  (check "the commands hook hears registering and unregistering"
         (let* ((heard '())
                (*commands-changed-hook* (list (lambda (name command)
                                                 (push (list name (and command t)) heard)))))
           (register-command "test-hooked" 'identity '(x))
           (unregister-command "test-hooked")
           (equal '(("test-hooked" nil) ("test-hooked" t)) heard))))

(defun client-load-checks ()
  (check "loading cl-proteus/client loads neither cl-iris nor CFFI"
         (multiple-value-bind (output code)
             (run-child-lisp "(asdf:load-asd (truename \"cl-proteus.asd\"))"
                             "(asdf:load-system \"cl-proteus/client\")"
                             "(format t \"~&LOADED ~A ~A~%\" (and (find-package \"CL-IRIS\") t) (and (find-package \"CFFI\") t))")
           (or (and (eql 0 code) (search "LOADED NIL NIL" output))
               (progn (format t "~&;; ~A~%" (last-lines output 20)) nil)))))

(defun socket-directory ()
  ;; A Unix-domain socket path holds at most 103 bytes, and the temporary
  ;; directory on macOS is long, so tests use /tmp.
  (format nil "/tmp/cl-proteus-test-~D-~D/" (sb-posix:getpid) (random 1000000)))

(defun mode (path)
  (logand #o777 (sb-posix:stat-mode (sb-posix:stat (string-right-trim "/" path)))))

(defun server-checks ()
  (let* ((directory (socket-directory))
         (path (concatenate 'string directory "shell.sock")))
    (unwind-protect
         (progn
           (check "a socket path over 103 bytes is refused"
                  (handler-case (progn (serve-shell (format nil "/tmp/~A.sock"
                                                            (make-string 120 :initial-element #\a)))
                                       nil)
                    (error (e) (search "too long" (princ-to-string e)))))
           (let ((server (serve-shell path)))
             (unwind-protect
                  (progn
                    (check "the server makes its directory and socket this user's only"
                           (and (eql #o700 (mode directory)) (eql #o600 (mode path))))
                    (check "a second server on a socket that answers is refused"
                           (handler-case (progn (serve-shell path) nil)
                             (error (e) (search "already listens" (princ-to-string e))))))
               (stop-shell server)))
           (check "a stopped server removes its socket"
                  (not (probe-file path)))
           (let ((stale (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
             (sb-bsd-sockets:socket-bind stale path)
             (sb-bsd-sockets:socket-close stale))
           (check "a socket left by a shell that is gone is replaced"
                  (let ((server (serve-shell path)))
                    (prog1 (typep server 'shell-server) (stop-shell server)))))
      (ignore-errors (uiop:delete-directory-tree (uiop:ensure-directory-pathname directory)
                                                 :validate t :if-does-not-exist :ignore)))))

(defun remote-unit-checks ()
  (json-checks)
  (view-checks)
  (commands-hook-checks)
  (client-load-checks)
  (server-checks))

;;; A page and a child image

(defun noted (value control &rest arguments)
  "VALUE; when it is false, say why with CONTROL and ARGUMENTS, so a failing
check shows which part of it failed."
  (unless value
    (format t "~&;; ~?~%" control arguments))
  value)

(defun start-client (path log)
  "Start the test client image, connecting to PATH, with its output in LOG."
  (let ((root (asdf:system-source-directory "cl-proteus")))
    (sb-ext:run-program sb-ext:*runtime-pathname*
                        (list "--noinform" "--non-interactive" "--no-userinit"
                              "--load" (namestring (merge-pathnames ".qlot/setup.lisp" root))
                              "--load" (namestring (merge-pathnames "test/remote-client.lisp" root))
                              "--end-toplevel-options" path)
                        :directory root :output log :if-output-exists :append
                        :error :output :wait nil)))

(defun stop-client (process)
  (when (sb-ext:process-alive-p process)
    (sb-ext:process-kill process 9)
    (sb-ext:process-wait process)))

(defun client-registered-p (name)
  (member name (remote-commands) :test #'string=))

(defun remote-checks ()
  (let* ((directory (socket-directory))
         (path (concatenate 'string directory "shell.sock"))
         (log (concatenate 'string directory "client.log"))
         (server (serve-shell path))
         (clients '()))
    (unwind-protect
         (with-window (window :title "remote" :width 400 :height 300 :activate nil)
           (push (start-client path log) clients)
           (check "a client registers its commands and views with the shell"
                  (and (wait-until (lambda () (client-registered-p "remote-add")) :timeout 60)
                       (find-view "remote-notes")
                       (equal "test client" (connection-name (first (shell-clients server))))))
           (let ((webview (make-app-webview window :view "remote-notes")))
             (unwind-protect
                  (progn
                    (check "a page shows a client's view"
                           (wait-until (lambda () (equal "v1" (eval-js webview "document.title")))))
                    (check "a view's other files are served"
                           (wait-until (lambda () (equal "loaded" (eval-js webview "window.viewScript || ''")))))
                    (check "a page invokes a client's command and gets its value"
                           (equal "ok:42" (page-value webview "window.result = proteus.invoke('remote-add', {a: 40, b: 2})")))
                    (check "the client's command runs in the client, which has no cl-iris"
                           (equal "ok:false" (page-value webview "window.result = proteus.invoke('remote-cl-iris-p')")))
                    (check "an error in a client's command rejects the page's Promise"
                           (search "missing argument"
                                   (page-value webview "window.result = proteus.invoke('remote-add', {a: 1})")))
                    (check "an event a client emits reaches the page"
                           (progn
                             (eval-js webview "window.fromClient = null; proteus.listen('from-client', p => window.fromClient = p); 0")
                             (page-value webview "window.result = proteus.invoke('remote-emit', {event: 'from-client', payload: 'hi'})")
                             (wait-until (lambda () (equal "hi" (eval-js webview "window.fromClient || ''"))))))
                    (check "an event a client emits reaches the shell's Lisp listeners"
                           (let* ((heard nil)
                                  (listener (listen-event "from-client-lisp"
                                                          (lambda (payload)
                                                            (setf heard (list payload (typep *event-source* 'connection)))))))
                             (page-value webview "window.result = proteus.invoke('remote-emit', {event: 'from-client-lisp', payload: 3})")
                             (prog1 (wait-until (lambda () (equal heard '(3 t))))
                               (unlisten-event listener))))
                    (check "an event a page emits reaches the client"
                           (progn
                             (eval-js webview "proteus.emit('to-client', 'yo'); 0")
                             (wait-until (lambda ()
                                           (equal "ok:\"yo\""
                                                  (page-value webview "window.result = proteus.invoke('remote-heard')"))))))
                    (check "a client's view defined again reloads the page, in the same window"
                           (progn
                             (eval-js webview "window.marker = 1; 0")
                             (page-value webview "window.result = proteus.invoke('swap-view', {title: 'v2'})")
                             (and (wait-until (lambda () (equal "v2" (eval-js webview "document.title"))))
                                  (eql :null (eval-js webview "window.marker === undefined ? null : 1"))
                                  (not (window-closed-p window))
                                  (member webview (app-webviews)))))
                    (check "a client that dies rejects the invokes it had not answered"
                           (progn
                             (eval-js webview "window.slow = 'waiting'; proteus.invoke('remote-slow', {seconds: 30}).then(v => window.slow = 'ok', e => window.slow = 'error:' + e.message); 0")
                             (sleep 0.5)
                             (stop-client (first clients))
                             (and (wait-until (lambda () (search "disconnected" (eval-js webview "window.slow"))))
                                  (search "error:" (eval-js webview "window.slow")))))
                    (check "a client that dies takes its commands with it"
                           (and (wait-until (lambda () (not (client-registered-p "remote-add"))))
                                (null (shell-clients server))
                                (search "no such command"
                                        (page-value webview "window.result = proteus.invoke('remote-add', {a: 1, b: 2})"))))
                    (check "the next client registers again and the same page invokes it"
                           (progn
                             (push (start-client path log) clients)
                             (and (noted (wait-until (lambda () (client-registered-p "remote-add")) :timeout 60)
                                         "the next client did not register within 60 s")
                                  ;; The new client sends its view (v1) after its commands, and the
                                  ;; page showing v2 is loaded again when it arrives: an invoke made
                                  ;; in between dies with the old page.
                                  (noted (wait-until (lambda () (equal "v1" (eval-js webview "document.title"))))
                                         "the page did not show the next client's view; its title is ~S"
                                         (ignore-errors (eval-js webview "document.title")))
                                  (let ((outcome (page-value webview "window.result = proteus.invoke('remote-add', {a: 2, b: 3})")))
                                    (noted (equal "ok:5" outcome)
                                           "the invoke gave ~S (\"\" is no outcome in 10 s); the page's title is ~S"
                                           outcome (ignore-errors (eval-js webview "document.title"))))
                                  (noted (not (window-closed-p window)) "the window closed"))))
                    (check "a client that connects again with the same view leaves the page as it is"
                           (progn
                             (eval-js webview "window.marker = 2; 0")
                             (stop-client (first clients))
                             (wait-until (lambda () (not (client-registered-p "remote-add"))))
                             (push (start-client path log) clients)
                             (and (noted (wait-until (lambda () (client-registered-p "remote-add")) :timeout 60)
                                         "the client did not register within 60 s")
                                  ;; Its view comes right after its commands.
                                  (progn (sleep 1) t)
                                  (noted (eql 2 (eval-js webview "window.marker === 2 ? 2 : null"))
                                         "the page was loaded again"))))
                    (check "an answer for a webview destroyed meanwhile does no harm"
                           (let ((doomed (make-app-webview window :html "<title>doomed</title>")))
                             (wait-until (lambda () (equal "doomed" (eval-js doomed "document.title"))))
                             (eval-js doomed "proteus.invoke('remote-slow', {seconds: 1}); 0")
                             (sleep 0.2)
                             (destroy-app-webview doomed)
                             (sleep 2)
                             (and (application-running-p)
                                  (equal "ok:5" (page-value webview "window.result = proteus.invoke('remote-add', {a: 2, b: 3})"))))))
               (destroy-app-webview webview))))
      (dolist (client clients) (stop-client client))
      (stop-shell server)
      (when *failures*
        (ignore-errors (format t "~&;; client log:~%~A~%" (last-lines (uiop:read-file-string log) 40))))
      (ignore-errors (uiop:delete-directory-tree (uiop:ensure-directory-pathname directory)
                                                 :validate t :if-does-not-exist :ignore)))))
