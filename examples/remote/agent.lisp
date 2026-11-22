;;;; agent.lisp -- the agent half of the remote example: no window at all.
;;;;
;;;;   qlot exec sbcl --load examples/remote/agent.lisp
;;;;
;;;; This image loads cl-proteus/client, not cl-iris: it holds no Cocoa
;;;; state, so it could fork or save itself while the shell keeps the window.
;;;; It connects to the shell started by shell.lisp, gives it the command
;;;; ROLL, and defines the view HOME, which the shell shows at once. Evaluate
;;;; the DEFINE-VIEW form again with other text and watch the window.

(asdf:load-asd (merge-pathnames "../../cl-proteus.asd" (or *load-truename* *default-pathname-defaults*)))
(asdf:load-system "cl-proteus/client")

(defpackage #:cl-proteus.examples.remote-agent
  (:use #:cl #:cl-proteus/core #:cl-proteus/client)
  (:export #:main))

(in-package #:cl-proteus.examples.remote-agent)

(define-command roll (sides)
  "A roll of a die with SIDES sides, made in the agent's image."
  (1+ (random sides)))

(define-view home
  :files ("index.html" "<!doctype html>
<title>Agent connected</title>
<link rel=stylesheet href=style.css>
<p>This page came from the agent's image.</p>
<p><button id=roll>Roll a die</button> <span id=result></span></p>
<script src=app.js></script>"
          "style.css" "body { font: 15px -apple-system, sans-serif; margin: 2em; }"
          "app.js" "document.getElementById('roll').onclick = async () => {
  document.getElementById('result').textContent =
    await proteus.invoke('roll', {sides: 6});
};"))

(defun main (&key (path "/tmp/cl-proteus-remote-example.sock"))
  "Connect to the shell on PATH and return; the REPL stays yours."
  (connect-shell path :name "remote example agent")
  (format t "~&Connected to ~A. Redefine HOME or ROLL here; the window follows.~%" path))

#-(or cl-proteus-example-test cl-proteus-bundle) (main)
