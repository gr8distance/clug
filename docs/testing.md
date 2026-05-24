# Testing

Because every plug is a function `(conn) → conn`, testing clug code
mostly boils down to: build a conn, call the function, assert on
the result. No HTTP server, no Clack handler, no network — just
function calls.

This page shows how to construct fixtures, invoke plugs and routers
directly, and what to assert on.

The patterns below come from clug's own test suite at
[`tests/main.lisp`](../tests/main.lisp); browse it for a fuller
gallery.

---

## Build a conn directly

`make-conn` accepts keyword arguments matching the struct slots:

```lisp
(make-conn :method :get :path "/users/42")
```

Defaults: `:method :get`, `:path "/"`, all other slots `NIL` or
empty. That's enough to feed into most plugs.

For plugs that read request headers or body, attach a `:req` plist
shaped like a Clack env:

```lisp
(defun fake-env (&key headers raw-body)
  (list :headers (when headers
                   (alexandria:plist-hash-table headers :test 'equal))
        :raw-body raw-body))

(make-conn :req (fake-env :headers '("content-type" "application/json")
                          :raw-body "{\"x\":1}"))
```

The `:headers` value is a hash-table keyed by **lowercase strings**
— that's the Clack convention. `:raw-body` can be a string, an
octet vector, a stream (any `streamp`), or `NIL`.

---

## Call a plug directly

```lisp
(test handler-returns-200
  (let ((out (hello (make-conn))))
    (is (= 200 (conn-status out)))
    (is (equal "hello, clug" (conn-body out)))))
```

That's the whole pattern. The "fixture → call → assert" loop is
how the entire clug suite is structured.

For a plug that depends on a previous plug's assigns:

```lisp
(test user-handler-reads-current-user
  (let* ((c0 (assign (make-conn) :current-user '(:id 1 :email "a@x")))
         (out (show-user c0)))
    (is (search "a@x" (conn-body out)))))
```

You stub `:current-user` directly — no need to drag the auth
middleware into the test.

---

## Call a pipeline directly

`run-pipeline` is your friend:

```lisp
(test pipeline-applies-and-halts
  (let* ((p1 (lambda (c) (assign c :x 1)))
         (p2 (lambda (c) (halt (assign c :x 2))))
         (p3 (lambda (c) (assign c :x 3))))   ; should NOT run
    (let ((out (run-pipeline (make-conn) p1 p2 p3)))
      (is (= 2 (get-assign out :x)))
      (is (conn-halted-p out)))))
```

---

## Call a router directly

`clug::call-router` is internal but stable. The tests use it:

```lisp
(defroutes routes
  (:get  "/"            'home)
  (:get  "/users/:id"   'users-show))

(defun call (method path)
  (clug::call-router routes
                     (make-conn :method method :path path)))

(test root-route
  (let ((c (call :get "/")))
    (is (= 200 (conn-status c)))
    (is (equal "home" (conn-body c)))))

(test param-route
  (let ((c (call :get "/users/42")))
    (is (equal '(:id "42") (subseq (conn-params c) 0 2)))))
```

If you'd rather not reach into the internal `call-router`, use
`(funcall (router-as-plug routes) conn)` — it's the public form
and does the same thing.

---

## Test path matching in isolation

For routes with complex patterns, test the matcher directly without
a router:

```lisp
(test wildcard-captures-rest
  (let ((c (compile-path "/static/*path")))
    (is (equal '(:path ("a" "b" "c")) (match-path c "/static/a/b/c")))
    (is (equal '(:path nil)           (match-path c "/static")))
    (is (null                         (match-path c "/other/a")))))
```

`compile-path` returns the segment list; `match-path` returns the
captured params (or `T` for empty match, or `NIL` for no match).
Useful when debugging "why doesn't this route match?"

---

## Test 405 / OPTIONS / HEAD

```lisp
(test method-not-allowed
  (let ((c (call :post "/")))
    (is (= 405 (conn-status c)))
    (is (search "GET" (get-resp-header c "allow")))))

(test options-returns-204-with-allow
  (let ((c (call :options "/")))
    (is (= 204 (conn-status c)))
    (is (search "OPTIONS" (get-resp-header c "allow")))))

(test head-falls-back-to-get-and-strips-body
  (let ((c (call :head "/")))
    ;; the GET handler still ran (conn-body is set)
    (is (= 200 (conn-status c)))
    ;; conn->clack strips the body for HEAD
    (let ((clack-resp (clug::conn->clack c)))
      (is (equal '() (third clack-resp))))))
```

The asymmetry: `conn-body` still holds the GET body after a HEAD
request because the handler ran normally. The body is only stripped
when serializing to a Clack response via `conn->clack`.

---

## Test plugs that read JSON

Combine a fake env with `parse-json`:

```lisp
(ql:quickload :clug/parsers)

(test parse-json-stashes-on-correct-content-type
  (let* ((c0 (make-conn
              :req (fake-env :headers '("content-type" "application/json")
                             :raw-body "{\"x\":1}")))
         (c1 (parse-json c0)))
    (is (= 1 (gethash "x" (get-assign c1 :json-body))))))

(test parse-json-passes-through-non-json
  (let* ((c0 (make-conn :req (fake-env :headers '("content-type" "text/plain")
                                       :raw-body "hello")))
         (c1 (parse-json c0)))
    (is (null (get-assign c1 :json-body)))))
```

For a handler that expects JSON, stub `:json-body` directly:

```lisp
(test create-user-with-stubbed-json
  (let* ((attrs (obj "email" "alice@example.com"))
         (c0 (assign (make-conn) :json-body attrs))
         (out (users-create c0)))
    (is (= 201 (conn-status out)))
    (is (search "alice@example.com" (conn-body out)))))
```

`obj` (from `clug/parsers`) gives you a JSON-shaped hash-table for
fixtures.

---

## Test error catching

```lisp
(ql:quickload :clug/errors)

(test with-error-catcher-becomes-500
  (let* ((plug (lambda (c) (declare (ignore c)) (error "boom")))
         (wrapped (with-error-catcher plug))
         (out (funcall wrapped (make-conn))))
    (is (= 500 (conn-status out)))
    (is (search "boom" (conn-body out)))))

(test with-error-catcher-custom-renderer
  (let* ((plug (lambda (c) (declare (ignore c)) (error "nope")))
         (wrapped (with-error-catcher
                   plug
                   :renderer (lambda (c condition)
                               (render-error c 418
                                             (format nil "~a" condition)))))
         (out (funcall wrapped (make-conn))))
    (is (= 418 (conn-status out)))
    (is (search "\"error\":\"nope\"" (conn-body out)))))
```

---

## Test sessions

The session middleware is Clack-level (it wraps an app, not a
plug), so testing it means feeding it a fake env:

```lisp
(ql:quickload :clug/session)

(defun env-with-cookie (cookie)
  (list :headers (alexandria:plist-hash-table
                  (when cookie (list "cookie" cookie)) :test 'equal)))

(test session-load-and-save-roundtrip
  (let* ((store (make-memory-store))
         (app (with-session
               (lambda (env)
                 (let ((conn (make-conn :req env)))
                   (put-session-value conn :user "alice")
                   (list 200 nil '(""))))
               :store store))
         ;; First request: no cookie -> new session, Set-Cookie emitted
         (response (funcall app (env-with-cookie nil)))
         (set-cookie (find-set-cookie response "clug.session")))
    (is (= 200 (first response)))
    (is (not (null set-cookie)))
    ;; Second request with the cookie -> session restored
    (let* ((sid (extract-sid set-cookie))
           (loaded nil)
           (app2 (with-session
                  (lambda (env)
                    (let ((c (make-conn :req env)))
                      (setf loaded (get-session-value c :user))
                      (list 200 nil '(""))))
                  :store store)))
      (funcall app2 (env-with-cookie (format nil "clug.session=~a" sid)))
      (is (equal "alice" loaded)))))
```

`find-set-cookie` and `extract-sid` are test helpers — clug's
suite has working versions of both; copy from
[`tests/main.lisp`](../tests/main.lisp).

The pattern: the inner Clack app captures whatever you want to
assert into a closure variable, returns a minimal response, and the
test inspects both the closure variable and the response's
`Set-Cookie` header.

---

## A typical test layout

The tests use `fiveam`:

```lisp
(defpackage #:my-app/tests
  (:use #:cl #:fiveam #:my-app)
  (:import-from #:clug
                #:make-conn #:run-pipeline
                #:get-assign #:assign #:conn-status #:conn-body))

(in-package #:my-app/tests)

(def-suite :my-app)
(in-suite :my-app)

(test routes-match
  ...)

(test handlers-return-shapes
  ...)
```

Run from the REPL:

```lisp
(asdf:test-system :my-app)
;; or:
(fiveam:run! :my-app)
```

Or from the shell:

```sh
sbcl --non-interactive --load ~/quicklisp/setup.lisp \
     --eval '(ql:quickload :my-app/tests)' \
     --eval '(asdf:test-system :my-app)'
```

---

## What NOT to test through the network

If you're tempted to spin up a Clack server in a test, ask first
whether you can call the plug directly. You usually can — and the
direct call is faster, deterministic, and doesn't require port
allocation or sleep loops.

Reach for an actual HTTP test (with `dexador` against a running
Clack server) only when you need to test:

- The Clack adapter integration itself
- Streaming response bodies
- WebSocket upgrade handshakes
- Multipart upload behavior end-to-end

For everything else — routing, middleware, handlers, sessions,
error rendering — call the plug.

---

## Quick reference

| What you want to test     | How |
| ------------------------- | --- |
| A handler in isolation    | `(funcall #'handler (make-conn ...))` |
| A pipeline                | `(run-pipeline conn plug1 plug2 ...)` |
| Route matching            | `(call-router router conn)` or `(funcall (router-as-plug router) conn)` |
| Method 405 / OPTIONS      | Hit the router with that method on a path that lacks it |
| `HEAD` body stripping     | `(conn->clack (call-router router head-conn))` |
| Path matching            | `(match-path (compile-path "/...") "/...")` |
| `parse-json` integration  | Fake env with `content-type: application/json` + raw body |
| `with-error-catcher`      | Wrap a `(lambda (c) (error "..."))` plug |
| Session round-trip        | Two requests through `with-session` sharing a store |
| A `:pipe-through` ran    | Assert on assigns the plug sets |
