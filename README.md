# clug

A tiny Clack routing plugin for Common Lisp, in the spirit of Phoenix's `Plug`.

`clug` is a [ningle](https://github.com/fukamachi/ningle) alternative built on
one idea:

> **A plug is just a function `(conn) -> conn`.**

Middleware, handlers, and the router itself are all the same shape. You compose
them with `pipeline`, group them with `scope`, and mount the result as a Clack
app. Nothing else.

---

## Install

`clug` isn't on Quicklisp yet. Drop a symlink into `local-projects`:

```sh
git clone https://github.com/gr8distance/clug.git ~/src/clug
ln -s ~/src/clug ~/quicklisp/local-projects/clug
```

Then from a Lisp REPL:

```lisp
(ql:quickload :clug)
```

You'll also need a Clack handler (e.g. `clack-handler-hunchentoot` or
`clack-handler-woo`) to actually serve requests.

---

## Quickstart

```lisp
(defpackage #:my-app (:use #:cl #:clug))
(in-package #:my-app)

(defun hello (conn)
  (put-resp conn 200 "hello, clug"
            (list "content-type" "text/plain")))

(defroutes *routes*
  (:get "/" 'hello))

(defparameter *app* (to-clack-app *routes*))

(clack:clackup *app* :port 5000)
```

```sh
curl localhost:5000/        # => hello, clug
```

---

## Feature lookup

Where each feature lives — three tiers: clug core (always available),
opt-in clug sub-systems (same repo, separate `ql:quickload`), and
existing Clack/Lack ecosystem libraries.

### In clug core — just `(ql:quickload :clug)`

| Want | Use |
|---|---|
| Routing (`GET`/`POST`/...) | `defroutes`, `(:get "/path" 'handler)` shorthand |
| Path params | `:name` segments (`/users/:id`) |
| Wildcard / catch-all routes | `*name` (last segment, `/static/*path`) |
| Nested route groups + shared plugs | `(scope "/api" :pipe-through '(auth) ...)` |
| `HEAD` / `OPTIONS` / `405 Method Not Allowed` | Automatic, RFC-compliant |
| Plug composition | `pipeline`, `halt`, `assign`/`get-assign` |
| Request headers | `(get-req-header conn "x-foo")` |
| Request body (raw, single-read cache) | `(read-req-body conn)` |
| Query string | Auto-parsed into `(conn-params conn)` |
| Response status / body / header | `put-status`, `put-body`, `put-header`, `put-resp` |
| Response header lookup | `(get-resp-header conn "content-type")` |
| Response cookies (single) | `(put-resp-cookie conn "key" "val" :max-age ...)` |
| Request cookie parsing | `(fetch-req-cookies conn)` |
| Request ID (`x-request-id`) for log correlation | `tag-request-id` plug + `(request-id conn)` |
| Percent-decoding (path + query) | Automatic |
| Header injection / CRLF defense | Automatic (`put-header` rejects) |

### Opt-in clug sub-systems — same repo

| Want | Pull | Use |
|---|---|---|
| JSON request body → hash-table | `:clug/parsers` | `(json-body conn)` |
| JSON response | `:clug/parsers` | `(render-json conn 200 (obj ...))`, `render-error` |
| Plug-form JSON body parser | `:clug/parsers` | `parse-json` plug → `(get-assign conn :json-body)` |
| Catch handler errors → 500 | `:clug/errors` | `(with-error-catcher router :renderer ...)` |
| Server-side session (no body parsing!) | `:clug/session` | `with-session` middleware + `get-session-value`/`put-session-value`/`clear-session` |
| Pluggable session store | `:clug/session` | implement `store-load`/`store-save`/`store-delete` generic functions |

### From the existing Lack / Clack ecosystem

| Want | Use |
|---|---|
| Static file serving | `lack-middleware-static` or `lack-app-file` / `lack-app-directory` |
| CSRF protection | `lack-middleware-csrf` |
| Access logging | `lack-middleware-accesslog` |
| Dev-mode pretty error pages | `lack-middleware-backtrace` |
| gzip response compression | `lack-middleware-deflater` |
| Mount sub-apps at a prefix (Plug's `forward`) | `lack-middleware-mount` |
| HTTP Basic auth | `lack-middleware-auth-basic` |
| WebSocket | `clack-socket` + `websocket-driver` |
| Form / multipart body parsing | `(lack.request:request-body-parameters (lack.request:make-request env))` |
| Accept-header content negotiation | `lack.request:request-accepts-p` |
| DB connection pool | `lack-middleware-dbpool` |
| Alternative session store (Redis / DB) | `lack-session-store-redis` / `-dbi` *(if using `lack-middleware-session` instead of `clug/session`)* |
| Server adapter (HTTP) | `clack-handler-hunchentoot`, `-woo`, `-toot`, `-wookie` |
| HTTP client | `dexador` |
| JSON library (if you prefer another) | `jonathan`, `jzon`, `cl-json` *(`clug/parsers` uses `yason`)* |
| HTML templating | `spinneret`, `cl-who`, `djula` |
| Database access | `cl-dbi`, `mito` |

### Sample combinations

```lisp
;; Minimal — routing only, no JSON, no session
(ql:quickload :clug)

;; JSON REST API with error handling
(ql:quickload '(:clug :clug/parsers :clug/errors))

;; Full app: API + session + static + logs
(ql:quickload '(:clug :clug/parsers :clug/errors :clug/session
                :clack-handler-hunchentoot :lack))
;; then in lack:builder add :accesslog :backtrace
;; (:static :path "/public/" :root #P"public/")
;; and wrap with with-session

;; Heavy uploads / form bodies — add lack-request directly
(ql:quickload '(:clug :clug/parsers :clug/errors :clug/session :lack-request))
;; call (lack.request:request-body-parameters ...) inside handlers
```

## Core concepts

### conn — the value that flows

A `conn` is an immutable-ish struct holding everything about one request and
its in-progress response.

| accessor | meaning |
|---|---|
| `conn-method`  | `:get`, `:post`, ... |
| `conn-path`    | `"/api/users/42"` |
| `conn-params`  | plist: route params + query string |
| `conn-req`     | raw Clack env (plist) |
| `conn-status`  | response status (default `200`) |
| `conn-headers` | plist of response headers |
| `conn-body`    | response body (string, list, pathname, stream) |
| `conn-assigns` | plist for passing data between plugs |
| `conn-halted-p`| if `T`, the pipeline short-circuits |

Updaters return a fresh conn — don't mutate slots yourself:

```lisp
(put-status      conn 201)
(put-header      conn "content-type" "application/json")  ; names must be lowercase
(put-body        conn "{\"ok\":true}")
(put-resp        conn 200 "ok" '("content-type" "text/plain"))  ; combo
(get-resp-header conn "content-type")                     ; case-insensitive
(assign          conn :user-id "u-123")
(get-assign      conn :user-id)
(halt            conn)
```

### Request helpers

```lisp
(get-req-header conn "content-type")        ; case-insensitive lookup

(multiple-value-bind (body conn) (read-req-body conn)
  ;; body is a string or octet vector; reads from :raw-body once and
  ;; caches the result on the returned conn
  ...)
```

### Cookies

```lisp
;; set a cookie (HttpOnly + Path=/ by default; value is percent-encoded)
(put-resp-cookie conn "sid" "abc123"
                 :max-age 3600 :secure t :same-site :lax)

;; parse the request Cookie header into an alist
(multiple-value-bind (cookies conn) (fetch-req-cookies conn)
  (cdr (assoc "sid" cookies :test #'equal)))
```

Multiple `put-resp-cookie` calls produce multiple `Set-Cookie` headers
(they coexist). Using `put-header` with `"set-cookie"` raises — use
`put-resp-cookie` instead.

### Plugs and pipelines

A **plug** is any function `(conn) -> conn`. Compose with `pipeline`:

```lisp
(defun log-it (conn)
  (format t "~&~a ~a~%" (conn-method conn) (conn-path conn))
  conn)

(defun require-auth (conn)
  (if (get-assign conn :user-id)
      conn
      (halt (put-resp conn 401 "{\"error\":\"unauthorized\"}"))))

(defparameter *stack*
  (pipeline #'log-it #'require-auth 'hello))

(funcall *stack* (make-conn :method :get :path "/"))
```

`halt` short-circuits the rest of the pipeline. That's the entire protocol.

### defroutes / scope

Inside `defroutes` (and `scope`), any form starting with an HTTP-method keyword
is a route. `scope` prepends a path prefix and accumulates `:pipe-through`
plugs. Scopes nest freely.

```lisp
(defroutes *routes*
  (:get "/" 'home)
  (scope "/api" :pipe-through '(json-headers authenticate)
    (:get  "/users"      'users-index)
    (:get  "/users/:id"  'users-show)
    (:post "/users"      'users-create)
    (scope "/admin" :pipe-through '(require-admin)
      (:get "/stats" 'admin-stats)))
  (:get "/static/*path" 'serve-static))   ; '*' globs remaining segments
```

If you'd rather build routes programmatically, the underlying `route` function
is still exported: `(route :get "/x" 'h :pipe-through '(p))` returns an entry
list you can splice into `make-router`.

`:name` binds one segment; `*name` binds all remaining segments as a list.
A glob must be the last segment of the pattern.

The router also handles HTTP method semantics correctly:

- **HEAD** falls back to the matching GET handler; the response body is stripped.
- **OPTIONS** on a matched path responds 204 with an `Allow` header.
- **405 Method Not Allowed** (with `Allow`) is returned when a path matches but
  no entry handles the request's method — not 404.

For `/api/admin/stats`, the effective pipeline becomes:

```
json-headers → authenticate → require-admin → admin-stats
```

Route params (`:id`) land in `conn-params` as a plist:

```lisp
(defun users-show (conn)
  (put-resp conn 200
            (format nil "{\"id\":\"~a\"}" (getf (conn-params conn) :id))))
```

### Mounting on Clack

```lisp
(defparameter *app* (to-clack-app *routes*))
(clack:clackup *app* :port 5000)
```

`to-clack-app` also accepts a single plug function, so you can wrap the router
with global middleware:

```lisp
(to-clack-app (pipeline #'log-it (clug::router-as-plug *routes*)))
```

---

## Example

See [`examples/hello.lisp`](examples/hello.lisp) for a minimal app, or
[`examples/api.lisp`](examples/api.lisp) for a REST API exercising
`:clug/parsers`, `:clug/errors`, and `:clug/session` end-to-end. To
run hello:

```sh
sbcl --load ~/quicklisp/setup.lisp --load examples/serve.lisp
```

Then in another shell:

```sh
curl localhost:5123/                                                 # 200
curl localhost:5123/api/users                                        # 401
curl -H "Authorization: Bearer x" localhost:5123/api/users           # 200
curl -H "Authorization: Bearer x" localhost:5123/api/users/42        # 200
curl -H "Authorization: Bearer x" localhost:5123/api/admin/stats     # 403
```

---

## Security defaults

clug applies Plug-style hygiene at the boundary so handlers can trust the
values they receive:

- **Path segments and query strings are percent-decoded.** `/files/a%2Fb`
  matches `/files/:name` with `:name = "a/b"` (the `%2F` stays inside the
  segment instead of being treated as a separator). `+` in query strings
  becomes space, and UTF-8 is decoded correctly. Malformed encodings yield
  empty params rather than crashing the app.
- **Response header names must be lowercase HTTP tokens (RFC 7230).**
  `put-header` raises on mixed case, matching Phoenix's strict behaviour
  and HTTP/2 requirements. Lookups stay simple and case-stable.
- **Response header values may not contain CR, LF, or NUL.** `put-header`
  raises, blocking response-splitting / header-injection attacks at the
  edge where clug controls the data.

`put-header` also rejects non-string names and values up front.

---

## Opt-in sub-systems

clug core stays free of JSON, error-handling, and session concerns.
Three sibling ASDF systems live in the same repo and add those pieces
when you want them — same `ql:quickload`, no extra git remote:

```lisp
(ql:quickload '(:clug :clug/parsers :clug/errors :clug/session))
```

### `clug/parsers` — JSON in/out

```lisp
;; request body
(json-body conn)                       ; -> hash-table | list | nil

;; response
(render-json  conn 200 (obj "ok" t "user" "alice"))
(render-error conn 400 "title required")

;; plug form: stash parsed JSON under (:json-body)
(pipeline 'parse-json 'create-user)
```

Backed by `yason` + `babel`. Pair `json-body` with
`with-error-catcher` — malformed JSON signals an error.

### `clug/errors` — conn-level 500 boundary

```lisp
(with-error-catcher (clug::router-as-plug *routes*)
                    :renderer (lambda (c e)
                                (render-error c 500 (format nil "~a" e))))
```

Place immediately around the router. Default renderer emits
`text/plain`; swap with `render-error` from `:clug/parsers` for JSON.

### `clug/session` — cookie-based session, no body parsing

```lisp
(get-session-value conn :user-id)
(put-session-value conn :user-id "u-123")
(clear-session     conn)             ; destroys server-side + expires cookie

(lack:builder
  (lambda (app) (with-session app :store (make-memory-store)))
  (to-clack-app ...))
```

Pluggable store via `store-load` / `store-save` / `store-delete`
generic functions; default is a thread-safe in-memory hash-table.

**Why not `lack-middleware-session`?** Its `extract-sid` calls
`lack/request:make-request`, which calls `http-body:parse` on every
request whose body has a parseable content-type. For JSON APIs that
means an entire `yason:parse` runs on every POST/PUT (perf tax), a
malformed `{` crashes the request before any handler-level rescue can
fire (DoS), and a 100 MB multipart upload is buffered into memory just
to read a cookie. `clug/session` reads the Cookie header directly and
never touches the body.

## Composing with Lack middleware

A clug app is a Clack/Lack app, so `lack:builder` wraps any middleware
around it. Cross-cutting concerns (sessions, static files, CSRF, gzip,
logging, dev error pages) live in Lack's middleware ecosystem — clug
deliberately doesn't reimplement them.

```lisp
(clack:clackup
  (lack:builder
    :accesslog
    :backtrace                                     ; dev pretty errors
    (:static :path "/public/" :root #P"public/")
    :session                                       ; in-memory store by default
    (to-clack-app *routes*))
  :port 5000)
```

Inside a handler, middleware-supplied values are reachable via `conn-req`:

```lisp
(defun me (conn)
  (let* ((session (getf (conn-req conn) :lack.session))
         (uid     (and session (gethash :user-id session))))
    (put-resp conn 200 (or uid "anonymous"))))
```

Middleware shipped with Lack that pairs naturally with clug:

| middleware | role |
|---|---|
| `lack-middleware-session` | session + cookie wiring (`lack-session-store-dbi`, `-redis` available) |
| `lack-middleware-static` | serve a directory of static files |
| `lack-middleware-csrf` | CSRF token validation |
| `lack-middleware-accesslog` | request logging |
| `lack-middleware-backtrace` | dev-mode error pages with stack trace |
| `lack-middleware-mount` | mount a sub-app at a prefix (Plug's `forward`) |
| `lack-middleware-auth-basic` | HTTP Basic authentication |
| `lack-middleware-deflater` | gzip response compression |

## What clug intentionally does NOT do

To stay tiny and avoid reinventing solved problems, the following are
deliberately *out of scope*:

| not in clug | use this instead |
|---|---|
| sessions | `clug/session` (preferred — see above) or `lack-middleware-session` |
| static file serving | `lack-middleware-static`, `lack-app-file`, `lack-app-directory` |
| CSRF | `lack-middleware-csrf` |
| access logging | `lack-middleware-accesslog` |
| gzip compression | `lack-middleware-deflater` |
| pretty error pages | `lack-middleware-backtrace` |
| mounting sub-apps at a prefix | `lack-middleware-mount` |
| HTTP Basic auth | `lack-middleware-auth-basic` |
| WebSocket | `clack-socket` + `websocket-driver` |
| form / multipart body parsing | `lack.request:request-body-parameters` (uses `http-body`) |
| Accept-header content negotiation | `lack.request:request-accepts-p` |
| outbound HTTP requests | `dexador` |

JSON body parsing, error handling, and session are shipped as opt-in
sibling systems (`clug/parsers`, `clug/errors`, `clug/session`) — see
[Opt-in sub-systems](#opt-in-sub-systems) above.

## Source layout

| File | Responsibility |
|------|----------------|
| `src/conn.lisp`     | `conn` struct + pure updaters |
| `src/pipeline.lisp` | `pipeline`, `run-pipeline` — composition with halt short-circuit |
| `src/path.lisp`     | `compile-path`, `match-path` — `:param` style matching |
| `src/parsers.lisp`  | opt-in `:clug/parsers` — JSON in/out helpers |
| `src/errors.lisp`   | opt-in `:clug/errors` — conn-level 500 boundary |
| `src/session.lisp`  | opt-in `:clug/session` — cookie-based session middleware |
| `src/router.lisp`   | `route`, `scope`, `defroutes` — data-only route definitions |
| `src/clack.lisp`    | Clack env ↔ conn translation |

Each file is small and orthogonal. Pick the pieces you need; ignore the rest.

---

## Run the tests

```sh
sbcl --non-interactive --load ~/quicklisp/setup.lisp \
     --eval '(ql:quickload :clug/tests)' \
     --eval '(asdf:test-system :clug)'
```

---

## License

MIT
