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
            (list "Content-Type" "text/plain")))

(defroutes *routes*
  (route :get "/" 'hello))

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
(put-header   conn "Content-Type" "application/json")
(put-body     conn "{\"ok\":true}")
(put-resp     conn 200 "ok" '("Content-Type" "text/plain"))  ; combo
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

### route / scope / defroutes

`route` and `scope` are plain functions returning route-entry lists. `scope`
prepends a path prefix and concatenates `:pipe-through` plugs. Scopes nest
freely.

```lisp
(defroutes *routes*
  (route :get "/"                       'home)
  (scope "/api" :pipe-through '(json-headers authenticate)
    (route :get  "/users"      'users-index)
    (route :get  "/users/:id"  'users-show)
    (route :post "/users"      'users-create)
    (scope "/admin" :pipe-through '(require-admin)
      (route :get "/stats" 'admin-stats))))
```

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
