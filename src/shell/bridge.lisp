;;;; The bridge between pages and Lisp.
;;;;
;;;; Every frame of an app webview gets window.proteus.invoke(command, args),
;;;; a Promise of the command's value. It rides on cl-iris's iris.invoke, which
;;;; WebKit answers natively (WKScriptMessageHandlerWithReply): no JavaScript
;;;; is evaluated to carry a call or its answer.

(in-package #:cl-proteus/shell)

(defparameter *bridge-script*
  "(() => {
  if (window.proteus) return;
  const invoke = (command, args = {}) => {
    if (typeof command !== 'string') {
      return Promise.reject(new TypeError('proteus.invoke: the command must be a string'));
    }
    return window.iris.invoke({command, args});
  };
  Object.defineProperty(window, 'proteus', {
    value: Object.freeze({invoke}),
    enumerable: true,
  });
})();"
  "The script that gives every frame window.proteus.")

;;; Live app webviews, for events going to pages.

(defvar *app-webviews* '()
  "Every webview made with MAKE-APP-WEBVIEW and not yet destroyed.")

(defvar *app-webviews-lock* (sb-thread:make-mutex :name "cl-proteus webviews"))

(defun app-webviews ()
  "The live webviews made with MAKE-APP-WEBVIEW."
  (sb-thread:with-mutex (*app-webviews-lock*)
    (remove-if-not #'find-webview *app-webviews*)))

(defun forget-webview (webview)
  (sb-thread:with-mutex (*app-webviews-lock*)
    (setf *app-webviews* (remove webview *app-webviews*))))

;;; Commands

(defvar *command-caller* nil
  "While a command runs for a page, the webview of that page.")

(defun command-request (request)
  "The command name and arguments of one proteus.invoke REQUEST."
  (unless (hash-table-p request)
    (error 'command-error :message "an invoke carries {command, args}"))
  (let ((name (gethash "command" request))
        (arguments (gethash "args" request (make-hash-table :test 'equal))))
    (unless (stringp name)
      (error 'command-error :message "the command must be a string"))
    (unless (hash-table-p arguments)
      (error 'command-error :command name :message "args must be an object"))
    (values name arguments)))

(defun answer-invoke (webview request answer)
  "Run the command REQUEST names on a thread of its own, so a slow command
never holds up the window, and ANSWER the page with its value or error."
  (handler-case
      (multiple-value-bind (name arguments) (command-request request)
        (sb-thread:make-thread
         (lambda ()
           (handler-case
               (let ((*command-caller* webview))
                 (funcall answer (call-command name arguments)))
             (serious-condition (c)
               (funcall answer nil :error (princ-to-string c)))))
         :name (format nil "cl-proteus command ~A" name)))
    (serious-condition (c)
      (funcall answer nil :error (princ-to-string c)))))

;;; App webviews

(defun make-app-webview (window &rest options
                         &key on-message init-scripts url headers html (base-url "about:blank")
                         &allow-other-keys)
  "Make a webview in WINDOW, as cl-iris's MAKE-WEBVIEW does with OPTIONS,
whose pages can call commands with proteus.invoke(command, args).

Commands run on threads of their own, with *COMMAND-CALLER* bound to this
webview; an error rejects the page's Promise with its message. ON-INVOKE belongs
to the bridge and cannot be given; INIT-SCRIPTS run after the bridge's."
  (when (getf options :on-invoke)
    (error "MAKE-APP-WEBVIEW answers invoke itself; define commands instead of :ON-INVOKE."))
  (when (and url html)
    (error "Give MAKE-APP-WEBVIEW a URL or HTML, not both."))
  (let* ((box (list nil))
         (options (loop for (key value) on options by #'cddr
                        unless (member key '(:on-message :init-scripts :url :headers :html
                                             :base-url :invoke-async))
                          append (list key value)))
         (webview
           (apply #'make-webview window
                  :invoke-async t
                  :on-invoke (lambda (request answer)
                               (answer-invoke (car box) request answer))
                  :on-message on-message
                  :init-scripts (cons *bridge-script* init-scripts)
                  options)))
    ;; Known before any page can call: content is loaded only now.
    (setf (car box) webview)
    (sb-thread:with-mutex (*app-webviews-lock*)
      (push webview *app-webviews*))
    (cond (url (load-url webview url :headers headers))
          (html (load-html webview html :base-url base-url)))
    webview))

(defun destroy-app-webview (webview)
  "Destroy WEBVIEW, made by MAKE-APP-WEBVIEW, and stop sending it events."
  (forget-webview webview)
  (destroy-webview webview))
