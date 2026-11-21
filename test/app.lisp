;;;; Tests for running an application: RUN-APP on the main thread, checks on
;;;; a worker, windows transparent as everywhere in the tests.

(in-package #:cl-proteus/test)

(define-command test-count-up ()
  (update-app-state :count #'1+))

(defun live-app (frontend &rest windows)
  "Define, or redefine, the app the run checks use."
  (ensure-app 'test-live-app :title "Live" :frontend frontend
                             :state '(:count 0) :windows windows))

(defun live-app-checks (app frontend record)
  "The checks made while APP runs; each result goes to RECORD as (name value)."
  (let ((main (app-webview 'main app)))
    (funcall record "run-app opens the app's windows"
             (and (app-running-p app)
                  (equal "Live" (window-title (app-window 'main app)))))
    (funcall record "a page is served from the app's front end"
             (wait-until (lambda () (equal "front" (eval-js main "document.title")))))
    (funcall record "a command of the app shares its state"
             (equal "ok:1" (page-value main "window.result = proteus.invoke('test-count-up')"))))
  (live-app frontend
            '(main :title "Live again" :width 360 :height 260 :html "<title>replaced</title>")
            '(side :title "Side" :width 200 :height 150 :html "<title>side</title>"))
  (funcall record "redefining the app retitles and resizes an open window"
           (wait-until (lambda ()
                         (let ((window (app-window 'main app)))
                           (and (equal "Live again" (window-title window))
                                (equal '(360d0 260d0) (window-size window)))))))
  (funcall record "redefining the app loads a changed page"
           (wait-until (lambda ()
                         (equal "replaced" (eval-js (app-webview 'main app) "document.title")))))
  (funcall record "redefining the app opens a new window"
           (and (app-window 'side app)
                (wait-until (lambda ()
                              (equal "side" (eval-js (app-webview 'side app) "document.title"))))))
  (live-app frontend
            '(main :title "Live again" :width 360 :height 260 :html "<title>replaced</title>"))
  (funcall record "redefining the app closes a removed window"
           (null (app-window 'side app))))

(defun app-run-checks (frontend)
  "Run an app whose front end is FRONTEND and check it while it runs."
  (let ((app (live-app frontend
                       '(main :title "Live" :width 320 :height 240 :page "index.html")))
        (results '()))
    (run-app app
             :activation-policy :accessory
             ;; cl-iris 0.1.0 quits a loop started with this option at once
             ;; when an earlier loop in the process closed a window with a
             ;; webview, before ON-LAUNCH runs; the earlier tests did.
             :quit-on-last-window-closed nil
             :on-launch
             (lambda ()
               (sb-thread:make-thread
                (lambda ()
                  (unwind-protect
                       (handler-case
                           (live-app-checks app frontend
                                            (lambda (name value) (push (list name value) results)))
                         (error (e)
                           (push (list (format nil "the app checks ran without error: ~A" e) nil)
                                 results)))
                    (stop-app)))
                :name "cl-proteus app checks")))
    (check "the app checks all ran while the app ran"
           (= 7 (length results)))
    (dolist (result (reverse results))
      (check (first result) (second result)))
    (check "run-app returns when the app stops, and the app is no longer running"
           (not (app-running-p app)))
    (check "the state outlives the run"
           (eql 1 (app-state :count app)))))
