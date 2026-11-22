;;;; hello.lisp -- an application with one command.
;;;;
;;;;   qlot exec sbcl --load examples/hello.lisp
;;;;
;;;; The page calls the Lisp command greet with proteus.invoke. Redefine
;;;; GREET at the REPL while the window is open and click again.

(asdf:load-asd (merge-pathnames "../cl-proteus.asd" (or *load-truename* *default-pathname-defaults*)))
(asdf:load-system "cl-proteus")

(defpackage #:cl-proteus.examples.hello
  (:use #:cl #:cl-proteus)
  (:export #:main))

(in-package #:cl-proteus.examples.hello)

(define-command greet (user-name)
  "Greet USER-NAME."
  (format nil "Hello, ~A! (from Lisp, ~A)" user-name (lisp-implementation-type)))

(define-app hello
  (:title "Hello")
  (:window main :title "Hello from cl-proteus" :width 480 :height 240 :center t
           :html "<!doctype html>
<title>Hello from cl-proteus</title>
<style>body { font: 15px -apple-system, sans-serif; margin: 2em; }</style>
<p><input id=name value=Ada> <button id=go>Greet</button></p>
<p id=answer></p>
<script>
  document.getElementById('go').onclick = async () => {
    const userName = document.getElementById('name').value;
    document.getElementById('answer').textContent =
      await proteus.invoke('greet', {userName});
  };
</script>"))

(defun main (&rest options)
  "Run the app until its window is closed. OPTIONS go to RUN-APP."
  (apply #'run-app 'hello options))

#-(or cl-proteus-example-test cl-proteus-bundle) (main)
