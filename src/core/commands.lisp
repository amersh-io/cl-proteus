;;;; Commands: Lisp functions a page may call by name.
;;;;
;;;; A command is an ordinary function, registered under a name the page uses.
;;;; Its parameters are filled from the arguments object the page passes, by
;;;; name: a parameter USER-NAME takes the argument "userName". Only
;;;; registered commands can be called; nothing else in the image is reachable
;;;; from a page.

(in-package #:cl-proteus/core)

(defvar *commands* (make-hash-table :test 'equal)
  "Registered commands, by the name a page calls them with.")

(defvar *commands-lock* (sb-thread:make-mutex :name "cl-proteus commands"))

(defstruct (command (:constructor make-command (name function parameters documentation)))
  "A registered command: NAME as pages call it, the FUNCTION it calls (a
symbol, so redefining the function changes the command), and the names of
its PARAMETERS as the page passes them."
  (name "" :type string)
  (function nil :type symbol)
  (parameters '() :type list)
  (documentation nil))

(setf (documentation 'command-name 'function) "The name pages call the command by."
      (documentation 'command-function 'function)
      "The symbol naming the function the command calls."
      (documentation 'command-parameters 'function)
      "The names of the command's arguments, as pages pass them."
      (documentation 'command-documentation 'function)
      "The command's documentation string, or NIL.")

(defmethod print-object ((command command) stream)
  (print-unreadable-object (command stream :type t)
    (format stream "~S (~{~A~^ ~})" (command-name command) (command-parameters command))))

(define-condition command-error (error)
  ((command :initarg :command :initform nil :reader command-error-command)
   (message :initarg :message :reader command-error-message))
  (:report (lambda (c stream)
             (format stream "~@[Command ~S: ~]~A"
                         (command-error-command c) (command-error-message c))))
  (:documentation "A page called a command wrongly: an unknown name, or
arguments that do not match the command's parameters."))

(setf (documentation 'command-error-command 'function)
      "The name of the command that was called, or NIL if there was none."
      (documentation 'command-error-message 'function)
      "What was wrong with the call.")

(defun js-name (symbol)
  "The name SYMBOL goes by in JavaScript: USER-NAME becomes \"userName\"."
  (let ((parts (uiop:split-string (string-downcase (symbol-name symbol)) :separator "-")))
    (format nil "~A~{~:(~A~)~}" (first parts) (rest parts))))

(defun register-command (name function parameters &optional documentation)
  "Register FUNCTION, a symbol, as the command NAME (a string) whose
arguments are PARAMETERS, a list of symbols. Registering a name again
replaces the command. Returns NAME."
  (check-type name string)
  (check-type function symbol)
  (let ((command (make-command name function
                               (mapcar #'js-name parameters)
                               documentation)))
    (sb-thread:with-mutex (*commands-lock*)
      (setf (gethash name *commands*) command)))
  name)

(defun unregister-command (name)
  "Forget the command NAME. Returns true if there was one."
  (sb-thread:with-mutex (*commands-lock*)
    (remhash name *commands*)))

(defun find-command (name)
  "The registered command NAME, or NIL."
  (sb-thread:with-mutex (*commands-lock*)
    (values (gethash name *commands*))))

(defun list-commands ()
  "The names of every registered command, sorted."
  (sort (sb-thread:with-mutex (*commands-lock*)
          (loop for name being the hash-keys of *commands* collect name))
        #'string<))

(defmacro define-command (name (&rest parameters) &body body)
  "Define the function NAME with PARAMETERS and BODY, like DEFUN, and register
it as a command pages call by NAME's lower-case name:

  (define-command greet (user-name)
    (format nil \"Hello, ~A!\" user-name))

  // in the page
  await proteus.invoke('greet', {userName: 'Ada'})   // => \"Hello, Ada!\"

Only required parameters are allowed; each is filled from the argument of
its JavaScript name. The function stays callable from Lisp, and redefining
it, or evaluating the form again, changes the command at once."
  (dolist (parameter parameters)
    (when (or (not (symbolp parameter)) (member parameter lambda-list-keywords))
      (error "DEFINE-COMMAND takes only required parameters, not ~S." parameter)))
  (multiple-value-bind (body declarations documentation)
      (uiop:parse-body body :documentation t)
    `(progn
       (defun ,name ,parameters
         ,@(when documentation (list documentation))
         ,@declarations
         ,@body)
       (register-command ,(string-downcase (symbol-name name)) ',name ',parameters
                         ,documentation)
       ',name)))

(defun argument (arguments key)
  "The value of KEY in ARGUMENTS (a hash table or an alist), and whether it
was there."
  (etypecase arguments
    (hash-table (gethash key arguments))
    (list (let ((entry (assoc key arguments :test #'equal)))
            (values (cdr entry) (and entry t))))))

(defun call-command (name &optional (arguments '()))
  "Call the command NAME with ARGUMENTS, a hash table or an alist from
argument names to values, as a page's invoke does. Signals COMMAND-ERROR for
an unknown command or a missing argument; an extra argument is ignored."
  (let ((command (or (find-command name)
                     (error 'command-error :command name :message "no such command"))))
    (apply (command-function command)
           (mapcar (lambda (key)
                     (multiple-value-bind (value present) (argument arguments key)
                       (unless present
                         (error 'command-error :command name
                                               :message (format nil "missing argument ~S" key)))
                       value))
                   (command-parameters command)))))
