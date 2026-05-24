# pipeline

A pipeline is a left-to-right composition of plugs. Each plug
receives the conn from the previous plug and returns a new conn for
the next plug. If any plug calls `halt`, every subsequent plug in
the same pipeline is skipped.

That's the whole concept. The implementation is six lines.

---

## `(pipeline &rest PLUGS) → PLUG`

Combine zero or more plugs into a single plug.

```lisp
(defparameter *api*
  (pipeline #'parse-json
            #'require-auth
            #'handler))
```

- Returns a function `(conn) → conn` like any other plug. This
  composes — you can pipeline pipelines.
- `NIL` entries are dropped, which is handy for conditional plugs:

  ```lisp
  (pipeline #'always-on
            (when *enable-rate-limit* #'rate-limit)
            #'handler)
  ```

- Plugs are called in order. Once `(conn-halted-p c)` becomes true,
  the loop stops and `c` is returned as-is.

---

## `(run-pipeline conn &rest PLUGS) → conn`

The eager variant. Equivalent to:

```lisp
(funcall (apply #'pipeline plugs) conn)
```

Useful in one-off invocations:

```lisp
(run-pipeline conn
              #'parse-json
              #'authenticate
              #'handler)
```

Inside the router, this is what runs each matched route: the route's
`:pipe-through` plugs followed by the route's handler.

---

## `(halt conn) → conn'`

Sets the conn's `halted-p` flag. The next pipeline check will skip
remaining plugs.

The convention is "write the response, then halt." Calling `halt` on
a conn that has no status/body still produces an HTTP response — it
just falls back to defaults (`200`, empty body).

```lisp
(defun require-auth (conn)
  (if (get-assign conn :current-user)
      conn
      (halt (put-resp conn 401 "unauthorized"
                      (list "content-type" "text/plain")))))
```

A halted conn is returned to the caller as-is. The Clack adapter
will still send its status/headers/body — `halt` only stops *plug
execution*, not the HTTP response.

---

## What pipelines compose

Any function `(conn) → conn` is a plug. That includes:

- Bare functions you write
- Higher-order plugs (a function that returns a plug, e.g. for
  configurable middleware)
- Routers (a router-as-plug runs the matched route's pipeline
  internally)
- Other pipelines (composition is just function composition)

This means you can fold sub-pipelines into a single plug name and
pass them around:

```lisp
(defparameter *json-stack*
  (pipeline #'parse-json
            #'tag-request-id))

(defparameter *root*
  (pipeline *json-stack*
            (router-as-plug *routes*)))
```

---

## Halt semantics, in detail

`pipeline` checks `halted-p` between plugs, **not** during a plug's
own execution. That has two consequences worth knowing:

1. **A plug that calls another plug** is responsible for re-checking
   halt itself if it cares. The built-in `pipeline` handles this for
   you, so the common case "just" works.

2. **`halt` is sticky.** Once set, only an explicit unset would clear
   it — but there is no `unhalt`. If you find yourself wanting to
   un-halt, the design is probably wrong; consider whether your
   "halting" plug should instead return the conn unchanged (and let
   the next plug decide what to do).

---

## Why composition matters

Because plugs are plain functions:

- Testing is just calling them with a conn fixture (see [testing](./testing.md))
- Reusing logic across routes is just naming a pipeline
- Adding/removing middleware is a one-line edit
- The order of operations is visible in the source — no decorator
  stack to mentally trace

There's no plug registry, no resolver, no dependency injection. If
you can't find where a plug runs, `grep` for its name.

---

## Snippets

**Conditional middleware based on a flag:**

```lisp
(pipeline
  #'tag-request-id
  (and *enable-csrf* #'csrf-protect)
  (router-as-plug *routes*))
```

`(and FLAG PLUG)` evaluates to either the plug (when flag is true)
or `NIL` (which `pipeline` drops).

**A custom "decorator" plug:**

```lisp
(defun with-timing (plug)
  (lambda (conn)
    (let ((start (get-internal-real-time)))
      (let ((c (funcall plug conn)))
        (assign c :elapsed-ms
                (/ (- (get-internal-real-time) start)
                   (/ internal-time-units-per-second 1000.0)))))))

;; usage
(pipeline (with-timing #'handler))
```

**Halting based on the response so far:**

```lisp
(defun reject-if-error (conn)
  (if (>= (conn-status conn) 400)
      (halt conn)
      conn))
```

Useful for "stop running side-effect plugs if a previous plug
already produced an error response."
