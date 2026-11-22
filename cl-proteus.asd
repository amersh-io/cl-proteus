;;;; cl-proteus -- a Tauri-style application framework for Common Lisp.

(defsystem "cl-proteus"
  :description "A Tauri-style application framework for Common Lisp, on cl-iris."
  :license "Apache-2.0"
  :version "0.1.0"
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
               (:file "json")
               (:file "commands")
               (:file "events")
               (:file "views")
               (:file "app")))

(defsystem "cl-proteus/shell"
  :description "The windows and the page bridge, on cl-iris."
  :license "Apache-2.0"
  :depends-on ("cl-iris" "cl-proteus/core" "sb-bsd-sockets" "sb-posix")
  :pathname "src/shell/"
  :serial t
  :components ((:file "package")
               (:file "json")
               (:file "frontend")
               (:file "bridge")
               (:file "views")
               (:file "app")
               (:file "server")))

(defsystem "cl-proteus/bundle"
  :description "Building a signed macOS application bundle from an app."
  :license "Apache-2.0"
  :depends-on ("uiop" "sb-posix" "cl-proteus/core")
  :pathname "src/bundle/"
  :serial t
  :components ((:file "package")
               (:static-file "launcher.c")
               (:file "bundle")))

(defsystem "cl-proteus/client"
  :description "Commands, events and views of an image without windows, shown by a shell."
  :license "Apache-2.0"
  :depends-on ("cl-proteus/core" "sb-bsd-sockets")
  :pathname "src/client/"
  :serial t
  :components ((:file "package")
               (:file "client")))

(defsystem "cl-proteus/test"
  :license "Apache-2.0"
  :depends-on ("cl-proteus" "cl-proteus/bundle" "cl-proteus/client" "sb-posix" "sb-bsd-sockets")
  :pathname "test/"
  :serial t
  :components ((:file "package")
               (:file "core")
               (:file "shell")
               (:file "app")
               (:file "examples")
               (:file "bundle")
               (:file "remote")
               (:file "run"))
  :perform (test-op (o c) (symbol-call :cl-proteus/test :run!)))
