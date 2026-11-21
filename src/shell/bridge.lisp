;;;; The bridge between a page and the commands.
;;;;
;;;; The page gets window.proteus.invoke(command, args), a Promise. It rides on
;;;; cl-iris's iris.invoke, which WebKit answers natively
;;;; (WKScriptMessageHandlerWithReply): no JavaScript is evaluated to carry a
;;;; call or its answer.

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

(defun answer-invoke (request)
  "Answer one proteus.invoke: REQUEST is {command, args} as a hash table."
  (unless (hash-table-p request)
    (error 'command-error :message "an invoke carries {command, args}"))
  (let ((name (gethash "command" request))
        (arguments (gethash "args" request (make-hash-table :test 'equal))))
    (unless (stringp name)
      (error 'command-error :message "the command must be a string"))
    (unless (hash-table-p arguments)
      (error 'command-error :command name :message "args must be an object"))
    (call-command name arguments)))

(defun make-app-webview (window &rest options &key init-scripts &allow-other-keys)
  "Make a webview in WINDOW, as cl-iris's MAKE-WEBVIEW does with OPTIONS,
whose pages can call commands with proteus.invoke(command, args). An error
in a command rejects the page's Promise with its message.

ON-INVOKE belongs to the bridge and cannot be given; every other option of
MAKE-WEBVIEW can, and INIT-SCRIPTS run after the bridge's."
  (when (getf options :on-invoke)
    (error "MAKE-APP-WEBVIEW answers invoke itself; define commands instead of :ON-INVOKE."))
  (let ((options (copy-list options)))
    (remf options :init-scripts)
    (apply #'make-webview window
           :on-invoke #'answer-invoke
           :init-scripts (cons *bridge-script* init-scripts)
           options)))
