;;;; Building an application bundle: a test app is bundled, signed, checked
;;;; and run from its bundle, out of sight. CL_PROTEUS_TEST_SKIP_BUNDLE=1
;;;; skips the build, which takes a while.

(in-package #:cl-proteus/test)

(defparameter *bundle-identifier* "org.example.cl-proteus-test")

(defun bundle-unit-checks ()
  (check "bundle executable names are lower case file names"
         (and (equal "notes" (cl-proteus/bundle::executable-name 'notes))
              (equal "my-app" (cl-proteus/bundle::executable-name "pkg::my app"))
              (equal "app" (cl-proteus/bundle::executable-name "::"))))
  (check "bundle Info.plist entries take additions and replacements"
         (let ((entries (cl-proteus/bundle::info-entries
                         :name "Notes" :executable "notes" :identifier "org.example.notes"
                         :version "1.2.0"
                         :info '("CFBundleVersion" "7" "NSCameraUsageDescription" "Scans"))))
           (and (equal "7" (cdr (assoc "CFBundleVersion" entries :test #'string=)))
                (equal "Scans" (cdr (assoc "NSCameraUsageDescription" entries :test #'string=)))
                (= 1 (count "CFBundleVersion" entries :key #'car :test #'string=))
                (equal "1.2.0" (cdr (assoc "CFBundleShortVersionString" entries
                                           :test #'string=))))))
  (check "a bundle property list escapes its text and passes plutil"
         (uiop:with-temporary-file (:pathname file :type "plist")
           (cl-proteus/bundle::write-plist file '(("Name" . "a <b> & c") ("Flag" . t)
                                                  ("List" . ("x" "y")) ("Count" . 3)))
           (and (search "a &lt;b&gt; &amp; c" (uiop:read-file-string file))
                (eql 0 (nth-value 2 (uiop:run-program (list "/usr/bin/plutil" "-lint"
                                                            (namestring file))
                                                      :ignore-error-status t))))))
  (check "bundle-app wants a system or files that define the app"
         (handler-case (progn (cl-proteus/bundle:bundle-app 'notes) nil)
           (error () t))))

(defun program-output (&rest command)
  "What COMMAND printed, and its exit code."
  (multiple-value-bind (output error-output code)
      (uiop:run-program command :output :string :error-output :string :ignore-error-status t)
    (values (concatenate 'string output error-output) code)))

(defun built-bundle-checks (app)
  (let* ((contents (merge-pathnames "Contents/" app))
         (plist (namestring (merge-pathnames "Info.plist" contents)))
         (bundle (string-right-trim "/" (namestring app)))
         (launcher (namestring (merge-pathnames "MacOS/bundle-app" contents)))
         (runtime (namestring (merge-pathnames "MacOS/sbcl" contents))))
    (flet ((plist-value (key)
             (string-trim '(#\Newline)
                          (program-output "/usr/bin/plutil" "-extract" key "raw" plist))))
      (check "bundle-app lays out the bundle"
             (and (equal "Bundle Test.app" (car (last (pathname-directory app))))
                  (every (lambda (file) (probe-file (merge-pathnames file contents)))
                         '("Info.plist" "MacOS/bundle-app" "MacOS/sbcl" "Resources/app.core"
                           "Resources/frontend/index.html"))))
      (check "a bundle's Info.plist is valid and names its executable"
             (and (eql 0 (nth-value 1 (program-output "/usr/bin/plutil" "-lint" plist)))
                  (equal "bundle-app" (plist-value "CFBundleExecutable"))
                  (equal *bundle-identifier* (plist-value "CFBundleIdentifier"))
                  (equal "Bundle Test" (plist-value "CFBundleName"))
                  (equal "APPL" (plist-value "CFBundlePackageType"))))
      (check "a bundle passes codesign --verify --deep --strict"
             (multiple-value-bind (output code)
                 (program-output "/usr/bin/codesign" "--verify" "--deep" "--strict" bundle)
               (or (eql 0 code) (progn (format t "~&;; ~A~%" output) nil))))
      (check "a bundle runs under the hardened runtime, its Lisp with the entitlements"
             (and (search "runtime" (program-output "/usr/bin/codesign" "-dv" bundle))
                  (search "runtime" (program-output "/usr/bin/codesign" "-dv" runtime))
                  (every (lambda (key)
                           (search key (program-output "/usr/bin/codesign" "-d"
                                                       "--entitlements" "-" runtime)))
                         cl-proteus/bundle:*entitlements*)))
      (check "a bundled app runs from its bundle and serves its front end from there"
             ;; SBCL_HOME pointing elsewhere must not change the core it starts.
             (multiple-value-bind (output code)
                 (program-output "/usr/bin/perl" "-e" "alarm shift; exec @ARGV" "120"
                                 "/usr/bin/env" "SBCL_HOME=/nonexistent" launcher)
               (or (and (eql 0 code)
                        (search "BUNDLE-TITLE bundled by SBCL" output)
                        (search (format nil "BUNDLE-IDENTIFIER ~A" *bundle-identifier*) output)
                        (search ".app/Contents/Resources/frontend/" output)
                        (not (search "BUNDLE-ERROR" output)))
                   (progn (format t "~&;; bundled app, exit code ~A, output:~%~A~%"
                                  code (last-lines output 40))
                          nil)))))))

(defparameter *built-bundle-checks*
  '("bundle-app builds the test app"
    "bundle-app lays out the bundle"
    "a bundle's Info.plist is valid and names its executable"
    "a bundle passes codesign --verify --deep --strict"
    "a bundle runs under the hardened runtime, its Lisp with the entitlements"
    "a bundled app runs from its bundle and serves its front end from there"))

(defun bundle-checks ()
  (bundle-unit-checks)
  (when (and (some #'selected-p *built-bundle-checks*)
             (not (sb-ext:posix-getenv "CL_PROTEUS_TEST_SKIP_BUNDLE")))
    (uiop:with-temporary-file (:pathname marker :prefix "cl-proteus-bundle")
      (let ((output (merge-pathnames (format nil "~A.d/" (pathname-name marker))
                                     (uiop:pathname-directory-pathname marker))))
        (unwind-protect
             (let ((app (handler-case
                            (cl-proteus/bundle:bundle-app
                             "cl-proteus.test.bundle-app::bundle-app"
                             :load (asdf:system-relative-pathname
                                    "cl-proteus" "test/bundle-app/app.lisp")
                             :output-directory output
                             :identifier *bundle-identifier*
                             ;; No Dock icon and no focus taken while it runs.
                             :run-options '(:activation-policy :accessory))
                          (error (e)
                            (format t "~&;; bundle-app failed: ~A~%" e)
                            nil))))
               (check "bundle-app builds the test app" app)
               (when app (built-bundle-checks app)))
          (uiop:delete-directory-tree output :validate t :if-does-not-exist :ignore))))))
