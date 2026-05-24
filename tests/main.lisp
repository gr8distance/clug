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
    (is (equal "text/plain" (get-resp-header c "content-type")))
    (is (equal "text/plain" (get-resp-header c "Content-Type")))))

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

(test method-not-allowed
  (let ((c (call *r* :post "/")))
    (is (= 405 (conn-status c)))
    (let ((allow (get-resp-header c "allow")))
      (is (search "GET"     allow))
      (is (search "HEAD"    allow))
      (is (search "OPTIONS" allow)))))

(test head-falls-back-to-get
  (let ((c (call *r* :head "/")))
    (is (= 200 (conn-status c)))
    ;; the handler still ran and produced "index"; conn->clack strips it
    (is (equal "index" (conn-body c)))
    (let ((clack-resp (clug::conn->clack c)))
      (is (equal '() (third clack-resp))))))

(test options-returns-allow
  (let ((c (call *r* :options "/")))
    (is (= 204 (conn-status c)))
    (is (search "GET" (get-resp-header c "allow")))))

(test options-on-missing-path-404s
  (is (= 404 (conn-status (call *r* :options "/nope")))))

;;; --- wildcard routes ---

(test wildcard-compile-and-match
  (let ((c (compile-path "/static/*path")))
    (is (equal '(:path ("a" "b" "c")) (match-path c "/static/a/b/c")))
    (is (equal '(:path nil)           (match-path c "/static")))
    (is (null (match-path c "/other/a")))))

(test wildcard-must-be-last
  (signals error (compile-path "/a/*rest/b")))

(defun h-static (c)
  (put-resp c 200 (format nil "~{~a~^/~}" (getf (conn-params c) :path))))

(defroutes *rw*
  (:get "/static/*path" 'h-static))

(test wildcard-route-end-to-end
  (is (equal "img/logo.png" (conn-body (call *rw* :get "/static/img/logo.png"))))
  (is (equal ""            (conn-body (call *rw* :get "/static")))))

;;; --- request helpers ---

(defun fake-env (&key headers raw-body)
  (list :headers (when headers
                   (alexandria:plist-hash-table headers :test 'equal))
        :raw-body raw-body))

(test get-req-header-is-case-insensitive
  (let ((c (make-conn :req (fake-env :headers '("content-type" "application/json"
                                                "x-foo" "bar")))))
    (is (equal "application/json" (get-req-header c "Content-Type")))
    (is (equal "bar"              (get-req-header c "x-foo")))
    (is (null (get-req-header c "x-missing"))))
  ;; tolerates missing headers
  (is (null (get-req-header (make-conn) "anything"))))

(test read-req-body-caches
  (let* ((c0 (make-conn :req (fake-env :raw-body "raw string body")))
         (call-count 0))
    (multiple-value-bind (b1 c1) (read-req-body c0)
      (incf call-count)
      (multiple-value-bind (b2 c2) (read-req-body c1)
        (declare (ignore c2))
        (is (equal "raw string body" b1))
        (is (eq b1 b2))                        ; same object — cache hit
        (is (= 1 call-count))))))

(test read-req-body-drains-octet-stream
  (let* ((bytes (make-array 5 :element-type '(unsigned-byte 8)
                              :initial-contents '(104 101 108 108 111)))
         (stream (flexi-streams:make-in-memory-input-stream bytes))
         (c0 (make-conn :req (fake-env :raw-body stream))))
    (multiple-value-bind (body c1) (read-req-body c0)
      (declare (ignore c1))
      (is (equalp bytes body)))))

;;; --- cookies ---

(test fetch-req-cookies-parses-and-decodes
  (let ((c (make-conn :req (fake-env
                            :headers '("cookie" "sid=abc; greeting=hello%20world")))))
    (multiple-value-bind (cookies c1) (fetch-req-cookies c)
      (declare (ignore c1))
      (is (equal "abc"          (cdr (assoc "sid" cookies :test 'equal))))
      (is (equal "hello world"  (cdr (assoc "greeting" cookies :test 'equal)))))))

(test put-resp-cookie-attributes
  (let* ((c (put-resp-cookie (make-conn) "sid" "abc"
                             :max-age 3600 :secure t :same-site :lax))
         (sc (get-resp-header c "set-cookie")))
    (is (search "sid=abc"      sc))
    (is (search "Path=/"       sc))
    (is (search "Max-Age=3600" sc))
    (is (search "HttpOnly"     sc))
    (is (search "Secure"       sc))
    (is (search "SameSite=Lax" sc))))

(test put-resp-cookie-multiple-coexist
  (let* ((c0 (put-resp-cookie (make-conn) "a" "1"))
         (c1 (put-resp-cookie c0 "b" "2"))
         (set-cookies (loop for (k v) on (conn-headers c1) by #'cddr
                            when (string= k "set-cookie") collect v)))
    (is (= 2 (length set-cookies)))
    (is (find "a=1" set-cookies :test (lambda (a b) (search a b))))
    (is (find "b=2" set-cookies :test (lambda (a b) (search a b))))))

(test put-header-rejects-set-cookie
  (signals error (put-header (make-conn) "set-cookie" "a=1")))

(test put-resp-cookie-rejects-crlf-in-path
  ;; Without attribute validation, a CR/LF in :path could inject
  ;; arbitrary response headers via Set-Cookie. PUT-RESP-COOKIE
  ;; bypasses PUT-HEADER's dedup path, so attributes must be
  ;; re-validated.
  (signals error
    (put-resp-cookie (make-conn) "sid" "x"
                     :path (format nil "/foo~aSet-Cookie: evil=1" #\Newline)))
  (signals error
    (put-resp-cookie (make-conn) "sid" "x"
                     :path (format nil "/foo~areturn" #\Return)))
  (signals error
    (put-resp-cookie (make-conn) "sid" "x" :domain (format nil "x~ay" #\Newline)))
  (signals error
    (put-resp-cookie (make-conn) "sid" "x" :expires (format nil "x~ay" #\Return))))

(test put-resp-cookie-rejects-negative-max-age
  (signals error
    (put-resp-cookie (make-conn) "sid" "x" :max-age -1)))

;;; --- request-id (core) ----------------------------------------------------

(test tag-request-id-generates-when-missing
  (let* ((c (tag-request-id (make-conn))))
    (is (not (null (request-id c))))
    (is (equal (request-id c) (get-resp-header c "x-request-id")))))

(test tag-request-id-trusts-incoming
  (let* ((c (make-conn :req (fake-env
                             :headers '("x-request-id" "upstream-abc-123"))))
         (out (tag-request-id c)))
    (is (equal "upstream-abc-123" (request-id out)))
    (is (equal "upstream-abc-123" (get-resp-header out "x-request-id")))))

(test tag-request-id-rejects-oversize-incoming
  (let* ((huge (make-string 500 :initial-element #\a))
         (c (make-conn :req (fake-env :headers (list "x-request-id" huge))))
         (out (tag-request-id c)))
    (is (not (equal huge (request-id out))))
    (is (<= (length (request-id out)) clug:*request-id-max-length*))))

(test tag-request-id-custom-generator
  (let ((out (tag-request-id (make-conn) :generator (lambda () "fixed"))))
    (is (equal "fixed" (request-id out)))
    (is (equal "fixed" (get-resp-header out "x-request-id")))))

;;; --- clug/parsers ---------------------------------------------------------

(asdf:load-system :clug/parsers)

(test body-string-passes-string-through
  (let ((c (make-conn :req (fake-env :raw-body "hello"))))
    (is (equal "hello" (body-string c)))))

(test body-string-decodes-octets-utf8
  (let* ((bytes (babel:string-to-octets "あいう" :encoding :utf-8))
         (stream (flexi-streams:make-in-memory-input-stream bytes))
         (c (make-conn :req (fake-env :raw-body stream))))
    (is (equal "あいう" (body-string c)))))

(test json-body-parses-object
  (let ((c (make-conn :req (fake-env :raw-body "{\"name\":\"alice\",\"n\":42}"))))
    (let ((h (json-body c)))
      (is (equal "alice" (gethash "name" h)))
      (is (= 42 (gethash "n" h))))))

(test json-body-returns-nil-on-empty
  (is (null (json-body (make-conn :req (fake-env :raw-body ""))))))

(test json-body-signals-on-bad-input
  (let ((c (make-conn :req (fake-env :raw-body "this is not json"))))
    (signals error (json-body c))))

(test obj-builds-string-keyed-hash-table
  (let ((h (obj "a" 1 "b" "two")))
    (is (= 1 (gethash "a" h)))
    (is (equal "two" (gethash "b" h)))))

(test render-json-sets-content-type-and-body
  (let* ((c (render-json (make-conn) 201 (obj "ok" t)))
         (body (conn-body c)))
    (is (= 201 (conn-status c)))
    (is (equal "application/json" (get-resp-header c "content-type")))
    (is (search "\"ok\":true" body))))

(test render-error-shape
  (let ((c (render-error (make-conn) 400 "bad")))
    (is (= 400 (conn-status c)))
    (is (search "\"error\":\"bad\"" (conn-body c)))))

(test parse-json-stashes-on-content-type
  (let* ((c (make-conn :req (fake-env :headers '("content-type" "application/json")
                                      :raw-body "{\"x\":1}")))
         (c2 (parse-json c)))
    (is (= 1 (gethash "x" (get-assign c2 :json-body))))))

(test parse-json-passthrough-on-other-content-type
  (let* ((c (make-conn :req (fake-env :headers '("content-type" "text/plain")
                                      :raw-body "hello")))
         (c2 (parse-json c)))
    (is (null (get-assign c2 :json-body)))))

;;; --- clug/errors ----------------------------------------------------------

(asdf:load-system :clug/errors)

(test with-error-catcher-passthrough-on-success
  (let* ((plug (lambda (c) (put-resp c 200 "ok")))
         (wrapped (with-error-catcher plug))
         (out (funcall wrapped (make-conn))))
    (is (= 200 (conn-status out)))
    (is (equal "ok" (conn-body out)))))

(test with-error-catcher-returns-500-on-error
  (let* ((plug (lambda (c) (declare (ignore c)) (error "boom")))
         (wrapped (with-error-catcher plug))
         (out (funcall wrapped (make-conn))))
    (is (= 500 (conn-status out)))
    (is (search "boom" (conn-body out)))))

(test with-error-catcher-honors-custom-renderer
  (let* ((plug (lambda (c) (declare (ignore c)) (error "nope")))
         (wrapped (with-error-catcher
                   plug
                   :renderer (lambda (c e)
                               (render-error c 418 (format nil "~a" e)))))
         (out (funcall wrapped (make-conn))))
    (is (= 418 (conn-status out)))
    (is (search "\"error\":\"nope\"" (conn-body out)))))

;;; --- clug/session ---------------------------------------------------------

(asdf:load-system :clug/session)

(defun env-with-cookie (cookie)
  (list :headers (alexandria:plist-hash-table
                  (when cookie (list "cookie" cookie)) :test 'equal)))

(defun cookie-from-response (response key)
  "Extract Set-Cookie value for KEY from a Clack response."
  (loop for (k v) on (second response) by #'cddr
        when (and (stringp k) (string= k "set-cookie")
                  (alexandria:starts-with-subseq (format nil "~a=" key) v))
          return v))

(test session-load-and-save-roundtrip
  (let* ((store (make-memory-store))
         (captured-sid nil)
         (app (with-session
                (lambda (env)
                  (let ((conn (make-conn :req env)))
                    (put-session-value conn :user "alice")
                    (setf captured-sid (session-id conn))
                    (list 200 nil '(""))))
                :store store))
         (response (funcall app (env-with-cookie nil)))
         (set-cookie (cookie-from-response response "clug.session")))
    (is (= 200 (first response)))
    ;; new SID assigned, Set-Cookie emitted
    (is (not (null set-cookie)))
    ;; subsequent request with same cookie -> session restored
    (let* ((sid (let* ((eq-pos (position #\= set-cookie))
                       (semi   (position #\; set-cookie)))
                  (subseq set-cookie (1+ eq-pos) semi)))
           (loaded nil)
           (app2 (with-session
                   (lambda (env)
                     (let ((c (make-conn :req env)))
                       (setf loaded (get-session-value c :user))
                       (list 200 nil '(""))))
                   :store store)))
      (declare (ignore captured-sid))
      (funcall app2 (env-with-cookie (format nil "clug.session=~a" sid)))
      (is (equal "alice" loaded)))))

(test session-clear-destroys-and-expires-cookie
  (let* ((store (make-memory-store))
         (sid "deadbeef"))
    (store-save store sid (alexandria:plist-hash-table '(:user "alice") :test 'equal))
    (let* ((app (with-session
                  (lambda (env)
                    (let ((c (make-conn :req env)))
                      (clear-session c)
                      (list 200 nil '(""))))
                  :store store))
           (response (funcall app
                              (env-with-cookie (format nil "clug.session=~a" sid)))))
      (is (= 200 (first response)))
      ;; store entry gone
      (is (null (store-load store sid)))
      ;; expiring Set-Cookie emitted (Max-Age=0)
      (let ((sc (cookie-from-response response "clug.session")))
        (is (not (null sc)))
        (is (search "Max-Age=0" sc))))))

(test session-rotate-issues-new-sid-and-deletes-old
  ;; Pre-populate the store under SID_old.
  (let* ((store (make-memory-store))
         (old-sid "deadbeef0000")
         (data (alexandria:plist-hash-table '(:user "alice") :test 'equal))
         (_ (store-save store old-sid data))
         (app (with-session
                (lambda (env)
                  (let ((c (make-conn :req env)))
                    (rotate-session-id c)
                    (list 200 nil '(""))))
                :store store))
         (response (funcall app
                            (env-with-cookie (format nil "clug.session=~a" old-sid)))))
    (declare (ignore _))
    (is (= 200 (first response)))
    ;; old sid is gone from the store
    (is (null (store-load store old-sid)))
    ;; a fresh Set-Cookie is emitted
    (let ((sc (cookie-from-response response "clug.session")))
      (is (not (null sc)))
      ;; ... carrying a new sid (not the old value)
      (let* ((eq-pos (position #\= sc))
             (semi   (position #\; sc))
             (new-sid (subseq sc (1+ eq-pos) semi)))
        (is (not (string= old-sid new-sid)))
        ;; data preserved under the new sid
        (let ((reloaded (store-load store new-sid)))
          (is (not (null reloaded)))
          (is (equal "alice" (gethash :user reloaded))))))))

(test session-no-cookie-when-not-touched
  (let* ((app (with-session (lambda (env)
                              (declare (ignore env))
                              (list 200 nil '("")))))
         (response (funcall app (env-with-cookie nil))))
    ;; handler didn't touch session -> no Set-Cookie
    (is (null (cookie-from-response response "clug.session")))))

(test session-helpers-default-when-no-session
  (let ((c (make-conn)))
    (is (eq :fallback (get-session-value c :missing :fallback)))
    (is (null (session-id c)))))

(test generate-sid-is-hex
  (let ((sid (generate-sid 8)))
    (is (= 16 (length sid)))
    (is (every (lambda (c) (or (digit-char-p c) (find c "abcdefABCDEF"))) sid))))
