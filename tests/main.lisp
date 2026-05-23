(defpackage #:clug/tests
  (:use #:cl #:clug #:fiveam))
(in-package #:clug/tests)

(def-suite :clug)
(in-suite :clug)

;;; --- path ---

(test split-and-compile
  (is (equal '("a" "b") (clug::split-path "/a/b")))
  (is (equal nil (clug::split-path "/")))
  (let ((c (compile-path "/users/:id")))
    (is (equal "users" (first c)))
    (is (equal :param (caadr c)))
    (is (equal :id (cadadr c)))))

(test match
  (let ((c (compile-path "/users/:id")))
    (is (equal '(:id "42") (match-path c "/users/42")))
    (is (null (match-path c "/users/42/extra"))))
  (is (eq t (match-path (compile-path "/") "/"))))

;;; --- conn / pipeline ---

(test pipeline-halts
  (let* ((p1 (lambda (c) (assign c :x 1)))
         (p2 (lambda (c) (halt (assign c :x 2))))
         (p3 (lambda (c) (assign c :x 3)))
         (out (run-pipeline (make-conn) p1 p2 p3)))
    (is (equal 2 (get-assign out :x)))
    (is (conn-halted-p out))))

(test put-resp-and-header
  (let ((c (put-resp (make-conn) 201 "ok" '("Content-Type" "text/plain"))))
    (is (= 201 (conn-status c)))
    (is (equal "ok" (conn-body c)))
    (is (equal "text/plain" (getf (conn-headers c) "Content-Type")))))

;;; --- router + scope ---

(defun h-index (c) (put-resp c 200 "index"))
(defun h-show  (c) (put-resp c 200 (format nil "show:~a" (getf (conn-params c) :id))))
(defun h-stats (c) (put-resp c 200 "stats"))

(defun tag-pipe (c) (assign c :tagged t))
(defun admin-pipe (c) (assign c :admin t))

(defparameter *r*
  (make-router
   :entries
   (append
    (route :get "/" 'h-index)
    (scope "/api" :pipe-through '(tag-pipe)
      (route :get "/users/:id" 'h-show)
      (scope "/admin" :pipe-through '(admin-pipe)
        (route :get "/stats" 'h-stats))))))

(defun call (router method path)
  (clug::call-router router (make-conn :method method :path path)))

(test routes-match
  (is (equal "index" (conn-body (call *r* :get "/"))))
  (is (equal "show:7" (conn-body (call *r* :get "/api/users/7"))))
  (is (equal "stats" (conn-body (call *r* :get "/api/admin/stats")))))

(test scope-pipes-accumulate
  (let ((c (call *r* :get "/api/admin/stats")))
    (is (eq t (get-assign c :tagged)))
    (is (eq t (get-assign c :admin)))))

(test not-found
  (is (= 404 (conn-status (call *r* :get "/missing")))))

(test method-mismatch
  (is (= 404 (conn-status (call *r* :post "/")))))
