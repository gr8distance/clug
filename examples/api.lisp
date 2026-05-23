;;; A Plug-style REST API demonstrating clug + opt-in sub-systems.
;;;
;;; Load with:
;;;   (ql:quickload '(:clug :clug/parsers :clug/errors :clug/session
;;;                   :clack-handler-hunchentoot :lack))
;;;   (load "examples/api.lisp")
;;;   (clug-api:start)         ; http://localhost:5123
;;;   (clug-api:stop)
;;;
;;; Compared to a Lack-only baseline this version uses:
;;;   - clug/parsers   for JSON body in/out (no per-app helper duplication)
;;;   - clug/errors    for the conn-level 500 boundary
;;;   - clug/session   instead of lack-middleware-session (avoids its
;;;                    eager body parsing on every POST/PUT)

(in-package #:cl-user)
(defpackage #:clug-api
  (:use #:cl #:clug)
  (:export #:*app* #:start #:stop))
(in-package #:clug-api)

;;; --- in-memory state -------------------------------------------------------

(defparameter *users*
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "alice" h) "secret"
          (gethash "bob"   h) "hunter2")
    h))

(defparameter *todos*   (make-hash-table))
(defparameter *next-id* 0)

;;; --- pipes -----------------------------------------------------------------

(defun require-auth (conn)
  (let ((uid (get-session-value conn :user-id)))
    (if uid
        (assign conn :user-id uid)
        (halt (render-error conn 401 "unauthorized")))))

;;; --- handlers --------------------------------------------------------------

(defun home (conn)
  (put-resp conn 200
            "<h1>clug api</h1><p>POST /api/login with JSON body.</p>"
            '("content-type" "text/html; charset=utf-8")))

(defun trigger-error (conn)
  (declare (ignore conn))
  (error "intentional explosion to exercise the error boundary"))

(defun login (conn)
  (let* ((body (json-body conn))
         (user (and body (gethash "username" body)))
         (pass (and body (gethash "password" body))))
    (cond
      ((not (and user pass))
       (render-error conn 400 "username and password required"))
      ((equal pass (gethash user *users*))
       (put-session-value conn :user-id user)
       (render-json conn 200 (obj "ok" t "user" user)))
      (t (render-error conn 401 "bad credentials")))))

(defun logout (conn)
  (clear-session conn)
  (render-json conn 200 (obj "ok" t)))

(defun whoami (conn)
  (render-json conn 200 (obj "user" (get-assign conn :user-id))))

(defun todos-index (conn)
  (render-json conn 200
               (loop for id being the hash-keys of *todos*
                       using (hash-value v)
                     collect (obj "id" id "title" (getf v :title)))))

(defun todos-create (conn)
  (let* ((body  (json-body conn))
         (title (and body (gethash "title" body))))
    (cond
      ((not title) (render-error conn 400 "title required"))
      (t (let ((id (incf *next-id*)))
           (setf (gethash id *todos*) (list :title title))
           (render-json conn 201 (obj "id" id "title" title)))))))

(defun todos-show (conn)
  (let* ((id (parse-integer (getf (conn-params conn) :id) :junk-allowed t))
         (t* (and id (gethash id *todos*))))
    (if t*
        (render-json conn 200 (obj "id" id "title" (getf t* :title)))
        (render-error conn 404 "not found"))))

(defun todos-destroy (conn)
  (let ((id (parse-integer (getf (conn-params conn) :id) :junk-allowed t)))
    (cond
      ((not (and id (gethash id *todos*)))
       (render-error conn 404 "not found"))
      (t (remhash id *todos*)
         (put-resp conn 204 nil)))))

;;; --- routes ----------------------------------------------------------------

(defroutes *routes*
  (:get  "/"              'home)
  (:get  "/boom"          'trigger-error)
  (:post "/api/login"     'login)
  (:post "/api/logout"    'logout)
  (scope "/api" :pipe-through '(require-auth)
    (:get    "/me"            'whoami)
    (:get    "/todos"         'todos-index)
    (:post   "/todos"         'todos-create)
    (:get    "/todos/:id"     'todos-show)
    (:delete "/todos/:id"     'todos-destroy)))

;;; --- composition -----------------------------------------------------------
;;;
;;; clug/session is env-level (it's middleware around the whole Clack app),
;;; with-error-catcher is conn-level (it wraps the router so handler errors
;;; become JSON 500s). No env-error-shield needed here because we avoid
;;; lack-middleware-session entirely.

(defparameter *app*
  (lack:builder
    :accesslog
    :backtrace
    (lambda (app) (with-session app))
    (to-clack-app
     (with-error-catcher (clug::router-as-plug *routes*)
                         :renderer (lambda (c e)
                                     (render-error c 500 (format nil "~a" e)))))))

(defvar *server* nil)

(defun start ()
  (setf *server* (clack:clackup *app* :port 5123 :silent t))
  (format t "~&clug-api listening on http://localhost:5123~%"))

(defun stop ()
  (when *server* (clack:stop *server*) (setf *server* nil)))
