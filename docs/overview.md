# Overview

clug is built around one type and one shape.

The type is **`conn`** — an immutable-ish value that represents both
the incoming HTTP request and the outgoing response. It flows through
your code from start to finish.

The shape is **plug** — a function `(conn) → conn`. Every piece of
clug is a plug: a request handler is a plug, a middleware is a plug,
a router is a plug, even the entire application is a plug.

```
        conn  ──▶  plug  ──▶  conn  ──▶  plug  ──▶  conn ...
       (req)                                       (response)
```

Because everything is the same shape, composition is just function
composition. The library doesn't introduce special "middleware" or
"handler" concepts that work differently from each other.

---

## A conn carries the whole world

A `conn` is a struct holding both request and response state:

| Slot | Purpose |
| ---- | ------- |
| `:method`   | request method as a keyword (`:get`, `:post`, ...) |
| `:path`     | request path string (`"/users/42"`) |
| `:params`   | merged plist of route params + parsed query string |
| `:req`      | raw Clack environment (escape hatch for adapter-specific data) |
| `:status`   | response status, defaults to 200 |
| `:headers`  | response headers as a plist (`("content-type" "application/json" ...)`) |
| `:body`     | response body (string / list of strings / pathname / stream / octets) |
| `:halted-p` | true once a plug halts the pipeline; downstream plugs are skipped |
| `:assigns`  | plist for plugs to stash data for later plugs (think "request-scoped storage") |

Every clug helper that "modifies" a conn returns a **new** conn —
nothing mutates in user code. This means you can keep references to
older versions, fork pipelines, retry a plug with different inputs,
or write tests that snapshot the conn before/after a plug ran. The
struct itself is mutable internally (so the library can copy
efficiently), but the convention you write code against is "treat
conn as a value."

---

## What flows where

A typical request goes through three layers:

```
   incoming Clack env
          │
          ▼
   ┌─────────────────┐
   │  env → conn     │   (clug:to-clack-app at the entry point)
   └─────────────────┘
          │
          ▼
   ┌─────────────────┐
   │  middlewares    │   plugs that decorate, validate, short-circuit
   │  (session,      │   tag-request-id, parse-json, with-error-catcher, ...
   │   parsers,      │
   │   error catch)  │
   └─────────────────┘
          │
          ▼
   ┌─────────────────┐
   │  router         │   matches method + path → finds a route
   │                 │   prepends route's :pipe-through plugs
   │                 │   runs the handler at the tail
   └─────────────────┘
          │
          ▼
   ┌─────────────────┐
   │  conn → env     │   (response sent back via Clack)
   └─────────────────┘
```

The same `pipeline` primitive composes everything. Middlewares are
just plugs you place before the router; route-specific plugs are just
plugs you list in `:pipe-through`; handlers are plugs at the tail.

---

## The minimum viable app

A complete clug app, no opt-ins:

```lisp
(defpackage #:demo (:use #:cl #:clug))
(in-package #:demo)

(defun hello (conn)
  (put-resp conn 200 "hello"
            (list "content-type" "text/plain")))

(defroutes routes
  (:get "/" 'hello))

(clack:clackup (to-clack-app routes) :port 5000)
```

What this gives you:
- Path routing with method dispatch
- Auto-handling of `HEAD` (falls back to `GET`, body stripped),
  `OPTIONS` (returns `Allow` header), and 405 (with `Allow` listing
  supported methods)
- Path params (`/users/:id`) and wildcard segments (`/static/*rest`)
- Query string parsed into `conn-params`
- Headers that reject CRLF injection at write time
- Cookies parsed lazily on demand
- A `request-id` plug for log correlation (opt-in, see [request-id](./request-id.md))

Anything beyond that — JSON helpers, sessions, error catching — is
an opt-in subsystem documented under its own page.

---

## Reading order

If you're new:

1. **[conn](./conn.md)** — what's on the conn and how to read/write it
2. **[pipeline](./pipeline.md)** — composing plugs and short-circuiting
3. **[router](./router.md)** — `defroutes`, `scope`, path patterns

Opt-in subsystems (each is a separate ASD system; load with
`(ql:quickload :clug/<name>)`):

- **[parsers](./parsers.md)** — JSON request/response helpers
- **[errors](./errors.md)** — 500-renderer for handler exceptions
- **[session](./session.md)** — cookie-based session middleware

Cross-cutting topics:

- **[cookbook](./cookbook.md)** — task-driven recipes
- **[testing](./testing.md)** — testing plugs and handlers
