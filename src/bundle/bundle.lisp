;;;; Building Name.app from an application defined with DEFINE-APP.
;;;;
;;;;   Name.app/Contents/
;;;;     Info.plist
;;;;     MacOS/name          a small launcher, the bundle's executable
;;;;     MacOS/sbcl          the SBCL runtime this Lisp runs on
;;;;     Resources/app.core  the application's image
;;;;     Resources/frontend/ the app's front-end directory, if it has one
;;;;
;;;; The image is saved by a fresh Lisp that loads the application and never
;;;; runs it, so no window or other Cocoa state is in it. It is kept apart
;;;; from the runtime because a code signature cannot cover a core appended
;;;; to an executable; the launcher starts the runtime with it.

(in-package #:cl-proteus/bundle)

(defparameter *entitlements*
  '("com.apple.security.cs.allow-unsigned-executable-memory")
  "The entitlements the Lisp runtime of a bundle is signed with, each granted.
SBCL writes compiled code into memory it then runs, which the hardened
runtime forbids without the first.")

(defparameter *minimum-system-version* "11.0"
  "The oldest macOS a bundle declares it runs on (LSMinimumSystemVersion).")

(define-condition bundle-error (error)
  ((message :initarg :message :reader bundle-error-message)
   (output :initarg :output :initform nil :reader bundle-error-output))
  (:report (lambda (condition stream)
             (format stream "~A~@[~%~A~]" (bundle-error-message condition)
                     (let ((output (bundle-error-output condition)))
                       (and output (last-lines output 30))))))
  (:documentation "Building a bundle failed; BUNDLE-ERROR-OUTPUT is what the
failing step printed, or NIL."))

(setf (documentation 'bundle-error-output 'function)
      "What the step that failed to build a bundle printed, or NIL.")

;;; Running programs

(defun last-lines (text count)
  "The last COUNT lines of TEXT."
  (let ((lines (uiop:split-string (string-right-trim '(#\Newline) text)
                                  :separator '(#\Newline))))
    (format nil "~{~A~^~%~}" (last lines count))))

(defun run (what program &rest arguments)
  "Run PROGRAM with ARGUMENTS and return what it printed; signal a
BUNDLE-ERROR saying WHAT failed if it exits with an error."
  (multiple-value-bind (output error-output code)
      (uiop:run-program (cons program arguments)
                        :output :string :error-output :string :ignore-error-status t)
    (let ((text (concatenate 'string output error-output)))
      (unless (eql code 0)
        (error 'bundle-error :message (format nil "~A failed (exit code ~A)." what code)
                             :output text))
      text)))

;;; Property lists

(defun xml-escape (string)
  (with-output-to-string (out)
    (loop for char across string
          do (case char
               (#\< (write-string "&lt;" out))
               (#\> (write-string "&gt;" out))
               (#\& (write-string "&amp;" out))
               (t (write-char char out))))))

(defun write-plist-value (value out)
  (etypecase value
    ((eql t) (write-string "<true/>" out))
    (null (write-string "<false/>" out))
    (string (format out "<string>~A</string>" (xml-escape value)))
    (integer (format out "<integer>~D</integer>" value))
    (cons (write-string "<array>" out)
     (dolist (element value) (write-plist-value element out))
     (write-string "</array>" out))))

(defun write-plist (pathname entries)
  "Write ENTRIES, a list of (key . value), to PATHNAME as an XML property list.
A value is a string, an integer, T or NIL (true or false), or a list of values."
  (with-open-file (out pathname :direction :output :if-exists :supersede
                                :external-format :utf-8)
    (format out "<?xml version=\"1.0\" encoding=\"UTF-8\"?>~%~
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" ~
\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">~%~
<plist version=\"1.0\">~%<dict>~%")
    (loop for (key . value) in entries
          do (format out "  <key>~A</key>" (xml-escape key))
             (write-plist-value value out)
             (terpri out))
    (format out "</dict>~%</plist>~%"))
  pathname)

(defun info-entries (&key name executable identifier version icon info)
  "The Info.plist entries of a bundle; INFO, a plist of keys and values,
adds entries or replaces these."
  (let ((entries `(("CFBundleDevelopmentRegion" . "en")
                   ("CFBundleDisplayName" . ,name)
                   ("CFBundleExecutable" . ,executable)
                   ,@(when icon `(("CFBundleIconFile" . ,icon)))
                   ("CFBundleIdentifier" . ,identifier)
                   ("CFBundleInfoDictionaryVersion" . "6.0")
                   ("CFBundleName" . ,name)
                   ("CFBundlePackageType" . "APPL")
                   ("CFBundleShortVersionString" . ,version)
                   ("CFBundleVersion" . ,version)
                   ("LSMinimumSystemVersion" . ,*minimum-system-version*)
                   ("NSHighResolutionCapable" . t)
                   ("NSPrincipalClass" . "NSApplication"))))
    (loop for (key value) on info by #'cddr
          do (setf entries (append (remove key entries :key #'car :test #'string=)
                                   (list (cons key value)))))
    entries))

;;; What the building Lisp loads

(defun dependency-name (spec)
  "The system name in the dependency SPEC of a DEFSYSTEM, or NIL."
  (cond ((or (stringp spec) (symbolp spec)) (asdf:coerce-name spec))
        ((and (consp spec) (eq (first spec) :version)) (dependency-name (second spec)))
        ((and (consp spec) (eq (first spec) :feature)) (dependency-name (third spec)))
        (t nil)))

(defun asd-files (names)
  "The .asd files of the systems NAMES and of all they depend on, as this
Lisp finds them, each after those of its dependencies."
  (let ((seen (make-hash-table :test 'equal))
        (files '()))
    (labels ((walk (name)
               (unless (or (null name) (gethash name seen))
                 (setf (gethash name seen) t)
                 (let ((system (asdf:find-system name nil)))
                   (when system
                     (dolist (spec (append (asdf:system-defsystem-depends-on system)
                                           (asdf:system-depends-on system)))
                       (walk (dependency-name spec)))
                     (let ((file (asdf:system-source-file system)))
                       (when file (pushnew (namestring file) files :test #'string=))))))))
      (mapc #'walk names))
    (nreverse files)))

(defun setup-files ()
  "The Quicklisp or qlot setup file this Lisp was started with, in a list."
  (let* ((package (find-package "QL-SETUP"))
         (home (and package (find-symbol "*QUICKLISP-HOME*" package)))
         (file (and home (boundp home)
                    (probe-file (merge-pathnames "setup.lisp" (symbol-value home))))))
    (and file (list (namestring file)))))

(defparameter *build-script* "~
;;;; Written by cl-proteus/bundle: save the image of one application.
(require :asdf)
(push :cl-proteus-bundle *features*)
~{(load ~S)~%~}~
~{(asdf:load-asd ~S)~%~}~
(asdf:load-system \"cl-proteus\")
~{(asdf:load-system ~S)~%~}~
~{(load ~S)~%~}~
(defpackage #:cl-proteus.bundled (:use #:cl))
(in-package #:cl-proteus.bundled)

(defparameter *app* (cl-proteus:find-app '~A))

(with-open-file (out ~S :direction :output :if-exists :supersede)
  (with-standard-io-syntax
    (prin1 (list :title (cl-proteus:app-title *app*)
                 :frontend (let ((dir (cl-proteus:app-frontend *app*)))
                             (and dir (namestring dir))))
           out)))

(defun main ()
  \"Run the application from its bundle, and exit when it quits.\"
  (sb-ext:disable-debugger)
  (handler-case
      (let ((resources (truename (merge-pathnames \"../Resources/\"
                                                  (make-pathname :name nil :type nil :version nil
                                                                 :defaults sb-ext:*runtime-pathname*)))))
        (when (cl-proteus:app-frontend *app*)
          (setf (cl-proteus:app-frontend *app*) (merge-pathnames \"frontend/\" resources)))
        (cl-proteus:run-app *app*~{ ~S~})
        (finish-output)
        (sb-ext:exit :code 0))
    (serious-condition (condition)
      (format *error-output* \"~~&~~A~~%\" condition)
      (finish-output *error-output*)
      (sb-ext:exit :code 1 :abort t))))

(setf *features* (remove :cl-proteus-bundle *features*))
(sb-ext:save-lisp-and-die ~S :toplevel #'main)
")

(defun save-image (app-name core manifest &key system load run-options)
  "Save the image of the application APP-NAME to CORE from a fresh Lisp that
loads SYSTEM and the files LOAD, and write what it learns of the app to
MANIFEST."
  (uiop:with-temporary-file (:pathname script :type "lisp" :prefix "cl-proteus-build")
    (with-open-file (out script :direction :output :if-exists :supersede)
      (with-standard-io-syntax
        (let ((*package* (find-package :keyword))
              (*print-readably* nil))
          (format out *build-script*
                  (setup-files)
                  (asd-files (remove nil (list "cl-proteus" system)))
                  (and system (list system))
                  (mapcar (lambda (file) (namestring (truename file))) load)
                  (if (stringp app-name) app-name (prin1-to-string app-name))
                  (namestring manifest)
                  run-options
                  (namestring core)))))
    (run "Saving the application image"
         (namestring sb-ext:*runtime-pathname*)
         "--noinform" "--non-interactive" "--no-sysinit" "--no-userinit"
         "--load" (namestring script))))

;;; Copying and signing

(defun copy-executable (from to)
  (uiop:copy-file from to)
  (sb-posix:chmod (namestring to) #o755))

(defun compile-launcher (to)
  (run "Compiling the launcher (a C compiler is needed: xcode-select --install)"
       "cc" "-O2" (format nil "-mmacosx-version-min=~A" *minimum-system-version*)
       "-o" (namestring to)
       (namestring (asdf:system-relative-pathname "cl-proteus/bundle" "src/bundle/launcher.c"))))

(defun copy-directory (from to)
  (ensure-directories-exist to)
  (run "Copying the front end" "/bin/cp" "-R"
       (concatenate 'string (string-right-trim "/" (namestring from)) "/.")
       (namestring to)))

(defun entitlements-file (entitlements directory)
  "A property list file of ENTITLEMENTS, a list of granted keys or a file."
  (if (listp entitlements)
      (write-plist (merge-pathnames "entitlements.plist" directory)
                   (mapcar (lambda (key) (cons key t)) entitlements))
      (truename entitlements)))

(defun sign (path identity &rest options)
  (apply #'run (format nil "Signing ~A" (file-namestring (string-right-trim "/" (namestring path))))
         "/usr/bin/codesign" "--force" "--sign" identity "--options" "runtime"
         (append (unless (string= identity "-") (list "--timestamp"))
                 options
                 (list (string-right-trim "/" (namestring path))))))

;;; The bundle

(defun executable-name (name)
  "A file name for the application NAME, a symbol or the text of one: lower
case letters, digits and -."
  (let* ((name (if (symbolp name)
                   (symbol-name name)
                   (subseq name (1+ (or (position #\: name :from-end t) -1)))))
         (text (substitute-if #\- (lambda (char) (not (or (alphanumericp char) (char= char #\-))))
                              (string-downcase name))))
    (if (plusp (length (string-trim "-" text))) text "app")))

(defun bundle-app (app &key system load (output-directory (uiop:getcwd)) name identifier
                         (version "0.1.0") icon info (entitlements *entitlements*)
                         (identity "-") run-options)
  "Build NAME.app in OUTPUT-DIRECTORY from APP, an application or the name
of one defined with DEFINE-APP, and return its pathname. The name may be a
string, read once the application is loaded, such as \"my-app::notes\", for
an app whose package this Lisp does not have.

A fresh Lisp loads SYSTEM, a system name, and the files LOAD, with the
feature :CL-PROTEUS-BUNDLE present (code that runs an app when loaded can
test it), and saves an image that runs APP with RUN-OPTIONS for RUN-APP and
exits when it quits. Systems this Lisp knows are found there too.

NAME, the name people see, defaults to the app's title. IDENTIFIER is the
reverse-DNS bundle identifier; give your own. VERSION is the bundle's
version; ICON, an .icns file; INFO, a plist of further Info.plist entries,
such as (\"NSCameraUsageDescription\" \"...\").

The app's front-end directory is copied into the bundle, and the app serves
it from there when run from the bundle.

The bundle is signed with IDENTITY, a codesign identity, \"-\" (the default)
for an ad-hoc signature, under the hardened runtime; the Lisp runtime gets
ENTITLEMENTS, a list of entitlement keys or a property list file. An
existing NAME.app is replaced."
  (let* ((app-name (if (typep app 'app) (app-name app) app))
         (executable (executable-name app-name))
         (output (uiop:ensure-directory-pathname (merge-pathnames output-directory)))
         (staging (merge-pathnames (format nil ".~A-building.app/" executable) output))
         (contents (merge-pathnames "Contents/" staging))
         (macos (merge-pathnames "MacOS/" contents))
         (resources (merge-pathnames "Resources/" contents)))
    (unless (or system load)
      (error "BUNDLE-APP needs a :SYSTEM or files to :LOAD that define ~S." app-name))
    (uiop:delete-directory-tree staging :validate t :if-does-not-exist :ignore)
    (ensure-directories-exist macos)
    (ensure-directories-exist resources)
    (uiop:with-temporary-file (:pathname manifest-file :prefix "cl-proteus-manifest")
      (save-image app-name (merge-pathnames "app.core" resources) manifest-file
                  :system system :load (uiop:ensure-list load) :run-options run-options)
      (destructuring-bind (&key title frontend)
          (with-open-file (in manifest-file) (with-standard-io-syntax (read in)))
        (let* ((name (or name (and (plusp (length title)) title) (string-capitalize executable)))
               (final (merge-pathnames (format nil "~A.app/" name) output))
               (icon-file (and icon (format nil "~A.icns" executable))))
          (copy-executable sb-ext:*runtime-pathname* (merge-pathnames "sbcl" macos))
          (compile-launcher (merge-pathnames executable macos))
          (when frontend
            (copy-directory frontend (merge-pathnames "frontend/" resources)))
          (when icon
            (uiop:copy-file icon (merge-pathnames icon-file resources)))
          (write-plist (merge-pathnames "Info.plist" contents)
                       (info-entries :name name :executable executable
                                     :identifier (or identifier
                                                     (format nil "local.cl-proteus.~A" executable))
                                     :version version :icon icon-file :info info))
          (run "Clearing extended attributes" "/usr/bin/xattr" "-cr" (namestring staging))
          (uiop:with-temporary-file (:pathname marker :prefix "cl-proteus-entitlements")
            (let ((directory (merge-pathnames (format nil "~A.d/" (file-namestring marker))
                                              (uiop:pathname-directory-pathname marker))))
              (ensure-directories-exist directory)
              (unwind-protect
                   (sign (merge-pathnames "sbcl" macos) identity
                         "--entitlements"
                         (namestring (entitlements-file entitlements directory)))
                (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))
          (sign staging identity)
          (run "Verifying the signature" "/usr/bin/codesign" "--verify" "--deep" "--strict"
               (string-right-trim "/" (namestring staging)))
          (uiop:delete-directory-tree final :validate t :if-does-not-exist :ignore)
          (sb-posix:rename (string-right-trim "/" (namestring staging))
                           (string-right-trim "/" (namestring final)))
          final)))))

;;; From a shell

(defun command-line (arguments)
  "Bundle as scripts/bundle asks: ARGUMENTS are the app's name, a .lisp file
to load or a system name, and then options as keyword and value, such as
:identifier org.example.notes."
  (destructuring-bind (app source &rest options) arguments
    (let ((options (loop for (key value) on options by #'cddr
                         collect (intern (string-upcase (string-left-trim ":" key)) :keyword)
                         collect value)))
      (format t "~&~A~%"
              (uiop:native-namestring
               (apply #'bundle-app app
                      (append (if (equalp "lisp" (pathname-type source))
                                  (list :load source)
                                  (list :system source))
                              options)))))))
