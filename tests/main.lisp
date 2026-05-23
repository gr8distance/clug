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

(test match-decodes-segments
  (let ((c (compile-path "/files/:name")))
    ;; %20 -> space; %2F stays inside segment, doesn't act as separator
    (is (equal '(:name "hello world") (match-path c "/files/hello%20world")))
    (is (equal '(:name "a/b") (match-path c "/files/a%2Fb")))
    ;; UTF-8: %E3%81%82 -> あ
    (is (equal '(:name "あ") (match-path c "/files/%E3%81%82")))))

(test query-string-decodes
  (let ((p (clug::parse-query-string "a=hello+world&b=%E3%81%82&c=a%26b")))
    (is (equal "hello world" (getf p :a)))
    (is (equal "あ" (getf p :b)))
    (is (equal "a&b" (getf p :c))))
  ;; malformed input doesn't crash
  (is (or (null (clug::parse-query-string "a=%ZZ"))
          (listp (clug::parse-query-string "a=%ZZ")))))

;;; --- conn / pipeline ---

(test pipeline-halts
  (let* ((p1 (lambda (c) (assign c :x 1)))
         (p2 (lambda (c) (halt (assign c :x 2))))
         (p3 (lambda (c) (assign c :x 3)))
         (out (run-pipeline (make-conn) p1 p2 p3)))
    (is (equal 2 (get-assign out :x)))
    (is (conn-halted-p out))))

(test put-resp-and-header
  (let ((c (put-resp (make-conn) 201 "ok" '("content-type" "text/plain"))))
    (is (= 201 (conn-status c)))
    (is (equal "ok" (conn-body c)))
    (is (equal "text/plain" (getf (conn-headers c) "content-type")))))

(test put-header-rejects-uppercase
  (signals error (put-header (make-conn) "Content-Type" "text/plain")))

(test put-header-rejects-crlf
  (signals error (put-header (make-conn) "x-evil" "foo
Set-Cookie: a=1"))
  (signals error (put-header (make-conn) "x-evil" (format nil "ok~creturn" #\Return))))

(test put-header-rejects-non-string
  (signals error (put-header (make-conn) "content-length" 42)))

;;; --- router + scope ---

(defun h-index (c) (put-resp c 200 "index"))
(defun h-show  (c) (put-resp c 200 (format nil "show:~a" (getf (conn-params c) :id))))
(defun h-stats (c) (put-resp c 200 "stats"))

(defun tag-pipe (c) (assign c :tagged t))
(defun admin-pipe (c) (assign c :admin t))

(defroutes *r*
  (:get "/" 'h-index)
  (scope "/api" :pipe-through '(tag-pipe)
    (:get "/users/:id" 'h-show)
    (scope "/admin" :pipe-through '(admin-pipe)
      (:get "/stats" 'h-stats))))

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
