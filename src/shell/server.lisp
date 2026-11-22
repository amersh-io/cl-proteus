;;;; The shell's socket: commands, events and views from other images.
;;;;
;;;; A client -- another Lisp image, which holds no window -- connects to a
;;;; Unix-domain socket the shell listens on and registers its commands and
;;;; views. A page's invoke of such a command is sent to the client and its
;;;; answer comes back the same way; events cross in both directions. When a
;;;; client goes away its commands go with it and the invokes it had not
;;;; answered are rejected, each once; the windows stay, and the next client
;;;; -- the next generation of the image -- registers again.
;;;;
;;;; Messages are JSON objects, one per line; docs/protocol.md lists them.
;;;; Each connection has a thread of its own that reads; writes take the
;;;; connection's lock.

(in-package #:cl-proteus/shell)

(defparameter *protocol-version* 1
  "The version of the socket protocol this shell speaks.")

(defvar *server-lock* (sb-thread:make-mutex :name "cl-proteus server")
  "Guards the remote commands, the pending invokes and the connection lists.")

(defclass connection ()
  ((id :initarg :id :reader connection-id
       :documentation "A number that tells this connection from every other.")
   (name :initform nil :accessor connection-name
         :documentation "The name the client gave in its hello, or NIL.")
   (socket :initarg :socket :reader connection-socket)
   (stream :initarg :stream :reader connection-stream)
   (write-lock :initform (sb-thread:make-mutex :name "cl-proteus connection write")
               :reader connection-write-lock)
   (server :initarg :server :reader connection-server)
   (open :initform t :accessor connection-open-p
         :documentation "True until the connection is dropped."))
  (:documentation "One client connected to a shell server."))

(setf (documentation 'connection-id 'function) "The number of CONNECTION."
      (documentation 'connection-name 'function)
      "The name CONNECTION's client gave when it said hello, or NIL."
      (documentation 'connection-open-p 'function)
      "True until CONNECTION is dropped.")

(defmethod print-object ((connection connection) stream)
  (print-unreadable-object (connection stream :type t)
    (format stream "#~D~@[ ~S~]~:[ closed~;~]" (connection-id connection)
            (connection-name connection) (connection-open-p connection))))

(defclass shell-server ()
  ((path :initarg :path :reader shell-server-path
         :documentation "The path of the socket.")
   (socket :initarg :socket :reader server-socket)
   (connections :initform '() :accessor server-connections)
   (stopping :initform nil :accessor server-stopping)
   (thread :initform nil :accessor server-thread))
  (:documentation "A shell listening for clients on a Unix-domain socket.
SERVE-SHELL makes one; STOP-SHELL ends it."))

(setf (documentation 'shell-server-path 'function) "The path of the server's socket.")

(defmethod print-object ((server shell-server) stream)
  (print-unreadable-object (server stream :type t)
    (format stream "~A ~D client~:P" (shell-server-path server)
            (length (server-connections server)))))

(defvar *next-connection-id* 0)

(defvar *servers* '()
  "Every running shell server.")

(defvar *remote-commands* (make-hash-table :test 'equal)
  "Commands registered by clients: name to (CONNECTION . PARAMETERS).")

(defstruct (pending (:constructor make-pending (connection)))
  "An invoke sent to CONNECTION and not yet settled."
  connection
  (done nil)
  (value nil)
  (error nil)
  (queue (sb-thread:make-waitqueue)))

(defvar *pending* (make-hash-table)
  "Invokes sent to clients and not yet settled, by id.")

(defvar *next-invoke-id* 0)

;;; Messages

(defun message (type &rest fields)
  "A message of TYPE with FIELDS, alternating names and values."
  (let ((table (make-hash-table :test 'equal)))
    (setf (gethash "type" table) type)
    (loop for (key value) on fields by #'cddr
          do (setf (gethash key table) value))
    table))

(defun send-message (connection message)
  "Write MESSAGE to CONNECTION as one line."
  (let ((stream (connection-stream connection)))
    (sb-thread:with-mutex ((connection-write-lock connection))
      (write-json message stream)
      (write-char #\Newline stream)
      (finish-output stream))))

(defun field (message name)
  (gethash name message))

;;; Commands that run in a client

(defun remote-commands ()
  "The names of the commands connected clients registered, sorted."
  (sort (sb-thread:with-mutex (*server-lock*)
          (loop for name being the hash-keys of *remote-commands* collect name))
        #'string<))

(defun remote-command-connection (name)
  (sb-thread:with-mutex (*server-lock*)
    (car (gethash name *remote-commands*))))

(defun settle (id &key connection value error)
  "Settle the pending invoke ID with VALUE or ERROR, once: only if it is still
pending and, when CONNECTION is given, was sent to that connection. Returns
true if this call settled it."
  (sb-thread:with-mutex (*server-lock*)
    (let ((pending (gethash id *pending*)))
      (when (and pending (or (null connection) (eq connection (pending-connection pending))))
        (remhash id *pending*)
        (setf (pending-value pending) value
              (pending-error pending) error
              (pending-done pending) t)
        (sb-thread:condition-broadcast (pending-queue pending))
        t))))

(defun call-remote (connection name arguments)
  "Run the command NAME with ARGUMENTS in CONNECTION's client and return its
value; signal COMMAND-ERROR if it fails or the client goes away first."
  (let* ((pending (make-pending connection))
         (id (sb-thread:with-mutex (*server-lock*)
               (let ((id (incf *next-invoke-id*)))
                 (setf (gethash id *pending*) pending)
                 id))))
    (handler-case
        (send-message connection (message "invoke" "id" id "name" name
                                          "args" (if (hash-table-p arguments)
                                                     arguments
                                                     (let ((table (make-hash-table :test 'equal)))
                                                       (loop for (key . value) in arguments
                                                             do (setf (gethash key table) value))
                                                       table))))
      (serious-condition ()
        (settle id :error "the client running the command cannot be reached")))
    (sb-thread:with-mutex (*server-lock*)
      (loop until (pending-done pending)
            do (sb-thread:condition-wait (pending-queue pending) *server-lock*)))
    (if (pending-error pending)
        ;; The client's message already names the command.
        (error 'command-error :message (pending-error pending))
        (pending-value pending))))

(defun invoke-command (name &optional (arguments '()))
  "Call the command NAME with ARGUMENTS as a page's invoke does: in the
client that registered it, if one did, or else in this image with
CALL-COMMAND. A client's command is used over a local one of the same name."
  (let ((connection (remote-command-connection name)))
    (if connection
        (call-remote connection name arguments)
        (call-command name arguments))))

;;; Events

(defun emit-to-clients (event payload &key except)
  "Send EVENT with PAYLOAD to every connected client but EXCEPT."
  (dolist (connection (shell-clients))
    (unless (eq connection except)
      (handler-case (send-message connection (message "event" "event" event "payload" payload))
        (serious-condition (c)
          (format *error-output* "~&;; cl-proteus: error sending ~S to a client: ~A~%" event c))))))

(defun forward-to-clients (event payload)
  (emit-to-clients event payload))

(pushnew 'forward-to-clients *event-forwarders*)

(defun relay-event (event payload &key source except)
  "An event came from SOURCE, a page's webview or a connection: tell the
Lisp listeners, every page and every client but EXCEPT."
  (dispatch-event event payload :source source)
  (emit-to-pages event payload)
  (emit-to-clients event payload :except except))

;;; Connections

(defun shell-clients (&optional server)
  "The open connections of SERVER, or of every server."
  (sb-thread:with-mutex (*server-lock*)
    (if server
        (copy-list (server-connections server))
        (loop for server in *servers* append (copy-list (server-connections server))))))

(defun view-files-from-message (files)
  (unless (hash-table-p files)
    (error "a view's files must be an object"))
  (loop for path being the hash-keys of files using (hash-value data)
        collect (cons path (cl-proteus/core::base64-decode data))))

(defun handle-message (connection message)
  "Act on one MESSAGE from CONNECTION."
  (unless (hash-table-p message)
    (error "a message must be an object"))
  (let ((type (field message "type")))
    (cond
      ((equal type "hello")
       (setf (connection-name connection)
             (let ((name (field message "name"))) (and (stringp name) name)))
       (send-message connection (message "welcome" "protocol" *protocol-version*)))
      ((equal type "command")
       (let ((name (field message "name"))
             (parameters (field message "parameters")))
         (check-type name string)
         (sb-thread:with-mutex (*server-lock*)
           (setf (gethash name *remote-commands*)
                 (cons connection (coerce (or parameters #()) 'list))))))
      ((equal type "uncommand")
       (let ((name (field message "name")))
         (sb-thread:with-mutex (*server-lock*)
           (when (eq connection (car (gethash name *remote-commands*)))
             (remhash name *remote-commands*)))))
      ((equal type "view")
       (ensure-view (field message "name")
                    :files (view-files-from-message (field message "files"))))
      ((equal type "emit")
       (let ((event (field message "event")))
         (check-type event string)
         (relay-event event (field message "payload") :source connection :except connection)))
      ((equal type "result")
       (settle (field message "id") :connection connection :value (field message "value")))
      ((equal type "error")
       (settle (field message "id") :connection connection
                                    :error (let ((text (field message "message")))
                                             (if (stringp text) text "the command failed"))))
      (t (error "unknown message type ~S" type)))))

(defun drop-connection (connection)
  "Close CONNECTION: forget its commands and reject its pending invokes."
  (let ((ids '()))
    (sb-thread:with-mutex (*server-lock*)
      (unless (connection-open-p connection)
        (return-from drop-connection nil))
      (setf (connection-open-p connection) nil)
      (let ((server (connection-server connection)))
        (setf (server-connections server) (remove connection (server-connections server))))
      (loop for name being the hash-keys of *remote-commands* using (hash-value entry)
            when (eq connection (car entry)) collect name into names
            finally (dolist (name names) (remhash name *remote-commands*)))
      (maphash (lambda (id pending)
                 (when (eq connection (pending-connection pending)) (push id ids)))
               *pending*))
    (dolist (id ids)
      (settle id :error "the client running the command disconnected"))
    (ignore-errors (sb-bsd-sockets:socket-shutdown (connection-socket connection) :direction :io))
    (ignore-errors (sb-bsd-sockets:socket-close (connection-socket connection)))
    t))

(defun read-connection (connection)
  "Read and act on CONNECTION's messages until it ends, then drop it."
  (unwind-protect
       (handler-case
           (loop for line = (read-line (connection-stream connection) nil)
                 while line
                 do (handler-case (handle-message connection (read-json line))
                      (serious-condition (c)
                        (format *error-output* "~&;; cl-proteus: bad message from ~A: ~A~%"
                                connection c))))
         (serious-condition () nil))
    (drop-connection connection)))

(defun accept-connection (server socket)
  (let* ((stream (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                           :element-type 'character
                                                           :external-format :utf-8
                                                           :buffering :full))
         (connection (make-instance 'connection
                                    :id (sb-thread:with-mutex (*server-lock*)
                                          (incf *next-connection-id*))
                                    :socket socket :stream stream :server server)))
    (sb-thread:with-mutex (*server-lock*)
      (push connection (server-connections server)))
    (sb-thread:make-thread #'read-connection :arguments (list connection)
                                             :name "cl-proteus connection")
    connection))

;;; Servers

(defun check-socket-path (path)
  ;; sun_path holds 104 bytes on macOS, the terminating zero included.
  (when (> (length (sb-ext:string-to-octets path :external-format :utf-8)) 103)
    (error "The socket path ~S is too long: a Unix-domain socket path holds at most 103 bytes."
           path)))

(defun socket-answers-p (path)
  "True if something accepts connections on the socket PATH."
  (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (unwind-protect
         (handler-case (progn (sb-bsd-sockets:socket-connect socket path) t)
           (error () nil))
      (ignore-errors (sb-bsd-sockets:socket-close socket)))))

(defun serve-shell (path)
  "Listen for clients on the Unix-domain socket PATH and return the
SHELL-SERVER. PATH's directory is made, readable by this user only, if it
does not exist; the socket is readable and writable by this user only. A
socket left at PATH by a shell that is gone is replaced; one that still
answers is an error.

Clients' commands are called by pages' invokes, their events reach pages and
Lisp listeners, and their views are served; see cl-proteus/client."
  (let ((path (uiop:native-namestring (merge-pathnames path))))
    (check-socket-path path)
    (when (nth-value 1 (ensure-directories-exist path))
      (sb-posix:chmod (string-right-trim "/" (uiop:native-namestring
                                              (uiop:pathname-directory-pathname path)))
                      #o700))
    (when (probe-file path)
      (when (socket-answers-p path)
        (error "A shell already listens on ~S." path))
      (delete-file path))
    (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
      (handler-bind ((error (lambda (c) (declare (ignore c))
                              (ignore-errors (sb-bsd-sockets:socket-close socket)))))
        (sb-bsd-sockets:socket-bind socket path)
        (sb-posix:chmod path #o600)
        (sb-bsd-sockets:socket-listen socket 8))
      (let ((server (make-instance 'shell-server :path path :socket socket)))
        (sb-thread:with-mutex (*server-lock*)
          (push server *servers*))
        (setf (server-thread server)
              (sb-thread:make-thread
               (lambda ()
                 (loop
                   (let ((client (handler-case (sb-bsd-sockets:socket-accept socket)
                                   (error () nil))))
                     (cond ((server-stopping server)
                            (when client (ignore-errors (sb-bsd-sockets:socket-close client)))
                            (return))
                           (client (accept-connection server client))))))
               :name "cl-proteus server"))
        server))))

(defun stop-shell (server)
  "Stop SERVER: drop its clients, stop listening and remove its socket."
  (setf (server-stopping server) t)
  ;; A thread blocked in accept() is not woken by closing its socket; a
  ;; connection is what wakes it.
  (socket-answers-p (shell-server-path server))
  (ignore-errors (sb-thread:join-thread (server-thread server) :timeout 5))
  (ignore-errors (sb-bsd-sockets:socket-close (server-socket server)))
  (dolist (connection (shell-clients server))
    (drop-connection connection))
  (sb-thread:with-mutex (*server-lock*)
    (setf *servers* (remove server *servers*)))
  (ignore-errors (delete-file (shell-server-path server)))
  server)
