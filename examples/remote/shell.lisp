;;;; shell.lisp -- the shell half of the remote example: the window.
;;;;
;;;;   qlot exec sbcl --load examples/remote/shell.lisp
;;;;   qlot exec sbcl --load examples/remote/agent.lisp     ; in another terminal
;;;;
;;;; The shell listens on a socket and shows the view HOME. Until an agent
;;;; connects, HOME is its own "waiting" page; the agent defines HOME again,
;;;; with a command behind it, and the page changes in place. Stop the agent,
;;;; change its view or command, start it again: the window stays open.

(asdf:load-asd (merge-pathnames "../../cl-proteus.asd" (or *load-truename* *default-pathname-defaults*)))
(asdf:load-system "cl-proteus")

(defpackage #:cl-proteus.examples.remote-shell
  (:use #:cl #:cl-proteus)
  (:export #:main #:*socket*))

(in-package #:cl-proteus.examples.remote-shell)

(defparameter *socket* "/tmp/cl-proteus-remote-example.sock"
  "The socket the shell listens on and the agent connects to.")

(define-view home
  :files ("index.html" "<!doctype html>
<title>Waiting for an agent</title>
<style>body { font: 15px -apple-system, sans-serif; margin: 2em; color: #666; }</style>
<p>Waiting for an agent on the socket&hellip;</p>"))

(define-app remote-shell
  (:title "Remote")
  (:window main :title "cl-proteus shell" :width 520 :height 300 :center t :view "home"))

(defun main (&rest options &key (path *socket*) &allow-other-keys)
  "Listen on PATH and run the app until its window is closed. The other
OPTIONS go to RUN-APP."
  (let ((server (serve-shell path)))
    (unwind-protect
         (apply #'run-app 'remote-shell (loop for (key value) on options by #'cddr
                                              unless (eq key :path) append (list key value)))
      (stop-shell server))))

#-(or cl-proteus-example-test cl-proteus-bundle) (main)
