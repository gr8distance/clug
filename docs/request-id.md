# request-id

A small plug that stamps each request with a unique ID and mirrors
it back on the response. The ID is available to every downstream
plug, your handler, and your error renderer — so logs from a single
request can be correlated across layers, and clients can ask "what
went wrong with request `abc123`?" and you can find it in the log.

This lives in **clug core** (no opt-in load needed).

---

## Quick example

```lisp
(defparameter *app*
  (to-clack-app
   (pipeline #'tag-request-id
             (router-as-plug routes))))

;; in a handler:
(defun home (conn)
  (format t "[~a] serving home~%" (request-id conn))
  (put-resp conn 200 "ok"
            (list "content-type" "text/plain")))
```

The response will carry `X-Request-Id: <id>`. If the request already
had one (e.g. forwarded from an upstream load balancer), that value
is preserved.

---

## `(tag-request-id conn &key header generator) → conn'`

Plug. Stash a request ID on the conn under `:request-id` (an assign)
and mirror it on the response under HEADER.

Behavior:

1. Read the incoming `header` value (default `"x-request-id"`).
2. If present and ≤ `*request-id-max-length*` characters, **trust
   it** — useful when fronted by a load balancer / API gateway that
   injects an upstream ID.
3. Otherwise generate a fresh one via GENERATOR (default
   `generate-request-id`).
4. Set the response header to the resulting ID.

Parameters:

| Key | Default | Notes |
| --- | ------- | ----- |
| `:header`    | `*request-id-header*` (`"x-request-id"`) | the header name to read and write |
| `:generator` | `#'generate-request-id` | thunk returning a string ID |

Place this **near the top of the pipeline** so subsequent plugs,
handlers, and error renderers can include the ID in their logs and
JSON payloads.

---

## `(request-id conn) → STRING | NIL`

Return the request ID assigned to CONN by `tag-request-id`. `NIL`
if the plug hasn't run yet — useful for cautiously logging from
plugs that might run before or after the ID is tagged.

---

## `(generate-request-id) → STRING`

Return a 16-character lowercase hex string. Uses `/dev/urandom` when
available; falls back to CL's `RANDOM` (non-cryptographic) on
platforms that don't have it.

The ID is just an opaque identifier; it doesn't need cryptographic
strength for correlation purposes, but the `/dev/urandom` source
gives you collision-resistance for free on Unix-like systems.

---

## Tunables

### `*request-id-header*`

The header name read from the request and written on the response.
Default `"x-request-id"`.

Change it if you've standardised on a different header — e.g.
`"x-amzn-trace-id"` when running behind AWS load balancers, or
`"x-correlation-id"` for some Java-shop conventions:

```lisp
(setf *request-id-header* "x-correlation-id")
```

### `*request-id-max-length*`

Default `200`. Incoming IDs longer than this are **rejected** and a
fresh one is generated instead.

This keeps attacker-supplied IDs from bloating logs and downstream
systems — a malicious client setting
`X-Request-Id: <megabyte of garbage>` would otherwise contaminate
every log line for that request.

---

## Snippets

**Including the request ID in a JSON 500:**

```lisp
(defun json-500 (conn condition)
  (render-json conn 500
               (obj "error" "internal_server_error"
                    "request_id" (or (request-id conn) "")
                    "detail" (princ-to-string condition))))

(defparameter *app*
  (to-clack-app
   (pipeline #'tag-request-id
             (with-error-catcher
              (router-as-plug routes)
              :renderer #'json-500))))
```

**Logging the ID alongside the path:**

```lisp
(defun log-request (conn)
  (format t "[~a] ~a ~a~%"
          (request-id conn)
          (string-upcase (symbol-name (conn-method conn)))
          (conn-path conn))
  conn)

(pipeline #'tag-request-id
          #'log-request
          (router-as-plug routes))
```

**Custom generator for deterministic tests:**

```lisp
(let ((counter 0))
  (defun test-generator ()
    (format nil "test-~a" (incf counter))))

;; in a test:
(let ((c (tag-request-id (make-conn) :generator #'test-generator)))
  (is (equal "test-1" (request-id c))))
```

---

## Why bother

Without correlation IDs, debugging a multi-service request means
guessing which log lines belong together by timestamp. With one, you
grep for the ID and every line involved with that request — handler,
DB layer, mailer, downstream HTTP calls — surfaces.

It costs one hex string per request. Add it.
