;;;; Running an application: its windows, their webviews and its front end.
;;;;
;;;; RUN-APP opens the windows an APP declares. While it runs, evaluating its
;;;; DEFINE-APP again is applied to them: titles and sizes change in place, a
;;;; page that changed is loaded again, new windows open and removed ones close.

(in-package #:cl-proteus/shell)

(defvar *open-windows* (make-hash-table :test 'eq)
  "For each running APP, an alist from window id to an OPEN-WINDOW.")

(defvar *open-windows-lock* (sb-thread:make-mutex :name "cl-proteus open windows"))

(defstruct (open-window (:constructor make-open-window (id spec window webview)))
  "One window of a running app: its ID, the SPEC it was opened from, and its
WINDOW and WEBVIEW."
  id spec window webview)

(defparameter *page-keys* '(:page :url :html :view)
  "The keys of a window spec that say what its webview shows.")

(defun page-url (spec)
  "The proteus:// URL of SPEC's :PAGE or :VIEW, or its :URL."
  (let ((page (getf (rest spec) :page))
        (view (getf (rest spec) :view)))
    (cond (page (format nil "~A://app/~A" *scheme* (string-left-trim "/" page)))
          (view (view-url view))
          (t (getf (rest spec) :url)))))

(defun window-options (spec)
  "MAKE-WINDOW's options in SPEC."
  (loop for (key value) on (rest spec) by #'cddr
        unless (member key *page-keys*)
          append (list key value)))

(defun open-app-window (app spec)
  "Open the window SPEC of APP with its webview, and remember it."
  (let* ((window (apply #'make-window (window-options spec)))
         (html (getf (rest spec) :html))
         (url (unless html (page-url spec)))
         (webview (apply #'make-app-webview window
                         :app app
                         :frontend (app-frontend app)
                         (cond (html (list :html html))
                               (url (list :url url))))))
    (sb-thread:with-recursive-lock (*open-windows-lock*)
      (push (cons (first spec) (make-open-window (first spec) spec window webview))
            (gethash app *open-windows*)))
    window))

(defun close-app-window (app id)
  "Close the window ID of APP."
  (let ((open (sb-thread:with-recursive-lock (*open-windows-lock*)
                (let ((entry (assoc id (gethash app *open-windows*))))
                  (setf (gethash app *open-windows*) (remove entry (gethash app *open-windows*)))
                  (cdr entry)))))
    (when open
      (destroy-app-webview (open-window-webview open))
      (close-window (open-window-window open)))))

(defun app-open-windows (app)
  "The OPEN-WINDOW records of APP's windows that the user has not closed."
  (sb-thread:with-recursive-lock (*open-windows-lock*)
    (remove-if (lambda (open) (window-closed-p (open-window-window open)))
               (mapcar #'cdr (gethash app *open-windows*)))))

(defun app-window (id &optional (app *app*))
  "The window ID of the running APP, or NIL."
  (let ((open (find id (app-open-windows app) :key #'open-window-id)))
    (and open (open-window-window open))))

(defun app-webview (id &optional (app *app*))
  "The webview of the window ID of the running APP, or NIL."
  (let ((open (find id (app-open-windows app) :key #'open-window-id)))
    (and open (open-window-webview open))))

(defun app-running-p (&optional (app *app*))
  "True while RUN-APP shows APP."
  (sb-thread:with-recursive-lock (*open-windows-lock*)
    (nth-value 1 (gethash app *open-windows*))))

(defun refresh-app (app)
  "Bring the open windows of the running APP in line with its definition."
  (when (app-running-p app)
    (let ((specs (app-windows app)))
      (dolist (open (app-open-windows app))
        (unless (assoc (open-window-id open) specs)
          (close-app-window app (open-window-id open))))
      (dolist (spec specs)
        (let ((open (find (first spec) (app-open-windows app) :key #'open-window-id)))
          (cond ((null open)
                 (open-app-window app spec))
                ((not (equal spec (open-window-spec open)))
                 (update-app-window app open spec))))))))

(defun update-app-window (app open spec)
  "Apply the changed SPEC to the open window OPEN."
  (let ((window (open-window-window open))
        (webview (open-window-webview open))
        (old (rest (open-window-spec open)))
        (new (rest spec)))
    (flet ((changed (key) (not (equal (getf old key) (getf new key)))))
      (when (and (changed :title) (getf new :title))
        (setf (window-title window) (getf new :title)))
      (when (and (or (changed :width) (changed :height))
                 (getf new :width) (getf new :height))
        (setf (window-size window) (list (getf new :width) (getf new :height))))
      (when (some #'changed *page-keys*)
        (let ((html (getf new :html)))
          (if html
              (load-html webview html)
              (let ((url (page-url spec)))
                (when url (load-url webview url)))))))
    (setf (open-window-spec open) spec)
    (values app)))

(pushnew 'refresh-app *app-redefined-hook*)

(defun run-app (app &rest options &key (quit-on-last-window-closed t) on-launch
                &allow-other-keys)
  "Show APP (an APP or its name): open its windows and run the application
on this thread, which must be the main thread, until it quits. *APP* is APP
meanwhile unless another app is already in effect. OPTIONS go to cl-iris's
RUN-APPLICATION; closing the last window quits unless
QUIT-ON-LAST-WINDOW-CLOSED is NIL, and ON-LAUNCH is called on the main
thread once the windows are open."
  (let* ((app (if (typep app 'app) app (find-app app)))
         (previous *app*))
    (when (app-running-p app)
      (error "~S is already running." app))
    (sb-thread:with-recursive-lock (*open-windows-lock*)
      (setf (gethash app *open-windows*) '()))
    (unless previous (setf *app* app))
    (unwind-protect
         (apply #'run-application
                :quit-on-last-window-closed quit-on-last-window-closed
                :on-launch (lambda ()
                             (dolist (spec (app-windows app))
                               (open-app-window app spec))
                             (when on-launch (funcall on-launch)))
                (loop for (key value) on options by #'cddr
                      unless (member key '(:quit-on-last-window-closed :on-launch))
                        append (list key value)))
      (dolist (open (sb-thread:with-recursive-lock (*open-windows-lock*)
                      (mapcar #'cdr (gethash app *open-windows*))))
        (ignore-errors (destroy-app-webview (open-window-webview open)))
        (ignore-errors (close-window (open-window-window open))))
      (sb-thread:with-recursive-lock (*open-windows-lock*)
        (remhash app *open-windows*))
      (unless previous (setf *app* nil))))
  (values))

(defun stop-app ()
  "Make RUN-APP return. Callable from any thread."
  (stop-application))
