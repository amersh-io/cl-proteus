;;;; Every example in examples/ is run in a child Lisp: it must open its
;;;; window, load its page without an error, and answer a probe.

(in-package #:cl-proteus/test)

(defparameter *examples*
  ;; file, a script run in the app's first page, and the title it leads to.
  '(("hello" "proteus.invoke('greet', {userName: 'Ada'}).then(v => document.title = v); 0"
     "Hello, Ada!")
    ("events" "proteus.listen('clicks', n => document.title = 'clicks ' + n); proteus.emit('clicked'); 0"
     "clicks 1")
    ("frontend-dir" nil "Facts: SBCL")))

(defparameter *example-driver* "
(sb-thread:make-thread
 (lambda ()
   (loop until (and (cl-iris:application-running-p) (cl-proteus:app-webviews))
         repeat 200 do (sleep 0.05))
   (unwind-protect
        (handler-case
            (let ((webview (first (cl-proteus:app-webviews))))
              (flet ((title () (cl-iris:eval-js webview \"document.title\" :timeout 5)))
                (loop repeat 100 until (plusp (length (title))) do (sleep 0.1))
                (when cl-user::*probe*
                  (cl-iris:eval-js webview cl-user::*probe*))
                (loop repeat 100 until (search cl-user::*expected* (title)) do (sleep 0.1))
                (format t \"~&EXAMPLE-TITLE ~A~%\" (title))))
          (error (e) (format t \"~&EXAMPLE-ERROR ~A~%\" e)))
     (cl-proteus:stop-app))))")

(defun run-child-lisp (&rest forms)
  "Run FORMS, strings read in the child, in a fresh Lisp with cl-proteus
loadable; return its output and exit code."
  (let ((root (asdf:system-source-directory "cl-proteus")))
    (multiple-value-bind (output error-output code)
        (uiop:run-program
         (append (list sb-ext:*runtime-pathname* "--non-interactive" "--no-userinit"
                       "--load" (namestring (merge-pathnames ".qlot/setup.lisp" root)))
                 (loop for form in forms append (list "--eval" form)))
         :directory root :output :string :error-output :string :ignore-error-status t)
      (values (concatenate 'string output error-output) code))))

(defun last-lines (text count)
  "The last COUNT lines of TEXT."
  (let ((lines (uiop:split-string (string-right-trim '(#\Newline) text) :separator '(#\Newline))))
    (format nil "~{~A~^~%~}" (last lines count))))

(defun run-example (name probe expected)
  (let ((file (namestring (merge-pathnames (format nil "examples/~A.lisp" name)
                                           (asdf:system-source-directory "cl-proteus")))))
    (run-child-lisp "(pushnew :cl-proteus-example-test *features*)"
                    (format nil "(load ~S)" file)
                    ;; Out of sight, like every test window.
                    "(setf cl-iris:*window-defaults* '(:alpha 0 :activate nil))"
                    (format nil "(defparameter cl-user::*probe* ~S)" probe)
                    (format nil "(defparameter cl-user::*expected* ~S)" expected)
                    *example-driver*
                    (format nil "(cl-proteus.examples.~A:main :activation-policy :accessory)" name)
                    "(format t \"~&EXAMPLE-DONE~%\")")))

(defun example-checks ()
  (loop for (name probe expected) in *examples*
        for check-name = (format nil "the ~A example runs and answers its probe" name)
        do (when (selected-p check-name)
             (multiple-value-bind (output code) (run-example name probe expected)
               (check check-name
                      (or (and (eql 0 code)
                               (search "EXAMPLE-DONE" output)
                               (not (search "EXAMPLE-ERROR" output))
                               (not (search ";; cl-proteus: error" output))
                               (not (search ";; cl-iris: error" output))
                               (search (format nil "EXAMPLE-TITLE ~A" expected) output))
                          (progn (format t "~&;; ~A example, exit code ~A, output:~%~A~%"
                                         name code (last-lines output 40))
                                 nil)))))))

;;; The remote example: a shell in one child Lisp, its agent in another.

(defparameter *remote-example-driver* "
(sb-thread:make-thread
 (lambda ()
   (loop until (and (cl-iris:application-running-p) (cl-proteus:app-webviews))
         repeat 200 do (sleep 0.05))
   (let ((agent nil))
     (unwind-protect
          (handler-case
              (let ((webview (first (cl-proteus:app-webviews)))
                    (root (asdf:system-source-directory \"cl-proteus\")))
                (flet ((title () (cl-iris:eval-js webview \"document.title\" :timeout 5)))
                  (loop repeat 100 until (search \"Waiting\" (title)) do (sleep 0.1))
                  (format t \"~&EXAMPLE-BEFORE ~A~%\" (title))
                  (setf agent (sb-ext:run-program
                               sb-ext:*runtime-pathname*
                               (list \"--noinform\" \"--non-interactive\" \"--no-userinit\"
                                     \"--load\" (namestring (merge-pathnames \".qlot/setup.lisp\" root))
                                     \"--eval\" \"(pushnew :cl-proteus-example-test *features*)\"
                                     \"--load\" (namestring (merge-pathnames \"examples/remote/agent.lisp\" root))
                                     \"--eval\" (format nil \"(cl-proteus.examples.remote-agent:main :path ~S)\" cl-user::*socket*)
                                     \"--eval\" \"(loop repeat 600 while (cl-proteus/client:shell-connected-p) do (sleep 0.1))\")
                               :directory root :output nil :error nil :wait nil))
                  (loop repeat 600 until (search \"Agent\" (title)) do (sleep 0.1))
                  (format t \"~&EXAMPLE-AFTER ~A~%\" (title))
                  ;; The page may still be loading again: look up elements each time.
                  (flet ((result () (cl-iris:eval-js webview \"(document.getElementById('result') || {}).textContent || ''\")))
                    (loop repeat 100 until (eql t (cl-iris:eval-js webview \"!!document.getElementById('roll')\"))
                          do (sleep 0.1))
                    (cl-iris:eval-js webview \"(document.getElementById('roll') || {click() {}}).click(); 0\")
                    (loop repeat 100 until (plusp (length (result))) do (sleep 0.1))
                    (format t \"~&EXAMPLE-TITLE ~A rolled ~A~%\" (title) (result)))))
            (error (e) (format t \"~&EXAMPLE-ERROR ~A~%\" e)))
       (when (and agent (sb-ext:process-alive-p agent)) (sb-ext:process-kill agent 9))
       (cl-proteus:stop-app)))))")

(defun remote-example-checks ()
  (let ((name "the remote example shows the agent's view and runs its command"))
    (when (selected-p name)
      (let ((socket (format nil "/tmp/cl-proteus-test-~D-example.sock" (sb-posix:getpid)))
            (file (namestring (merge-pathnames "examples/remote/shell.lisp"
                                               (asdf:system-source-directory "cl-proteus")))))
        (multiple-value-bind (output code)
            (run-child-lisp "(pushnew :cl-proteus-example-test *features*)"
                            (format nil "(load ~S)" file)
                            "(setf cl-iris:*window-defaults* '(:alpha 0 :activate nil))"
                            (format nil "(defparameter cl-user::*socket* ~S)" socket)
                            *remote-example-driver*
                            (format nil "(cl-proteus.examples.remote-shell:main :path ~S :activation-policy :accessory)" socket)
                            "(format t \"~&EXAMPLE-DONE~%\")")
          (check name
                 (or (and (eql 0 code)
                          (search "EXAMPLE-DONE" output)
                          (search "EXAMPLE-BEFORE Waiting for an agent" output)
                          (not (search "EXAMPLE-ERROR" output))
                          (not (search ";; cl-proteus: error" output))
                          (let ((line (search "EXAMPLE-TITLE Agent connected rolled " output)))
                            (and line (digit-char-p (char output (+ line (length "EXAMPLE-TITLE Agent connected rolled ")))))))
                     (progn (format t "~&;; remote example, exit code ~A, output:~%~A~%"
                                    code (last-lines output 40))
                            nil))))))))
