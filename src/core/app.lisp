;;;; Applications: windows, their pages, a front-end directory and shared state,
;;;; declared in one form.
;;;;
;;;; An APP is only a description and its state; the shell runs it. Evaluating
;;;; DEFINE-APP again updates the same object, and a running shell applies the
;;;; change to the live windows (see *APP-REDEFINED-HOOK*).

(in-package #:cl-proteus/core)

(defvar *apps* (make-hash-table :test 'eq)
  "Every application defined with DEFINE-APP, by name.")

(defvar *app* nil
  "The application in effect: bound while its commands run, and set by
RUN-APP when it is the only one running. APP-STATE uses it by default.")

(defvar *app-redefined-hook* '()
  "Functions of one argument, an APP, called after DEFINE-APP changes one.")

(defclass app ()
  ((name :initarg :name :reader app-name
         :documentation "The symbol the app was defined with.")
   (title :initarg :title :initform "" :accessor app-title
          :documentation "The application's name as people see it.")
   (frontend :initarg :frontend :initform nil :accessor app-frontend
             :documentation "The directory of front-end files the app's pages
are served from, under proteus://app/, or NIL.")
   (windows :initarg :windows :initform '() :accessor app-windows
            :documentation "Window specifications: lists (ID . OPTIONS), where
OPTIONS are MAKE-WINDOW's and :PAGE, :URL or :HTML for the webview.")
   (state :initform (make-hash-table :test 'equal) :reader app-state-table
          :documentation "The state commands share, by key.")
   (lock :initform (sb-thread:make-mutex :name "cl-proteus app state") :reader app-lock
         :documentation "Guards the state."))
  (:documentation "An application: what DEFINE-APP declares. RUN-APP shows it."))

(defmethod print-object ((app app) stream)
  (print-unreadable-object (app stream :type t)
    (format stream "~S~@[ ~S~] ~D window~:P"
            (app-name app) (and (plusp (length (app-title app))) (app-title app))
            (length (app-windows app)))))

(defmethod describe-object ((app app) stream)
  (format stream "~&~S is an application.~%" app)
  (format stream "  Title:     ~S~%" (app-title app))
  (format stream "  Front end: ~:[none~;~:*~A~]~%" (app-frontend app))
  (dolist (window (app-windows app))
    (format stream "  Window ~S: ~{~S~^ ~}~%" (car window) (cdr window)))
  (sb-thread:with-recursive-lock ((app-lock app))
    (maphash (lambda (key value) (format stream "  State ~S = ~S~%" key value))
             (app-state-table app))))

(defun find-app (name &optional (errorp t))
  "The application named NAME, a symbol; signals an error if there is none
and ERRORP is true, or else returns NIL."
  (or (gethash name *apps*)
      (and errorp (error "No application named ~S." name))))

(defun apps ()
  "Every defined application."
  (loop for app being the hash-values of *apps* collect app))

(defun ensure-app (name &key (title "") frontend windows state)
  "Define the application NAME, or update the one already defined: TITLE,
FRONTEND and WINDOWS are replaced; STATE, a plist, gives initial values to
keys the app has no value for yet, so a running app keeps its state. Calls
*APP-REDEFINED-HOOK* when an existing app changes. Returns the app."
  (let* ((existing (find-app name nil))
         (app (or existing (setf (gethash name *apps*) (make-instance 'app :name name)))))
    (setf (app-title app) title
          (app-frontend app) (and frontend (uiop:ensure-directory-pathname frontend))
          (app-windows app) windows)
    (sb-thread:with-recursive-lock ((app-lock app))
      (loop for (key value) on state by #'cddr
            do (multiple-value-bind (old present) (gethash key (app-state-table app))
                 (declare (ignore old))
                 (unless present (setf (gethash key (app-state-table app)) value)))))
    (when existing
      (dolist (hook *app-redefined-hook*)
        (funcall hook app)))
    app))

(defmacro define-app (name &body clauses)
  "Declare the application NAME (a symbol) in clauses:

  (define-app notes
    (:title \"Notes\")
    (:frontend \"frontend/\")            ; next to this source file
    (:state :count 0 :items #())
    (:window main :title \"Notes\" :width 720 :height 480 :page \"index.html\"))

(:FRONTEND dir) serves the files in DIR at proteus://app/; a relative DIR is
taken from the directory of the source file the form is in. Each (:WINDOW id . options) is a window:
MAKE-WINDOW's options, and for its page :PAGE (a path under the front end),
:URL or :HTML. (:STATE key value ...) gives the state's initial values.

Evaluating the form again updates the app; RUN-APP applies the change to
windows already open."
  (let ((title "") (frontend nil) (state '()) (windows '()))
    (dolist (clause clauses)
      (destructuring-bind (kind &rest arguments) clause
        (ecase kind
          (:title (setf title (first arguments)))
          (:frontend (setf frontend (first arguments)))
          (:state (setf state arguments))
          (:window (push arguments windows)))))
    `(progn
       (ensure-app ',name
                   :title ,title
                   :frontend ,(when frontend
                                ;; Relative to the source file the form is in, which
                                ;; is known when the form is compiled or loaded.
                                `(merge-pathnames ,frontend
                                                  ,(let ((source (or *compile-file-truename*
                                                                     *load-truename*)))
                                                     (if source
                                                         (uiop:pathname-directory-pathname source)
                                                         '*default-pathname-defaults*))))
                   :windows (list ,@(mapcar (lambda (window)
                                              `(list ',(first window) ,@(rest window)))
                                            (reverse windows)))
                   :state (list ,@state))
       ',name)))

;;; State

(defun current-app (app)
  (or app *app* (error "No application is in effect: pass one, or bind *APP*.")))

(defun app-state (key &optional app)
  "The value of KEY in the state of APP (default *APP*), and whether it has one."
  (let ((app (current-app app)))
    (sb-thread:with-recursive-lock ((app-lock app))
      (gethash key (app-state-table app)))))

(defun (setf app-state) (value key &optional app)
  "Set KEY in the state of APP (default *APP*) to VALUE."
  (let ((app (current-app app)))
    (sb-thread:with-recursive-lock ((app-lock app))
      (setf (gethash key (app-state-table app)) value))))

(defun update-app-state (key function &optional app)
  "Set KEY in the state of APP (default *APP*) to FUNCTION of its current
value (NIL if none), atomically -- other threads wait. Returns the new value."
  (let ((app (current-app app)))
    (sb-thread:with-recursive-lock ((app-lock app))
      (setf (gethash key (app-state-table app))
            (funcall function (gethash key (app-state-table app)))))))
