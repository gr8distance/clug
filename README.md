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
(put-status   conn 201)
(put-header   conn "content-type" "application/json")  ; names must be lowercase
(put-body     conn "{\"ok\":true}")
(put-resp     conn 200 "ok" '("content-type" "text/plain"))  ; combo
(assign       conn :user-id "u-123")
(get-assign   conn :user-id)
(halt         conn)
```

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
      (:get "/stats" 'admin-stats))))
```

If you'd rather build routes programmatically, the underlying `route` function
is still exported: `(route :get "/x" 'h :pipe-through '(p))` returns an entry
list you can splice into `make-router`.

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

See [`examples/hello.lisp`](examples/hello.lisp) for a full app with auth,
nested scopes, and JSON responses. To run it:

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

## Source layout

| File | Responsibility |
|------|----------------|
| `src/conn.lisp`     | `conn` struct + pure updaters |
| `src/pipeline.lisp` | `pipeline`, `run-pipeline` — composition with halt short-circuit |
| `src/path.lisp`     | `compile-path`, `match-path` — `:param` style matching |
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
