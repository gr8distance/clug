;;; Run with:
;;;   (ql:quickload :clug)
;;;   (load "examples/hello.lisp")
;;;   (clack:clackup clug-example:*app* :port 5000)

(defpackage #:clug-example
  (:use #:cl #:clug)
  (:export #:*app*))
(in-package #:clug-example)

;;; --- plugs (middleware) ---

(defun json-headers (conn)
  (put-header conn "Content-Type" "application/json"))

(defun authenticate (conn)
  (let* ((headers (getf (conn-req conn) :headers))
         (token (and headers (gethash "authorization" headers))))
    (if (and token (search "Bearer " token))
        (assign conn :user-id "u-123")
        (halt (put-resp conn 401 "{\"error\":\"unauthorized\"}"
                        (list "Content-Type" "application/json"))))))

(defun require-admin (conn)
  (if (equal (get-assign conn :user-id) "u-admin")
      conn
      (halt (put-resp conn 403 "{\"error\":\"forbidden\"}"))))

;;; --- handlers (also plugs) ---

(defun hello (conn)
  (put-resp conn 200 "hello, clug" (list "Content-Type" "text/plain")))

(defun users-index (conn)
  (put-resp conn 200 "[{\"id\":1},{\"id\":2}]"))

(defun users-show (conn)
  (let ((id (getf (conn-params conn) :id)))
    (put-resp conn 200 (format nil "{\"id\":\"~a\"}" id))))

(defun admin-stats (conn)
  (put-resp conn 200 "{\"requests\":42}"))

;;; --- routes ---

(defroutes *routes*
  (route :get "/" 'hello)
  (scope "/api" :pipe-through '(json-headers authenticate)
    (route :get "/users"      'users-index)
    (route :get "/users/:id"  'users-show)
    (scope "/admin" :pipe-through '(require-admin)
      (route :get "/stats" 'admin-stats))))

(defparameter *app* (to-clack-app *routes*))
