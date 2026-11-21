;;;; cl-proteus -- a Tauri-style application framework for Common Lisp.

(defsystem "cl-proteus"
  :description "A Tauri-style application framework for Common Lisp, on cl-iris."
  :license "Apache-2.0"
  :version "0.0.1"
  :homepage "https://github.com/amersh-io/cl-proteus"
  :depends-on ("cl-proteus/core" "cl-proteus/shell")
  :pathname "src/"
  :components ((:file "cl-proteus"))
  :in-order-to ((test-op (test-op "cl-proteus/test"))))

(defsystem "cl-proteus/core"
  :description "Commands and the other parts of an application that need no window."
  :license "Apache-2.0"
  :depends-on ("uiop")
  :pathname "src/core/"
  :serial t
  :components ((:file "package")
               (:file "commands")
               (:file "events")
               (:file "app")))

(defsystem "cl-proteus/shell"
  :description "The windows and the page bridge, on cl-iris."
  :license "Apache-2.0"
  :depends-on ("cl-iris" "cl-proteus/core")
  :pathname "src/shell/"
  :serial t
  :components ((:file "package")
               (:file "json")
               (:file "bridge")))

(defsystem "cl-proteus/test"
  :license "Apache-2.0"
  :depends-on ("cl-proteus")
  :pathname "test/"
  :serial t
  :components ((:file "package")
               (:file "core")
               (:file "shell")
               (:file "run"))
  :perform (test-op (o c) (symbol-call :cl-proteus/test :run!)))
