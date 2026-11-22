;;;; A connection to a shell.
;;;;
;;;; CONNECT-SHELL registers every command and view of this image with the
;;;; shell listening on a socket, and keeps them current: defining a command
;;;; or a view afterwards is sent at once. The shell sends invokes, which run
;;;; here on threads of their own, and events, which reach this image's
;;;; listeners; EMIT here reaches the shell's pages and listeners.

(in-package #:cl-proteus/client)

(defclass shell-connection ()
  ((path :initarg :path :reader shell-connection-path
         :documentation "The path of the shell's socket.")
   (socket :initarg :socket :reader connection-socket)
   (stream :initarg :stream :reader connection-stream)
   (write-lock :initform (sb-thread:make-mutex :name "cl-proteus client write")
               :reader connection-write-lock)
   (app :initarg :app :reader connection-app)
   (thread :initform nil :accessor connection-thread)
   (open :initform t :accessor connection-open-p))
  (:documentation "A connection to a shell, made by CONNECT-SHELL."))

(setf (documentation 'shell-connection-path 'function)
      "The path of the socket of the shell a SHELL-CONNECTION is to.")

(defmethod print-object ((connection shell-connection) stream)
  (print-unreadable-object (connection stream :type t)
    (format stream "~A~:[ closed~;~]" (shell-connection-path connection)
            (connection-open-p connection))))

(defvar *shell* nil
  "The connection to the shell, while there is one.")

(defun shell-connected-p (&optional (connection *shell*))
  "True if CONNECTION, by default *SHELL*, is open."
  (and connection (connection-open-p connection)))

;;; Messages

(defun message (type &rest fields)
  (let ((table (make-hash-table :test 'equal)))
    (setf (gethash "type" table) type)
    (loop for (key value) on fields by #'cddr
          do (setf (gethash key table) value))
    table))

(defun send (connection message)
  "Write MESSAGE to CONNECTION as one line. The text is made first, so a
value that is not JSON signals here and nothing is written."
  (let ((line (write-json message))
        (stream (connection-stream connection)))
    (sb-thread:with-mutex ((connection-write-lock connection))
      (write-string line stream)
      (write-char #\Newline stream)
      (finish-output stream))))

(defun send-if-connected (message)
  (let ((connection *shell*))
    (when (shell-connected-p connection)
      (handler-case (send connection message)
        (serious-condition (c)
          (format *error-output* "~&;; cl-proteus: error sending to the shell: ~A~%" c))))))

(defun command-message (name command)
  (if command
      (message "command" "name" name
                         "parameters" (coerce (command-parameters command) 'vector))
      (message "uncommand" "name" name)))

(defun view-message (view)
  (let ((files (make-hash-table :test 'equal)))
    (loop for (path . octets) in (view-files view)
          do (setf (gethash path files) (cl-proteus/core::base64-encode octets)))
    (message "view" "name" (view-name view) "files" files)))

;;; Keeping the shell current

(defun send-command-change (name command)
  (send-if-connected (command-message name command)))

(defun send-view (view)
  (send-if-connected (view-message view)))

(defun send-event (event payload)
  (send-if-connected (message "emit" "event" event "payload" payload)))

(pushnew 'send-command-change *commands-changed-hook*)
(pushnew 'send-view *views-changed-hook*)
(pushnew 'send-event *event-forwarders*)

;;; What the shell sends

(defun run-invoke (connection message)
  "Run the command an invoke MESSAGE names on a thread of its own and send
back its value or error."
  (let ((id (gethash "id" message))
        (name (gethash "name" message))
        (arguments (gethash "args" message)))
    (sb-thread:make-thread
     (lambda ()
       (let ((reply (handler-case
                        (let ((*app* (or (connection-app connection) *app*)))
                          (let ((value (call-command name (if (hash-table-p arguments)
                                                               arguments
                                                               '()))))
                            ;; Made here so a value that is not JSON becomes an error.
                            (write-json value)
                            (message "result" "id" id "value" value)))
                      (serious-condition (c)
                        (message "error" "id" id "message" (princ-to-string c))))))
         (handler-case (send connection reply)
           (serious-condition (c)
             (format *error-output* "~&;; cl-proteus: error answering the shell: ~A~%" c)))))
     :name (format nil "cl-proteus command ~A" name))))

(defun handle-message (connection message)
  (when (hash-table-p message)
    (let ((type (gethash "type" message)))
      (cond ((equal type "invoke") (run-invoke connection message))
            ((equal type "event")
             (let ((event (gethash "event" message)))
               (when (stringp event)
                 (dispatch-event event (gethash "payload" message) :source connection))))))))

(defun read-shell (connection)
  (unwind-protect
       (handler-case
           (loop for line = (read-line (connection-stream connection) nil)
                 while line
                 do (handler-case (handle-message connection (read-json line))
                      (serious-condition (c)
                        (format *error-output* "~&;; cl-proteus: bad message from the shell: ~A~%"
                                c))))
         (serious-condition () nil))
    (close-connection connection)))

(defun close-connection (connection)
  (when (connection-open-p connection)
    (setf (connection-open-p connection) nil)
    (ignore-errors (sb-bsd-sockets:socket-shutdown (connection-socket connection) :direction :io))
    (ignore-errors (sb-bsd-sockets:socket-close (connection-socket connection))))
  (when (eq *shell* connection)
    (setf *shell* nil)))

;;; Connecting

(defun connect-shell (path &key app name)
  "Connect to the shell listening on the socket PATH, make the connection
*SHELL* -- closing the one before, if any -- and return it.

Every command and view of this image is registered with the shell; one
defined or redefined later is sent at once. Invokes from the shell's pages
run here, each on a thread of its own with *APP* bound to APP, if given.
EMIT reaches the shell's pages and listeners, and events from the shell
reach this image's listeners, with *EVENT-SOURCE* the connection. NAME is
how the shell's CONNECTION-NAME shows this image."
  (when (shell-connected-p) (disconnect-shell))
  (let* ((path (uiop:native-namestring (merge-pathnames path)))
         (socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (handler-case (sb-bsd-sockets:socket-connect socket path)
      (error (e)
        (ignore-errors (sb-bsd-sockets:socket-close socket))
        (error "No shell answers on ~S: ~A" path e)))
    (let ((connection (make-instance 'shell-connection
                                     :path path :socket socket :app app
                                     :stream (sb-bsd-sockets:socket-make-stream
                                              socket :input t :output t
                                                     :element-type 'character
                                                     :external-format :utf-8
                                                     :buffering :full))))
      ;; Made current before the commands and views are listed, so one
      ;; defined meanwhile is sent by the hooks rather than missed.
      (setf *shell* connection)
      (send connection (message "hello" "protocol" 1 "name" (or name :null)))
      (dolist (name (list-commands))
        (let ((command (find-command name)))
          (when command (send connection (command-message name command)))))
      (dolist (name (list-views))
        (let ((view (find-view name)))
          (when view (send connection (view-message view)))))
      (setf (connection-thread connection)
            (sb-thread:make-thread #'read-shell :arguments (list connection)
                                                :name "cl-proteus client"))
      connection)))

(defun disconnect-shell (&optional (connection *shell*))
  "Close CONNECTION, by default *SHELL*. The shell forgets its commands and
rejects the invokes it had not answered; its views stay in the shell."
  (when connection
    (close-connection connection)
    (let ((thread (connection-thread connection)))
      (when (and thread (not (eq thread sb-thread:*current-thread*)))
        (ignore-errors (sb-thread:join-thread thread :timeout 5)))))
  nil)

(defmacro with-shell ((path &rest options) &body body)
  "Run BODY connected to the shell on PATH, as CONNECT-SHELL with OPTIONS
connects, and disconnect after."
  `(progn
     (connect-shell ,path ,@options)
     (unwind-protect (progn ,@body)
       (disconnect-shell))))
