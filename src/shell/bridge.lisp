;;;; The bridge between pages and Lisp.
;;;;
;;;; Every frame of an app webview gets window.proteus:
;;;;
;;;;   proteus.invoke(command, args)  a Promise of the command's value
;;;;   proteus.emit(event, payload)   to Lisp listeners and every page
;;;;   proteus.listen(event, fn)      returns a function that stops listening
;;;;   proteus.once(event, fn)        the same, for the next event only
;;;;
;;;; Invoke rides on cl-iris's iris.invoke, which WebKit answers natively
;;;; (WKScriptMessageHandlerWithReply); emit rides on iris.post. Only events
;;;; going to pages are carried by evaluating JavaScript.

(in-package #:cl-proteus/shell)

(defparameter *bridge-script*
  "(() => {
  if (window.proteus) return;
  const listeners = new Map();
  const listen = (event, fn, once) => {
    if (typeof event !== 'string' || typeof fn !== 'function') {
      throw new TypeError('proteus.listen: an event name and a function');
    }
    const entry = {fn, once};
    if (!listeners.has(event)) listeners.set(event, new Set());
    listeners.get(event).add(entry);
    return () => { listeners.get(event)?.delete(entry); };
  };
  const dispatch = (event, payload) => {
    for (const entry of [...(listeners.get(event) || [])]) {
      if (entry.once) listeners.get(event).delete(entry);
      try { entry.fn(payload, event); } catch (e) { console.error(e); }
    }
  };
  const proteus = Object.freeze({
    invoke: (command, args = {}) => {
      if (typeof command !== 'string') {
        return Promise.reject(new TypeError('proteus.invoke: the command must be a string'));
      }
      return window.iris.invoke({command, args});
    },
    emit: (event, payload = null) => {
      if (typeof event !== 'string') throw new TypeError('proteus.emit: the event must be a string');
      window.iris.post({proteusEvent: event, payload});
    },
    listen: (event, fn) => listen(event, fn, false),
    once: (event, fn) => listen(event, fn, true),
  });
  Object.defineProperty(window, 'proteus', {value: proteus, enumerable: true});
  Object.defineProperty(window, '__proteusDispatch', {value: dispatch});
})();"
  "The script that gives every frame window.proteus.")

;;; Live app webviews, for events going to pages.

(defvar *app-webviews* '()
  "Every webview made with MAKE-APP-WEBVIEW and not yet destroyed.")

(defvar *app-webviews-lock* (sb-thread:make-mutex :name "cl-proteus webviews"))

(defun app-webviews ()
  "The live webviews made with MAKE-APP-WEBVIEW."
  ;; Outside the lock: WEBVIEW-DESTROYED-P asks the main thread.
  (remove-if #'webview-destroyed-p
             (sb-thread:with-mutex (*app-webviews-lock*) (copy-list *app-webviews*))))

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

(defun answer-invoke (app request answer)
  "Run the command REQUEST names on a thread of its own, so a slow command
never holds up the window, and ANSWER the page with its value or error.
*APP* is APP while it runs, if the webview belongs to one."
  (handler-case
      (multiple-value-bind (name arguments) (command-request request)
        (let ((webview *webview*))
          (sb-thread:make-thread
           (lambda ()
             (handler-case
                 (let ((*command-caller* webview)
                       (*app* (or app *app*)))
                   (funcall answer (invoke-command name arguments)))
               (serious-condition (c)
                 (funcall answer nil :error (princ-to-string c)))))
           :name (format nil "cl-proteus command ~A" name))))
    (serious-condition (c)
      (funcall answer nil :error (princ-to-string c)))))

;;; Events

(defun page-event-p (message)
  (and (hash-table-p message)
       (nth-value 1 (gethash "proteusEvent" message))))

(defun receive-page-event (message)
  "A page emitted an event: tell the Lisp listeners and every page."
  (let ((event (gethash "proteusEvent" message))
        (payload (gethash "payload" message)))
    (when (stringp event)
      (relay-event event payload :source *webview*))))

(defun emit-to (webview event &optional payload)
  "Send the event EVENT with PAYLOAD to the page in WEBVIEW only."
  (check-type event string)
  (eval-js webview (format nil "window.__proteusDispatch && window.__proteusDispatch(~A, ~A)"
                           (to-json event) (to-json payload))
           :wait nil)
  event)

(defun emit-to-pages (event payload)
  "Send EVENT with PAYLOAD to the page in every app webview."
  (dolist (webview (app-webviews))
    (handler-case (emit-to webview event payload)
      (serious-condition (c)
        (format *error-output* "~&;; cl-proteus: error emitting ~S to a page: ~A~%" event c)))))

(pushnew 'emit-to-pages *event-forwarders*)

;;; App webviews

(defun make-app-webview (window &rest options
                         &key app on-message init-scripts url headers html (base-url "about:blank")
                           view frontend protocols
                         &allow-other-keys)
  "Make a webview in WINDOW, as cl-iris's MAKE-WEBVIEW does with OPTIONS,
whose pages get window.proteus: invoke for commands, emit, listen and once
for events.

Commands run on threads of their own, with *COMMAND-CALLER* bound to this
webview and *APP* to APP, if given; an error rejects the page's Promise with
its message. A command a connected client registered runs in that client.
ON-MESSAGE still hears iris.post values that are not proteus events.
ON-INVOKE belongs to the bridge and cannot be given; INIT-SCRIPTS run after
the bridge's.

The webview serves *SCHEME*: views at proteus://view/NAME/ and, if FRONTEND
is a directory, its files at proteus://app/ -- unless PROTOCOLS already
names that scheme. VIEW, a view name, is shown in place of URL or HTML."
  (when (getf options :on-invoke)
    (error "MAKE-APP-WEBVIEW answers invoke itself; define commands instead of :ON-INVOKE."))
  (when (< 1 (count-if #'identity (list url html view)))
    (error "Give MAKE-APP-WEBVIEW one of a URL, HTML or a VIEW."))
  (let* ((options (loop for (key value) on options by #'cddr
                        unless (member key '(:app :on-message :init-scripts :url :headers :html
                                             :base-url :invoke-async :view :frontend :protocols))
                          append (list key value)))
         (webview
           (apply #'make-webview window
                  :invoke-async t
                  :on-invoke (lambda (request answer)
                               (answer-invoke app request answer))
                  :on-message (lambda (message)
                                (if (page-event-p message)
                                    (receive-page-event message)
                                    (when on-message (funcall on-message message))))
                  :init-scripts (cons *bridge-script* init-scripts)
                  :protocols (if (assoc *scheme* protocols :test #'string-equal)
                                 protocols
                                 (append protocols (list (list *scheme* (scheme-handler frontend)))))
                  options)))
    ;; Content is loaded only now, so every page finds the webview listed.
    (sb-thread:with-mutex (*app-webviews-lock*)
      (push webview *app-webviews*))
    (cond (url (load-url webview url :headers headers))
          (html (load-html webview html :base-url base-url))
          (view (show-view webview view)))
    webview))

(defun destroy-app-webview (webview)
  "Destroy WEBVIEW, made by MAKE-APP-WEBVIEW, and stop sending it events."
  (forget-webview webview)
  (destroy-webview webview))
