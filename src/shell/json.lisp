;;;; JSON text for values sent to pages, written by Foundation.
;;;;
;;;; Values become Foundation objects as cl-iris converts them (strings,
;;;; numbers, T and NIL, :NULL, vectors and hash tables) and
;;;; NSJSONSerialization writes the text, so pages read exactly what an invoke
;;;; would have answered.

(in-package #:cl-proteus/shell)

(defconstant +json-fragments-allowed+ 4
  "NSJSONWritingFragmentsAllowed: a string or number may stand alone.")

(defun to-json (value)
  "The JSON text of VALUE, a JSON-like Lisp value."
  (cl-iris/objc:with-autorelease-pool
      (let* ((object (cl-iris/objc:lisp->objc value))
             (data (cl-iris/objc:send (cl-iris/objc:find-class* "NSJSONSerialization")
                                      "dataWithJSONObject:options:error:"
                                      :pointer object
                                      :unsigned-long +json-fragments-allowed+
                                      :pointer (cffi:null-pointer))))
        (when (cffi:null-pointer-p data)
          (error "~S cannot be written as JSON." value))
        (cl-iris/objc:lisp-string
         (cl-iris/objc:autorelease
          (cl-iris/objc:send (cl-iris/objc:send (cl-iris/objc:find-class* "NSString") "alloc")
                             "initWithData:encoding:"
                             :pointer data :unsigned-long 4))))))
