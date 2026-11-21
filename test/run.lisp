(in-package #:cl-proteus/test)

(defun run! ()
  "Run every test; signal an error if any of them fails."
  (setf *failures* '() *passed* 0)
  (core-checks)
  (event-checks)
  (app-checks)
  (frontend-checks)
  (documentation-checks)
  (let ((defaults cl-iris:*window-defaults*))
    ;; Test windows are transparent, so a run does not flash on the screen.
    (unless (sb-ext:posix-getenv "CL_PROTEUS_TEST_VISIBLE")
      (setf cl-iris:*window-defaults* (list* :alpha 0 defaults)))
    (unwind-protect
         (with-application (:activation-policy :accessory)
           (shell-checks)
           (command-thread-checks)
           (page-event-checks))
      (setf cl-iris:*window-defaults* defaults))
    (unless (sb-ext:posix-getenv "CL_PROTEUS_TEST_VISIBLE")
      (setf cl-iris:*window-defaults* (list* :alpha 0 defaults)))
    (uiop:with-temporary-file (:pathname marker :prefix "cl-proteus-app")
      (let ((frontend (merge-pathnames (format nil "~A/" (pathname-name marker))
                                       (uiop:pathname-directory-pathname marker))))
        (write-file (merge-pathnames "index.html" frontend) "<title>front</title>")
        (unwind-protect (app-run-checks frontend)
          (setf cl-iris:*window-defaults* defaults)
          (uiop:delete-directory-tree frontend :validate t :if-does-not-exist :ignore)))))
  (format t "~&~D passed, ~D failed~%" *passed* (length *failures*))
  (when *failures*
    (error "~D cl-proteus test~:P failed: ~{~A~^, ~}"
           (length *failures*) (reverse *failures*)))
  t)
