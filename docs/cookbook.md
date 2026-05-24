# Cookbook

Cross-cutting recipes — full pipelines you can copy-paste, with
notes on why each piece is where it is.

Each recipe assumes you've worked through [overview](./overview.md)
at least once.

---

## A JSON API from zero

The canonical JSON service: request-id correlation, error catching
that produces JSON 500s, JSON body parsing, and a router.

```lisp
(defpackage #:my-api
  (:use #:cl #:clug))
(in-package #:my-api)

(ql:quickload '(:clug :clug/parsers :clug/errors))

;; --- handlers ---

(defun users-index (conn)
  (render-json conn 200
               (list (obj "id" 1 "email" "alice@example.com")
                     (obj "id" 2 "email" "bob@example.com"))))

(defun users-show (conn)
  (let ((id (getf (conn-params conn) :id)))
    (render-json conn 200 (obj "id" id))))

(defun users-create (conn)
  (let* ((attrs (get-assign conn :json-body))
         (email (and (hash-table-p attrs) (gethash "email" attrs))))
    (cond
      ((not email) (render-error conn 400 "email required"))
      (t           (render-json conn 201 (obj "id" 42 "email" email))))))

;; --- routes ---

(defroutes routes
  (:get  "/users"      'users-index)
  (:get  "/users/:id"  'users-show)
  (:post "/users"      'users-create))

;; --- app assembly ---

(defun json-500 (conn condition)
  (render-json conn 500
               (obj "error" "internal_server_error"
                    "request_id" (or (request-id conn) "")
                    "detail" (princ-to-string condition))))

(defparameter *app*
  (to-clack-app
   (pipeline
    #'tag-request-id
    (with-error-catcher
     (pipeline #'parse-json
               (router-as-plug routes))
     :renderer #'json-500))))

;; --- mount ---

(clack:clackup *app* :port 5000)
```

Why this layout:

- `tag-request-id` runs **outside** the error catcher so the
  renderer can include the request ID. The cost is that an error in
  `tag-request-id` itself wouldn't be caught — but it's a six-line
  function that doesn't realistically error.
- `parse-json` runs **inside** the catcher so malformed JSON
  becomes a JSON 500 (or 400 if you discriminate) instead of a
  text/plain crash.
- The router sits at the tail; handlers focus on their own logic
  and let errors bubble up to the catcher.

---

## A simple HTML site with sessions

Browser-facing app with cookie sessions, login, logout, and a
gated dashboard.

```lisp
(defpackage #:my-site
  (:use #:cl #:clug))
(in-package #:my-site)

(ql:quickload '(:clug :clug/session))

(defparameter *store* (make-memory-store))

;; --- middleware plugs ---

(defun require-login (conn)
  (if (get-session-value conn :user-id)
      conn
      (halt (put-resp conn 302 ""
                      (list "location" "/login")))))

;; --- handlers ---

(defun home (conn)
  (put-resp conn 200 "<h1>welcome</h1><p><a href=/login>log in</a></p>"
            (list "content-type" "text/html; charset=utf-8")))

(defun login-form (conn)
  (put-resp conn 200
            "<form method=post><input name=email><button>log in</button></form>"
            (list "content-type" "text/html; charset=utf-8")))

(defun login-submit (conn)
  ;; (real code would parse form body + authenticate)
  (-> conn
      (put-session-value :user-id 1)
      (rotate-session-id)
      (put-resp 302 "" (list "location" "/dashboard"))))

(defun logout (conn)
  (clear-session conn)
  (put-resp conn 302 "" (list "location" "/")))

(defun dashboard (conn)
  (let ((uid (get-session-value conn :user-id)))
    (put-resp conn 200 (format nil "<p>user ~a</p><a href=/logout>log out</a>" uid)
              (list "content-type" "text/html; charset=utf-8"))))

;; --- routes + mount ---

(defroutes routes
  (:get  "/"          'home)
  (:get  "/login"     'login-form)
  (:post "/login"     'login-submit)
  (:post "/logout"    'logout)
  (scope "/dashboard" :pipe-through (list #'require-login)
    (:get "" 'dashboard)))

(defparameter *app*
  (with-session
   (to-clack-app routes)
   :store *store*
   :secure t            ; production HTTPS only — set to nil in dev
   :same-site :lax
   :max-age (* 60 60 24 14)))

(clack:clackup *app* :port 5000)
```

Why this layout:

- `with-session` is **outside** `to-clack-app` because it's a
  Clack-level middleware — it inspects the env before and after the
  app runs to decide what `Set-Cookie` to emit.
- `require-login` is a plug listed in the scope's `:pipe-through`,
  so every route under `/dashboard` runs it before the handler.
- `rotate-session-id` is called immediately after recording the
  user-ID — fresh SID for the post-login privilege level.
- Form parsing isn't shown; for a real HTML form you'd grab
  `(lack.request:request-body-parameters (lack.request:make-request
  (conn-req conn)))` or wire in your own form parser.

The session is opt-in: a request that never touches
`put-session-value` / `clear-session` / `rotate-session-id`
produces **no `Set-Cookie`** header. This keeps cookie noise off
GET responses that don't need a session.

---

## Mixing JSON API and HTML at the same root

Two routers — one for HTML pages, one for the JSON API — sharing
the same session.

```lisp
(defroutes pages
  (:get  "/"        'home)
  (:get  "/login"   'login-form)
  (:post "/login"   'login-submit))

(defroutes api
  (:get  "/api/me"      'api-me)
  (:post "/api/posts"   'api-create-post
         :pipe-through (list #'parse-json)))

(defun pages-or-api (conn)
  ;; First try the API; if it doesn't match (i.e. returns 404), try
  ;; pages. To avoid the round-trip, just look at the path.
  (if (alexandria:starts-with-subseq "/api" (conn-path conn))
      (call-router api conn)
      (call-router pages conn)))

(defparameter *app*
  (with-session
   (to-clack-app
    (pipeline #'tag-request-id
              #'pages-or-api))
   :store (make-memory-store)
   :same-site :lax
   :secure t))
```

A cleaner alternative: just merge into one router and use scope.
The split above is mostly useful when the two surfaces want
different error renderers (HTML 500 page vs JSON 500 payload).

---

## A protected admin scope

Multiple plugs combine with `and`-style accumulation: every
inner scope sees the outer scope's plugs **prepended** to its own.

```lisp
(defroutes routes
  (scope "/api" :pipe-through (list #'parse-json
                                    #'require-auth)
    (:get  "/users"  'users-index)
    (:post "/users"  'users-create)

    (scope "/admin" :pipe-through (list #'require-admin)
      (:get    "/users"      'admin-users-index)
      (:delete "/users/:id"  'admin-users-delete))))
```

A `DELETE /api/admin/users/42` runs:

```
parse-json → require-auth → require-admin → admin-users-delete
```

Plugs are applied in declaration order: outer scope first, inner
scope next, route's own `:pipe-through` after, handler last.

A `require-*` plug should `halt` the conn after writing the
response — otherwise downstream plugs continue running on a conn
that already has, say, a 401 status:

```lisp
(defun require-auth (conn)
  (if (get-assign conn :current-user)
      conn
      (halt (render-error conn 401 "unauthorized"))))
```

---

## Static files + dynamic routes side by side

`clug` doesn't ship a static-file server, but the Lack ecosystem
does. Wrap your clug app in `lack-middleware-static`:

```lisp
(ql:quickload '(:clug :lack-middleware-static))

(defparameter *app*
  (lack/builder:builder
   (:static :path "/static/" :root #P"./public/")
   (to-clack-app routes)))
```

Now `GET /static/img/logo.png` serves
`./public/img/logo.png` directly, without ever hitting your router.
Everything else falls through to clug.

(See [lack docs](https://github.com/fukamachi/lack) for the full
builder syntax.)

---

## Per-request timing in headers

Lightweight observability without a metrics library: stamp
`X-Response-Time-Ms` on every response.

```lisp
(defun with-timing (plug)
  (lambda (conn)
    (let* ((start (get-internal-real-time))
           (after (funcall plug conn))
           (elapsed-ms (/ (- (get-internal-real-time) start)
                          (/ internal-time-units-per-second 1000.0))))
      (put-header after "x-response-time-ms"
                  (format nil "~,1f" elapsed-ms)))))

(defparameter *app*
  (to-clack-app
   (with-timing
    (pipeline #'tag-request-id
              (router-as-plug routes)))))
```

`with-timing` is a higher-order plug: a function that takes a plug
and returns a wrapped plug. The pattern works for anything that
wants to do something *after* the wrapped plug runs (logging,
metrics, response post-processing).

---

## Logging the request line

A plug that logs `method path status request-id` after each
request. Place it after `tag-request-id` so the ID is available;
place it as a wrapper around the router so it sees the final
response state.

```lisp
(defun with-access-log (plug)
  (lambda (conn)
    (let ((c (funcall plug conn)))
      (format t "[~a] ~a ~a ~a~%"
              (or (request-id c) "-")
              (conn-status c)
              (string-upcase (symbol-name (conn-method c)))
              (conn-path c))
      c)))

(pipeline #'tag-request-id
          (with-access-log (router-as-plug routes)))
```

For structured logs, swap the `format` for whatever logging library
you use.

For "real" access logs (combined log format, etc.), prefer
`lack-middleware-accesslog` — it has the right shape and writes to
a file by default.

---

## Returning a file

Pathname response bodies are passed straight through to the Clack
adapter, which serves them efficiently (`sendfile(2)` on most
backends):

```lisp
(defun download-report (conn)
  (let ((path #P"/var/tmp/report.pdf"))
    (put-resp conn 200 path
              (list "content-type" "application/pdf"
                    "content-disposition" "attachment; filename=report.pdf"))))
```

The handler doesn't read the file — it just hands the path back.
For large files this means clug never holds the body in memory.

---

## Returning a stream

Streams are also passed through; the adapter drains them.

```lisp
(defun export-csv (conn)
  (let ((stream (open #P"/var/tmp/export.csv" :direction :input)))
    (put-resp conn 200 stream
              (list "content-type" "text/csv"
                    "content-disposition" "attachment; filename=export.csv"))))
```

You're responsible for the stream's lifetime — typically the Clack
adapter closes it after consumption, but check your adapter's
contract.

---

## A health check that bypasses middleware

You may want `/healthz` to skip session loading, body parsing, etc.
Two approaches:

**(a) Branch in a top-level plug:**

```lisp
(defun health-or-app (app)
  (lambda (conn)
    (if (string= (conn-path conn) "/healthz")
        (put-resp conn 200 "ok"
                  (list "content-type" "text/plain"))
        (funcall app conn))))

(pipeline (health-or-app (router-as-plug routes)))
```

The health handler runs **before** anything downstream — no
session, no parsing, no error catcher overhead.

**(b) Put the route in its own router, mounted in front of the
main one:**

```lisp
(defroutes health-routes
  (:get "/healthz" 'healthz))

(defun chain-routers (&rest routers)
  (lambda (conn)
    (loop for r in routers
          for c = (call-router r conn)
          unless (= 404 (conn-status c))
            return c
          finally (return c))))

(pipeline (chain-routers health-routes routes))
```

The first router is tried; if it 404s, the next one is tried. This
generalises to "mount multiple routers on the same root."

---

## Mounting clug under a path prefix

If you're running clug as one app among several under the same
Clack handler:

```lisp
(ql:quickload '(:clug :lack-middleware-mount))

(defparameter *app*
  (lack/builder:builder
   (:mount "/api"   (to-clack-app api-routes))
   (:mount "/admin" (to-clack-app admin-routes))
   #'default-404-app))
```

Each mounted app receives its `path-info` already stripped of the
mount prefix — your routes inside the API can be written as
`/users`, not `/api/users`.
