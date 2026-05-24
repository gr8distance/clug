# clug

A small Clack routing library for Common Lisp built on one idea:

> **A plug is just a function `(conn) → conn`.**

Middleware, handlers, and the router itself all share that shape.
Compose them with `pipeline`, group them with `scope`, and mount the
result as a Clack app. Nothing else.

---

## Install

clug isn't on Quicklisp yet. Symlink a checkout into local-projects:

```sh
git clone https://github.com/gr8distance/clug.git ~/src/clug
ln -s ~/src/clug ~/quicklisp/local-projects/clug
```

```lisp
(ql:quickload :clug)            ; core
(ql:quickload :clug/parsers)    ; opt-in: JSON helpers
(ql:quickload :clug/errors)     ; opt-in: 500-renderer
(ql:quickload :clug/session)    ; opt-in: cookie session
```

You also need a Clack handler — e.g. `clack-handler-hunchentoot` or
`clack-handler-woo` — to actually serve requests.

---

## Quickstart

```lisp
(defpackage #:demo (:use #:cl #:clug))
(in-package #:demo)

(defun hello (conn)
  (put-resp conn 200 "hello, clug"
            (list "content-type" "text/plain")))

(defroutes routes
  (:get "/" 'hello))

(clack:clackup (to-clack-app routes) :port 5000)
```

```sh
$ curl localhost:5000/
hello, clug
```

That's a complete clug app. Everything else is composition of plugs
and routes — see the docs.

---

## Documentation

clug is documented as topic pages under [`docs/`](./docs/).

**Core**

- [Overview](./docs/overview.md) — the plug model, conn flow, mental model
- [conn](./docs/conn.md) — reading the request, writing the response, assigns, cookies
- [pipeline](./docs/pipeline.md) — composing plugs and halting
- [router](./docs/router.md) — `defroutes`, `scope`, path patterns, params

**Opt-in subsystems** (each is a separate ASD system)

- [request-id](./docs/request-id.md) — `x-request-id` correlation *(coming)*
- [parsers](./docs/parsers.md) — JSON request/response helpers *(coming)*
- [errors](./docs/errors.md) — 500-renderer for handler exceptions *(coming)*
- [session](./docs/session.md) — cookie-based session middleware *(coming)*

**Cross-cutting**

- [Cookbook](./docs/cookbook.md) — task-driven recipes *(coming)*
- [Testing](./docs/testing.md) — testing plugs and handlers *(coming)*

---

## What clug intentionally does NOT do

clug stays small by deferring to the existing Lack / Clack ecosystem
for solved problems. Reach for these when you need them:

| not in clug | use this instead |
|---|---|
| sessions                          | `clug/session` (preferred) or `lack-middleware-session` |
| static file serving               | `lack-middleware-static`, `lack-app-file`, `lack-app-directory` |
| CSRF                              | `lack-middleware-csrf` |
| access logging                    | `lack-middleware-accesslog` |
| gzip compression                  | `lack-middleware-deflater` |
| pretty error pages                | `lack-middleware-backtrace` |
| mounting sub-apps at a prefix     | `lack-middleware-mount` |
| HTTP Basic auth                   | `lack-middleware-auth-basic` |
| WebSocket                         | `clack-socket` + `websocket-driver` |
| form / multipart body parsing     | `lack.request:request-body-parameters` (uses `http-body`) |
| Accept-header content negotiation | `lack.request:request-accepts-p` |
| outbound HTTP requests            | `dexador` |

JSON, error handling, and session are shipped as opt-in sibling
systems (`clug/parsers`, `clug/errors`, `clug/session`) because they
share clug's plug-shape and benefit from coexisting with the conn
abstraction.

---

## Source layout

| File | Responsibility |
|------|----------------|
| `src/conn.lisp`       | `conn` struct + pure updaters |
| `src/pipeline.lisp`   | `pipeline`, `run-pipeline` — composition with halt short-circuit |
| `src/path.lisp`       | `compile-path`, `match-path` — path pattern matching |
| `src/router.lisp`     | `route`, `scope`, `defroutes` — data-only route definitions |
| `src/request-id.lisp` | `tag-request-id` — `x-request-id` correlation plug |
| `src/clack.lisp`      | Clack env ↔ conn translation |
| `src/parsers.lisp`    | opt-in `:clug/parsers` — JSON in/out helpers |
| `src/errors.lisp`     | opt-in `:clug/errors` — conn-level 500 boundary |
| `src/session.lisp`    | opt-in `:clug/session` — cookie-based session middleware |

Each file is small and orthogonal. Pick the pieces you need; ignore
the rest.

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
