;;;; Events: named messages with a payload, heard by any number of listeners.
;;;;
;;;; EMIT delivers an event to every Lisp listener of its name and hands it to
;;;; every emitter in *EVENT-FORWARDERS*; the shell installs one that passes
;;;; it on to the pages, so the same EMIT reaches Lisp and JavaScript alike.

(in-package #:cl-proteus/core)

(defvar *listeners* (make-hash-table :test 'equal)
  "Lisp listeners, by event name: lists of LISTENER objects, oldest first.")

(defvar *listeners-lock* (sb-thread:make-mutex :name "cl-proteus listeners"))

(defvar *next-listener-id* 0)

(defvar *event-forwarders* '()
  "Functions of (NAME PAYLOAD) that EMIT also calls, after the Lisp listeners,
to carry events beyond this image -- the shell adds one that emits to pages.")

(defvar *event-source* nil
  "While a listener runs, what the event came from: a webview for an event a
page emitted, or NIL for one emitted from Lisp.")

(defclass listener ()
  ((id :initarg :id :reader listener-id
       :documentation "A number that tells this listener from every other.")
   (event :initarg :event :reader listener-event
          :documentation "The name of the event it hears.")
   (function :initarg :function :reader listener-function
             :documentation "Called with the payload of each event.")
   (once :initarg :once :initform nil :reader listener-once-p
         :documentation "True if it hears one event and then removes itself."))
  (:documentation "A Lisp function listening for events of one name. LISTEN-EVENT
returns one; UNLISTEN-EVENT takes it."))

(setf (documentation 'listener-id 'function) "The number that tells LISTENER from every other."
      (documentation 'listener-event 'function) "The name of the event LISTENER hears."
      (documentation 'listener-function 'function) "The function LISTENER calls with each payload."
      (documentation 'listener-once-p 'function)
      "True if LISTENER hears one event and then removes itself.")

(defmethod print-object ((listener listener) stream)
  (print-unreadable-object (listener stream :type t)
    (format stream "~S~:[~; once~] #~D"
            (listener-event listener) (listener-once-p listener) (listener-id listener))))

(defun listen-event (event function &key once)
  "Call FUNCTION with the payload of every event named EVENT (a string) --
emitted from Lisp with EMIT or from a page with proteus.emit -- until
UNLISTEN-EVENT, or only for the next one with ONCE. FUNCTION may be a symbol, which
follows its redefinitions. Returns the LISTENER.

While FUNCTION runs, *EVENT-SOURCE* is the webview a page's event came from.
An error in FUNCTION is reported and does not stop the other listeners."
  (check-type event string)
  (sb-thread:with-mutex (*listeners-lock*)
    (let ((listener (make-instance 'listener :id (incf *next-listener-id*)
                                             :event event :function function
                                             :once once)))
      (setf (gethash event *listeners*)
            (append (gethash event *listeners*) (list listener)))
      listener)))

(defun listen-event-once (event function)
  "LISTEN-EVENT to EVENT for its next occurrence only."
  (listen-event event function :once t))

(defun unlisten-event (listener)
  "Stop LISTENER. Returns true if it was still listening."
  (sb-thread:with-mutex (*listeners-lock*)
    (let* ((event (listener-event listener))
           (before (gethash event *listeners*))
           (after (remove listener before)))
      (if after
          (setf (gethash event *listeners*) after)
          (remhash event *listeners*))
      (/= (length before) (length after)))))

(defun listeners (&optional event)
  "The listeners of EVENT, or of every event, oldest first."
  (sb-thread:with-mutex (*listeners-lock*)
    (if event
        (copy-list (gethash event *listeners*))
        (loop for list being the hash-values of *listeners* append list))))

(defun take-listeners (event)
  "The listeners to call for EVENT now, removing those that listen once."
  (sb-thread:with-mutex (*listeners-lock*)
    (let ((all (gethash event *listeners*)))
      (when (some #'listener-once-p all)
        (let ((kept (remove-if #'listener-once-p all)))
          (if kept
              (setf (gethash event *listeners*) kept)
              (remhash event *listeners*))))
      all)))

(defun report (where condition)
  (format *error-output* "~&;; cl-proteus: error in ~A: ~A~%" where condition))

(defun dispatch-event (event payload &key source)
  "Call the Lisp listeners of EVENT with PAYLOAD, with *EVENT-SOURCE* bound to
SOURCE. Returns the number of listeners called."
  (let ((*event-source* source)
        (called 0))
    (dolist (listener (take-listeners event) called)
      (incf called)
      (handler-case (funcall (listener-function listener) payload)
        (serious-condition (c)
          (report (format nil "a listener of ~S" event) c))))))

(defun emit (event &optional payload)
  "Send the event EVENT (a string) with PAYLOAD, a JSON-like value, to every
Lisp listener and every page. Returns EVENT."
  (check-type event string)
  (dispatch-event event payload)
  (dolist (forward *event-forwarders* event)
    (handler-case (funcall forward event payload)
      (serious-condition (c) (report "forwarding an event" c)))))
