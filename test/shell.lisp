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
