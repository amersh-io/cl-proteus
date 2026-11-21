(in-package #:cl-proteus/test)

(defun run! ()
  "Run every test; signal an error if any of them fails."
  (setf *failures* '() *passed* 0)
  (core-checks)
  (event-checks)
  (let ((defaults cl-iris:*window-defaults*))
    ;; Test windows are transparent, so a run does not flash on the screen.
    (unless (sb-ext:posix-getenv "CL_PROTEUS_TEST_VISIBLE")
      (setf cl-iris:*window-defaults* (list* :alpha 0 defaults)))
    (unwind-protect
         (with-application (:activation-policy :accessory)
           (shell-checks))
      (setf cl-iris:*window-defaults* defaults)))
  (format t "~&~D passed, ~D failed~%" *passed* (length *failures*))
  (when *failures*
    (error "~D cl-proteus test~:P failed: ~{~A~^, ~}"
           (length *failures*) (reverse *failures*)))
  t)
