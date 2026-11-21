;;;; Serving a directory of front-end files through a custom URL scheme.
;;;;
;;;; proteus://app/css/site.css is the file css/site.css under the directory;
;;;; a path ending in / is its index.html. Nothing outside the directory can
;;;; be reached: ".." segments are refused, and a file is served only if its
;;;; real path, symbolic links followed, is still inside.

(in-package #:cl-proteus/shell)

(defparameter *scheme* "proteus"
  "The URL scheme an app's front end is served under, as proteus://app/.")

(defparameter *mime-types*
  '(("html" . "text/html; charset=utf-8")
    ("htm" . "text/html; charset=utf-8")
    ("css" . "text/css; charset=utf-8")
    ("js" . "text/javascript; charset=utf-8")
    ("mjs" . "text/javascript; charset=utf-8")
    ("json" . "application/json")
    ("map" . "application/json")
    ("txt" . "text/plain; charset=utf-8")
    ("svg" . "image/svg+xml")
    ("png" . "image/png")
    ("jpg" . "image/jpeg")
    ("jpeg" . "image/jpeg")
    ("gif" . "image/gif")
    ("webp" . "image/webp")
    ("ico" . "image/x-icon")
    ("woff" . "font/woff")
    ("woff2" . "font/woff2")
    ("ttf" . "font/ttf")
    ("wasm" . "application/wasm")
    ("mp4" . "video/mp4")
    ("webm" . "video/webm")
    ("mp3" . "audio/mpeg")
    ("wav" . "audio/wav"))
  "Content types by file extension; others are served as octet streams.")

(defun mime-type (pathname)
  "The content type to serve PATHNAME with."
  (or (cdr (assoc (pathname-type pathname) *mime-types* :test #'equalp))
      "application/octet-stream"))

(defun percent-decode (string)
  "STRING with its %XX escapes decoded as UTF-8, or NIL if one is malformed."
  (let ((octets (make-array (length string) :element-type '(unsigned-byte 8)
                                            :fill-pointer 0)))
    (loop with i = 0
          while (< i (length string))
          do (let ((char (char string i)))
               (cond ((char= char #\%)
                      (let ((code (and (<= (+ i 3) (length string))
                                       (parse-integer string :start (1+ i) :end (+ i 3)
                                                             :radix 16 :junk-allowed t))))
                        (unless (and code (digit-char-p (char string (+ i 2)) 16))
                          (return-from percent-decode nil))
                        (vector-push code octets)
                        (incf i 3)))
                     (t
                      (loop for octet across (sb-ext:string-to-octets (string char)
                                                                      :external-format :utf-8)
                            do (vector-push-extend octet octets))
                      (incf i)))))
    (handler-case (sb-ext:octets-to-string (coerce octets '(simple-array (unsigned-byte 8) (*)))
                                           :external-format :utf-8)
      (error () nil))))

(defun url-path (url)
  "The path of URL, decoded, without its query or fragment: \"a/b.css\" for
proteus://app/a/b.css. NIL if it cannot be decoded."
  (let* ((start (let ((scheme-end (search "://" url)))
                  (if scheme-end
                      (or (position #\/ url :start (+ scheme-end 3)) (length url))
                      0)))
         (end (or (position-if (lambda (c) (member c '(#\? #\#))) url :start start)
                  (length url))))
    (percent-decode (string-left-trim "/" (subseq url start end)))))

(defun safe-relative-path (path)
  "PATH split at /, or NIL if any segment could leave the directory or is
not a plain name."
  (let ((segments (uiop:split-string path :separator "/")))
    (when (and (notany (lambda (segment)
                         (or (member segment '("." "..") :test #'string=)
                             (find #\\ segment)
                             (find (code-char 0) segment)))
                       segments))
      segments)))

(defun resolve-frontend-file (directory path)
  "The file PATH names under DIRECTORY, or NIL if there is none or it lies
outside. An empty path, or one ending in /, names index.html."
  (let ((segments (safe-relative-path path))
        (root (ignore-errors (truename directory))))
    (when (and root (or segments (string= path "")))
      (let* ((segments (if (or (null segments) (string= "" (car (last segments))))
                           (append (butlast segments) (list "index.html"))
                           segments))
             (directories (butlast segments))
             (file (car (last segments)))
             (candidate (merge-pathnames
                         (make-pathname :directory (cons :relative directories)
                                        :defaults (uiop:parse-native-namestring file))
                         root))
             (real (ignore-errors (truename candidate))))
        (when (and real
                   (not (uiop:directory-pathname-p real))
                   (uiop:subpathp real root))
          real)))))

(defun read-octets (pathname)
  (with-open-file (in pathname :element-type '(unsigned-byte 8))
    (let ((octets (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence octets in)
      octets)))

(defun frontend-handler (directory)
  "A handler for cl-iris's :PROTOCOLS that serves the files under DIRECTORY:
GET and HEAD only, 404 for anything missing or outside it."
  (lambda (request)
    (let ((method (request-method request)))
      (if (not (member method '("GET" "HEAD") :test #'string-equal))
          (values "Method not allowed" "text/plain; charset=utf-8" 405)
          (let* ((path (url-path (request-url request)))
                 (file (and path (resolve-frontend-file directory path))))
            (when file
              (values (read-octets file) (mime-type file) 200
                      '(("Cache-Control" . "no-cache")))))))))
