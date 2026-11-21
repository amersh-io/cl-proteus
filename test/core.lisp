;;;; Tests for cl-proteus/core: no window involved.

(in-package #:cl-proteus/test)

(define-command test-add (a b)
  "Add two numbers."
  (+ a b))

(define-command test-greet (user-name)
  (format nil "Hello, ~A!" user-name))

(defun args (&rest plist)
  (let ((table (make-hash-table :test 'equal)))
    (loop for (key value) on plist by #'cddr do (setf (gethash key table) value))
    table))

(defun core-checks ()
  (check "a command is registered under its lower-case name"
         (and (find-command "test-add") (member "test-add" (list-commands) :test #'string=)))
  (check "a command keeps its docstring"
         (equal "Add two numbers." (command-documentation (find-command "test-add"))))
  (check "a defined command is still an ordinary function"
         (= 5 (test-add 2 3)))
  (check "call-command fills parameters from arguments by name"
         (= 42 (call-command "test-add" (args "a" 40 "b" 2))))
  (check "parameter names become camelCase argument names"
         (and (equal "userName" (js-name 'user-name))
              (equal "Hello, Ada!" (call-command "test-greet" (args "userName" "Ada")))))
  (check "arguments may also be an alist"
         (= 7 (call-command "test-add" '(("a" . 3) ("b" . 4)))))
  (check "an unknown command signals COMMAND-ERROR"
         (handler-case (progn (call-command "no-such-command") nil)
           (command-error (e) (search "no such command" (princ-to-string e)))))
  (check "a missing argument signals COMMAND-ERROR naming it"
         (handler-case (progn (call-command "test-add" (args "a" 1)) nil)
           (command-error (e) (search "\"b\"" (princ-to-string e)))))
  (check "redefining the function changes the command"
         (let ((old (fdefinition 'test-add)))
           (unwind-protect
                (progn (setf (fdefinition 'test-add) (lambda (a b) (* a b)))
                       (= 6 (call-command "test-add" (args "a" 2 "b" 3))))
             (setf (fdefinition 'test-add) old))))
  (check "define-command refuses lambda-list keywords"
         (handler-case (progn (macroexpand-1 '(define-command bad (&optional x) x)) nil)
           (error () t)))
  (check "an unregistered command cannot be called"
         (progn (register-command "test-temporary" 'test-add '(a b))
                (unregister-command "test-temporary")
                (handler-case (progn (call-command "test-temporary" (args "a" 1 "b" 2)) nil)
                  (command-error () t)))))

(defun event-checks ()
  (let ((heard '()))
    (flet ((hear (payload) (push payload heard)))
      (let ((listener (listen-event "test-tick" #'hear)))
        (check "emit reaches a Lisp listener with its payload"
               (progn (emit "test-tick" 1) (equal '(1) heard)))
        (check "a listener hears every event until it stops"
               (progn (emit "test-tick" 2)
                      (and (unlisten-event listener)
                           (progn (emit "test-tick" 3) (equal '(2 1) heard)))))
        (check "unlisten-event says whether the listener was still there"
               (not (unlisten-event listener)))))
    (setf heard '())
    (listen-event-once "test-once" (lambda (payload) (push payload heard)))
    (check "a once listener hears one event and goes"
           (progn (emit "test-once" :a) (emit "test-once" :b)
                  (and (equal '(:a) heard) (null (listeners "test-once")))))
    (check "an error in one listener is reported and the others still run"
           (let* ((ran nil)
                  (bad (listen-event "test-error" (lambda (p) (declare (ignore p)) (error "boom"))))
                  (good (listen-event "test-error" (lambda (p) (declare (ignore p)) (setf ran t))))
                  (*error-output* (make-broadcast-stream)))
             (emit "test-error")
             (unlisten-event bad) (unlisten-event good)
             ran))
    (check "a listener given as a symbol follows its redefinition"
           (let ((listener (listen-event "test-symbol" 'test-symbol-listener)))
             (setf (fdefinition 'test-symbol-listener) (lambda (p) (push (list :new p) heard)))
             (emit "test-symbol" 7)
             (unlisten-event listener)
             (equal '(:new 7) (first heard))))
    (check "emit hands events to the forwarders too"
           (let ((forwarded nil))
             (let ((*event-forwarders* (list (lambda (name payload) (setf forwarded (list name payload))))))
               (emit "test-forward" 9))
             (equal '("test-forward" 9) forwarded)))
    (check "a listener prints with its event"
           (let ((listener (listen-event "test-print" #'identity)))
             (prog1 (search "\"test-print\"" (prin1-to-string listener))
               (unlisten-event listener))))))

(defun test-symbol-listener (payload)
  (declare (ignore payload))
  nil)
