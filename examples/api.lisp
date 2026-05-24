;;; A Plug-style REST API demonstrating clug + opt-in sub-systems.
;;;
;;; ============================================================
;;; ⚠️  THIS IS A clug PRIMITIVE DEMO, NOT A REFERENCE AUTH IMPL.
;;; ============================================================
;;;
;;; The login handler below uses PLAIN-TEXT password storage and a
;;; non-constant-time EQUAL comparison, and it does NOT rotate the
;;; session id on login. These are deliberate simplifications so the
;;; file stays readable as a routing / session demo — they are NOT
;;; how you build a real login.
;;;
;;; For production-grade auth, use clauth:
;;;   https://github.com/gr8distance/clauth
;;; which provides Argon2id hashing, constant-time verify, dummy-hash
;;; timing protection, account lockout, session-token rotation, and
;;; email-driven confirmation / reset / magic-link flows.
;;;
;;; If you keep this file as your starting point, the minimum changes
;;; required before deploying are:
;;;   1. Hash passwords (clauth:hash-password / clauth:verify-password)
;;;   2. Use ironclad:constant-time-equal for any auth comparison
;;;   3. Call (clug:rotate-session-id conn) immediately after a
;;;      privilege change to defend against session fixation
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
  ;; ⚠️ DEMO-ONLY auth. EQUAL is short-circuit and the passwords are
  ;; in plain text — production code MUST use clauth (Argon2id +
  ;; ironclad:constant-time-equal). See the file header for details.
  (let* ((body (json-body conn))
         (user (and body (gethash "username" body)))
         (pass (and body (gethash "password" body))))
    (cond
      ((not (and user pass))
       (render-error conn 400 "username and password required"))
      ((equal pass (gethash user *users*))
       ;; rotate-session-id immediately after a privilege change is the
       ;; session-fixation defense — an attacker who planted a session
       ;; cookie on the browser pre-login no longer rides the post-login
       ;; privilege level.
       (let ((c (rotate-session-id conn)))
         (put-session-value c :user-id user)
         (render-json c 200 (obj "ok" t "user" user))))
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
     (with-error-catcher
      ;; tag-request-id runs before the router so every response carries
      ;; x-request-id and handlers / error renderers can correlate via
      ;; (request-id conn).
      (pipeline #'tag-request-id (clug::router-as-plug *routes*))
      :renderer (lambda (c e)
                  (render-error c 500
                                (format nil "~a (request-id ~a)"
                                        e (request-id c))))))))

(defvar *server* nil)

(defun start ()
  (setf *server* (clack:clackup *app* :port 5123 :silent t))
  (format t "~&clug-api listening on http://localhost:5123~%"))

(defun stop ()
  (when *server* (clack:stop *server*) (setf *server* nil)))
