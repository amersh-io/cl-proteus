;;;; Tests for cl-proteus/shell: a page calling commands through a webview.
;;;; They run on a worker thread while the main thread runs the application,
;;;; and their windows are transparent unless CL_PROTEUS_TEST_VISIBLE is set.

(in-package #:cl-proteus/test)

(define-command test-fail ()
  (error "the command failed on purpose"))

(define-command test-echo (value)
  value)

(defun wait-until (predicate &key (timeout 10))
  "Poll PREDICATE until it returns true or TIMEOUT seconds pass."
  (loop repeat (* timeout 20)
        thereis (funcall predicate)
        do (sleep 0.05)))

(defun page-value (webview script)
  "Run SCRIPT, which sets window.result to a Promise, and wait for its outcome
as the string \"ok:<json>\" or \"error:<message>\"."
  (eval-js webview (format nil "window.outcome = undefined;
~A;
window.result.then(v => { window.outcome = 'ok:' + JSON.stringify(v); },
                   e => { window.outcome = 'error:' + e.message; }); 0" script))
  (let (outcome)
    (wait-until (lambda ()
                  (setf outcome (eval-js webview "window.outcome || ''"))
                  (plusp (length outcome))))
    outcome))

(defun shell-checks ()
  (with-window (window :title "cl-proteus test" :width 400 :height 300 :activate nil)
    (let ((webview (make-app-webview window :html "<title>ready</title>")))
     (unwind-protect
      (progn
      (wait-until (lambda () (equal "ready" (eval-js webview "document.title"))))
      (check "pages get window.proteus.invoke"
             (equal "function" (eval-js webview "typeof window.proteus.invoke")))
      (check "proteus.invoke calls a command and resolves with its value"
             (equal "ok:42" (page-value webview
                                        "window.result = proteus.invoke('test-add', {a: 40, b: 2})")))
      (check "camelCase arguments reach their parameters"
             (equal "ok:\"Hello, Ada!\""
                    (page-value webview
                                "window.result = proteus.invoke('test-greet', {userName: 'Ada'})")))
      (check "objects and arrays round-trip through a command"
             ;; Dictionaries keep no key order, so compare field by field.
             (equal "ok:[[1,2,3],\"x\"]"
                    (page-value webview
                                "window.result = proteus.invoke('test-echo', {value: {a: [1, 2, 3], b: 'x'}}).then(v => [v.a, v.b])")))
      (check "an error in a command rejects the Promise with its message"
             (search "failed on purpose"
                     (page-value webview "window.result = proteus.invoke('test-fail')")))
      (check "an unknown command rejects the Promise"
             (search "no such command"
                     (page-value webview "window.result = proteus.invoke('nope')")))
      (check "a missing argument rejects the Promise"
             (search "missing argument"
                     (page-value webview "window.result = proteus.invoke('test-add', {a: 1})")))
      (check "a command name that is not a string is refused in the page"
             (search "must be a string"
                     (page-value webview "window.result = proteus.invoke(42)")))
      (check "a command redefined while the page is open answers with the new definition"
             (let ((old (fdefinition 'test-echo)))
               (unwind-protect
                    (progn (setf (fdefinition 'test-echo) (lambda (value) (list value value)))
                           (equal "ok:[1,1]"
                                  (page-value webview
                                              "window.result = proteus.invoke('test-echo', {value: 1})")))
                 (setf (fdefinition 'test-echo) old))))
      (check "the page cannot replace window.proteus"
             (equal "function"
                    (eval-js webview "try { window.proteus = null; } catch (e) {}; typeof window.proteus.invoke"))))
      (destroy-webview webview))))
  (check "make-app-webview refuses an :on-invoke of its own"
         (handler-case
             (with-window (window :activate nil)
               (make-app-webview window :on-invoke (lambda (x) x))
               nil)
           (error () t))))

(define-command test-on-main-thread ()
  (main-thread-p))

(define-command test-caller-known ()
  (and *command-caller* t))

(define-command test-sleep (seconds)
  (sleep seconds)
  seconds)

(defun command-thread-checks ()
  (with-window (window :title "commands" :width 300 :height 200 :activate nil)
    (let ((webview (make-app-webview window :html "<title>commands</title>")))
      (unwind-protect
           (progn
             (wait-until (lambda () (equal "commands" (eval-js webview "document.title"))))
             (check "a command runs off the main thread"
                    (equal "ok:false"
                           (page-value webview "window.result = proteus.invoke('test-on-main-thread')")))
             (check "a command knows the webview that called it"
                    (equal "ok:true"
                           (page-value webview "window.result = proteus.invoke('test-caller-known')")))
             (check "a slow command does not hold up the window"
                    (progn
                      (eval-js webview "window.slow = proteus.invoke('test-sleep', {seconds: 1}); 0")
                      (let ((start (get-internal-real-time)))
                        (eval-js webview "1 + 1")
                        (< (- (get-internal-real-time) start)
                           (* 0.3 internal-time-units-per-second)))))
             (check "app-webviews lists a live app webview"
                    (member webview (app-webviews))))
        (destroy-app-webview webview))
      (check "a destroyed app webview leaves app-webviews"
             (not (member webview (app-webviews)))))))

(defun page-event-checks ()
  (with-window (window :title "events" :width 300 :height 200 :activate nil)
    (let* ((posted '())
           (one (make-app-webview window :html "<title>one</title>"
                                         :on-message (lambda (m) (push m posted))))
           (two (make-app-webview window :html "<title>two</title>" :bounds '(0 0 10 10))))
      (unwind-protect
           (progn
             (wait-until (lambda () (and (equal "one" (eval-js one "document.title"))
                                         (equal "two" (eval-js two "document.title")))))
             (dolist (webview (list one two))
               (eval-js webview "window.got = []; proteus.listen('test-lisp', p => window.got.push(p)); 0"))
             (check "to-json writes JSON text through Foundation"
                    (and (equal "\"a\\\"b\"" (to-json "a\"b"))
                         (equal "[1,true,null]" (to-json (vector 1 t :null)))))
             (check "emit from Lisp reaches page listeners with the payload"
                    (progn
                      (emit "test-lisp" (let ((h (make-hash-table :test 'equal)))
                                          (setf (gethash "n" h) 1) h))
                      (wait-until (lambda () (eql 1 (eval-js one "window.got.length ? window.got[0].n : 0"))))))
             (check "emit reaches every app webview"
                    (wait-until (lambda () (eql 1 (eval-js two "window.got.length")))))
             (check "emit-to reaches one webview only"
                    (progn
                      (emit-to two "test-lisp" 2)
                      (and (wait-until (lambda () (eql 2 (eval-js two "window.got.length"))))
                           (progn (sleep 0.2)
                                  (eql 1 (eval-js one "window.got.length"))))))
             (check "a page's emit reaches Lisp listeners, with *event-source* its webview"
                    (let* ((heard nil)
                           (listener (listen-event "test-page"
                                                   (lambda (payload)
                                                     (setf heard (list payload *event-source*))))))
                      (eval-js one "proteus.emit('test-page', 'hi'); 0")
                      (prog1 (wait-until (lambda () (equal heard (list "hi" one))))
                        (unlisten-event listener))))
             (check "a page's emit reaches the other pages too"
                    (progn
                      (eval-js two "window.fromPage = null; proteus.listen('test-relay', p => window.fromPage = p); 0")
                      (eval-js one "proteus.emit('test-relay', 5); 0")
                      (wait-until (lambda () (eql 5 (eval-js two "window.fromPage"))))))
             (check "proteus.once hears one event, and listen's result stops listening"
                    (progn
                      (eval-js one "window.onceCount = 0; window.offCount = 0;
proteus.once('test-count', () => window.onceCount++);
const off = proteus.listen('test-count', () => window.offCount++); window.off = off; 0")
                      (emit "test-count")
                      (wait-until (lambda () (eql 1 (eval-js one "window.offCount"))))
                      (eval-js one "window.off(); 0")
                      (emit "test-count")
                      (sleep 0.3)
                      (and (eql 1 (eval-js one "window.onceCount"))
                           (eql 1 (eval-js one "window.offCount")))))
             (check "other iris.post values still reach on-message"
                    (progn
                      (eval-js one "iris.post('plain'); 0")
                      (wait-until (lambda () (member "plain" posted :test #'equal))))))
        (destroy-app-webview two)
        (destroy-app-webview one)))))

(defun write-file (pathname text)
  (ensure-directories-exist pathname)
  (with-open-file (out pathname :direction :output :if-exists :supersede
                                :external-format :utf-8)
    (write-string text out))
  pathname)

(defun request-for (url &optional (method "GET"))
  (cl-iris/webview::%make-request url method '() nil))

(defun serve (handler url &optional (method "GET"))
  "The body as a string (or NIL), content type and status HANDLER answers."
  (multiple-value-bind (body type status) (funcall handler (request-for url method))
    (values (and body (if (stringp body) body (sb-ext:octets-to-string body :external-format :utf-8)))
            type status)))

(defun frontend-checks ()
  (uiop:with-temporary-file (:pathname marker :prefix "cl-proteus-frontend")
    (let* ((base (merge-pathnames (format nil "~A/" (pathname-name marker))
                                  (uiop:pathname-directory-pathname marker)))
           (site (merge-pathnames "site/" base))
           (secret (write-file (merge-pathnames "secret.txt" base) "secret")))
      (unwind-protect
           (let ((handler (progn
                            (write-file (merge-pathnames "index.html" site) "<title>front</title><link rel=stylesheet href=css/site.css>")
                            (write-file (merge-pathnames "css/site.css" site) "body { color: red }")
                            (write-file (merge-pathnames "my file.txt" site) "spaced")
                            (write-file (merge-pathnames "docs/index.html" site) "docs")
                            (sb-posix:symlink (namestring secret) (namestring (merge-pathnames "link.txt" site)))
                            (frontend-handler site))))
             (check "the root of the front end is its index.html"
                    (equal "<title>front</title><link rel=stylesheet href=css/site.css>"
                           (serve handler "proteus://app/")))
             (check "a file is served with its content type"
                    (multiple-value-bind (body type status) (serve handler "proteus://app/css/site.css")
                      (and (equal "body { color: red }" body)
                           (search "text/css" type) (eql 200 status))))
             (check "a directory path serves that directory's index.html"
                    (equal "docs" (serve handler "proteus://app/docs/")))
             (check "escaped characters, queries and fragments are handled"
                    (equal "spaced" (serve handler "proteus://app/my%20file.txt?v=2#top")))
             (check "a missing file answers 404"
                    (null (serve handler "proteus://app/missing.js")))
             (check ".. cannot leave the front end, escaped or not"
                    (every (lambda (url) (null (serve handler url)))
                           '("proteus://app/../secret.txt"
                             "proteus://app/css/../../secret.txt"
                             "proteus://app/%2e%2e/secret.txt"
                             "proteus://app/css%2F..%2F..%2Fsecret.txt"
                             "proteus://app/%2E%2E%5Csecret.txt")))
             (check "a symbolic link out of the front end is not followed"
                    (null (serve handler "proteus://app/link.txt")))
             (check "a malformed escape answers 404"
                    (null (serve handler "proteus://app/%zz")))
             (check "only GET and HEAD are served"
                    (eql 405 (nth-value 2 (serve handler "proteus://app/" "POST")))))
        (uiop:delete-directory-tree base :validate t :if-does-not-exist :ignore)))))
