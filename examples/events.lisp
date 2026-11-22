;;;; events.lisp -- events both ways, and state the commands share.
;;;;
;;;;   qlot exec sbcl --load examples/events.lisp
;;;;
;;;; Lisp emits the time every second; the page shows it. Clicking emits
;;;; "clicked" to Lisp, which counts the clicks in the app's state and emits
;;;; the new count back to every page.

(asdf:load-asd (merge-pathnames "../cl-proteus.asd" (or *load-truename* *default-pathname-defaults*)))
(asdf:load-system "cl-proteus")

(defpackage #:cl-proteus.examples.events
  (:use #:cl #:cl-proteus)
  (:export #:main))

(in-package #:cl-proteus.examples.events)

(define-app events
  (:title "Events")
  (:state :clicks 0)
  (:window main :title "Events" :width 420 :height 220 :center t
           :html "<!doctype html>
<title>Events</title>
<style>body { font: 15px -apple-system, sans-serif; margin: 2em; }</style>
<p>Lisp's clock: <b id=clock>...</b></p>
<p><button id=click>Click</button> clicks: <b id=clicks>0</b></p>
<script>
  proteus.listen('clock', time => document.getElementById('clock').textContent = time);
  proteus.listen('clicks', n => document.getElementById('clicks').textContent = n);
  document.getElementById('click').onclick = () => proteus.emit('clicked');
</script>"))

(defun clock ()
  (multiple-value-bind (s m h) (get-decoded-time)
    (format nil "~2,'0D:~2,'0D:~2,'0D" h m s)))

(defun count-click (payload)
  "Count a click in the app's state and tell every page."
  (declare (ignore payload))
  (emit "clicks" (update-app-state :clicks #'1+ (find-app 'events))))

(defun main (&rest options)
  "Run the app until its window is closed. OPTIONS go to RUN-APP."
  (let ((listener (listen-event "clicked" 'count-click))
        (timer nil))
    (unwind-protect
         (apply #'run-app 'events
                ;; Timers run in the application loop, so start it there.
                :on-launch (lambda ()
                             (setf timer (cl-iris:run-every 1 (lambda () (emit "clock" (clock))))))
                options)
      (when timer (cl-iris:cancel-timer timer))
      (unlisten-event listener))))

#-(or cl-proteus-example-test cl-proteus-bundle) (main)
