;;;; Views: named sets of front-end files held in the image.
;;;;
;;;; A view is a small front end -- index.html and whatever it loads -- kept
;;;; as octets in Lisp rather than in a directory. The shell serves it at
;;;; proteus://view/NAME/ and reloads every page showing it when it is
;;;; defined again with other files; a client sends its views to the shell,
;;;; so an image with no window can still change the screens a shell shows.

(in-package #:cl-proteus/core)

(defvar *views* (make-hash-table :test 'equal)
  "Views by name.")

(defvar *views-lock* (sb-thread:make-mutex :name "cl-proteus views"))

(defvar *views-changed-hook* '()
  "Functions of one argument, a VIEW, called after it is defined, or defined
again with other files. The shell reloads the pages showing it; a client
sends it on.")

(defstruct (view (:constructor make-view (name files)))
  "A view: its NAME, a string, and its FILES, an alist from relative paths
such as \"index.html\" or \"css/site.css\" to octet vectors."
  (name "" :type string)
  (files '() :type list))

(setf (documentation 'view-name 'function) "The name a VIEW is served under."
      (documentation 'view-files 'function)
      "A VIEW's files: an alist from relative paths to octet vectors.")

(defmethod print-object ((view view) stream)
  (print-unreadable-object (view stream :type t)
    (format stream "~S ~D file~:P" (view-name view) (length (view-files view)))))

(defun view-file (view path)
  "The octets of the file PATH in VIEW, or NIL. An empty PATH, or one ending
in /, names its index.html."
  (let ((path (if (or (string= path "") (char= (char path (1- (length path))) #\/))
                  (concatenate 'string path "index.html")
                  path)))
    (cdr (assoc path (view-files view) :test #'string=))))

(defun file-octets (content)
  (etypecase content
    (string (sb-ext:string-to-octets content :external-format :utf-8))
    ((vector (unsigned-byte 8)) (coerce content '(simple-array (unsigned-byte 8) (*))))
    (pathname (read-file-octets content))))

(defun read-file-octets (pathname)
  (with-open-file (in pathname :element-type '(unsigned-byte 8))
    (let ((octets (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence octets in)
      octets)))

(defun directory-files (directory)
  "The files under DIRECTORY, as an alist from relative paths to octets."
  (let ((root (truename (uiop:ensure-directory-pathname directory)))
        (files '()))
    (uiop:collect-sub*directories
     root (constantly t) (constantly t)
     (lambda (subdirectory)
       (dolist (file (uiop:directory-files subdirectory))
         (push (cons (uiop:native-namestring (uiop:enough-pathname file root))
                     (read-file-octets file))
               files))))
    (sort files #'string< :key #'car)))

(defun view-name-string (name)
  (if (symbolp name) (string-downcase (symbol-name name)) name))

(defun ensure-view (name &key files directory)
  "Define the view NAME (a string, or a symbol for its lower-case name), or
replace its files: FILES is a plist or alist of relative paths and contents
(strings, written as UTF-8, octet vectors or pathnames), DIRECTORY a
directory whose files are read now. FILES are added after DIRECTORY's and
win over them. Calls *VIEWS-CHANGED-HOOK* if the files changed; the same
files again leave the view as it is. Returns the view."
  (let* ((name (view-name-string name))
         (pairs (if (and files (consp (first files)))
                    files
                    (loop for (path content) on files by #'cddr collect (cons path content))))
         (entries (append (when directory (directory-files directory))
                          (loop for (path . content) in pairs
                                collect (cons (string-left-trim "/" path) (file-octets content)))))
         (view (make-view name (remove-duplicates entries :key #'car :test #'string=
                                                          :from-end nil))))
    (check-type name string)
    (when (find #\/ name)
      (error "A view name cannot hold a /: ~S." name))
    (sb-thread:with-mutex (*views-lock*)
      (let ((old (gethash name *views*)))
        ;; The same files again change nothing: pages showing the view keep
        ;; their state, as when a client connects again with the same views.
        (when (and old (equalp (view-files old) (view-files view)))
          (return-from ensure-view old)))
      (setf (gethash name *views*) view))
    (dolist (function *views-changed-hook*)
      (handler-case (funcall function view)
        (serious-condition (c)
          (format *error-output* "~&;; cl-proteus: error in a views hook: ~A~%" c))))
    view))

(defmacro define-view (name &body options)
  "Define the view NAME, served by a shell at proteus://view/NAME/:

  (define-view notes
    :files (\"index.html\" \"<!doctype html><title>Notes</title>...\"
            \"app.js\" \"proteus.invoke('list-notes')...\"))

  (define-view settings :directory #p\"ui/settings/\")

OPTIONS are ENSURE-VIEW's, evaluated, except that a :FILES list written out
as paths and contents is taken as a list of them: its contents are
evaluated. Evaluating the form again replaces the files, and every page
showing the view reloads if they changed."
  `(ensure-view ',name
                ,@(loop for (key value) on options by #'cddr
                        collect key
                        collect (if (and (eq key :files) (consp value) (stringp (first value)))
                                    `(list ,@value)
                                    value))))

(defun find-view (name)
  "The view NAME (a string or symbol), or NIL."
  (sb-thread:with-mutex (*views-lock*)
    (values (gethash (view-name-string name) *views*))))

(defun list-views ()
  "The names of every view, sorted."
  (sort (sb-thread:with-mutex (*views-lock*)
          (loop for name being the hash-keys of *views* collect name))
        #'string<))

;;; Base64, to carry a view's octets in JSON.

(defparameter +base64-alphabet+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun base64-encode (octets)
  "OCTETS as a base64 string."
  (with-output-to-string (out)
    (loop for i from 0 below (length octets) by 3
          for count = (min 3 (- (length octets) i))
          for group = (loop for j below 3
                            sum (ash (if (< j count) (aref octets (+ i j)) 0) (* 8 (- 2 j))))
          do (loop for k below 4
                   do (write-char (if (<= k count)
                                      (char +base64-alphabet+ (ldb (byte 6 (* 6 (- 3 k))) group))
                                      #\=)
                                  out)))))

(defun base64-decode (string)
  "The octets of the base64 STRING."
  (let ((octets (make-array (* 3 (ceiling (length string) 4))
                            :element-type '(unsigned-byte 8) :fill-pointer 0))
        (group 0)
        (bits 0))
    (loop for char across string
          for value = (position char +base64-alphabet+)
          do (cond (value
                    (setf group (logior (ash group 6) value))
                    (incf bits 6)
                    (when (>= bits 8)
                      (decf bits 8)
                      (vector-push (ldb (byte 8 bits) group) octets)
                      (setf group (ldb (byte bits 0) group))))
                   ((char= char #\=) (loop-finish))
                   ((member char '(#\Newline #\Return #\Space)))
                   (t (error "Not base64: ~S." char))))
    (coerce octets '(simple-array (unsigned-byte 8) (*)))))
