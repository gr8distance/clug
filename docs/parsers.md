# parsers

JSON request and response helpers. Lives in the **opt-in
`clug/parsers`** ASD system — load it explicitly to use:

```lisp
(ql:quickload :clug/parsers)
```

The subsystem brings in `yason` (parser/encoder) and `babel`
(UTF-8 decoding for octet bodies). The core clug stays free of
these dependencies — only callers that touch JSON pay for them.

The exported symbols come from the main `clug` package; loading
`clug/parsers` just binds their function definitions.

---

## Quick example

```lisp
(defun create-user (conn)
  (let ((attrs (get-assign conn :json-body)))
    (cond
      ((not (hash-table-p attrs))
       (render-error conn 400 "bad JSON"))
      (t
       (let ((id (insert-user attrs)))
         (render-json conn 201 (obj "id" id)))))))

(defroutes routes
  (:post "/users" 'create-user :pipe-through (list #'parse-json)))
```

`parse-json` does the parsing as a middleware; the handler reads
`(get-assign conn :json-body)` and renders with `render-json`.

---

## Request side

### `(parse-json conn) → conn'`

Plug. If the request's `Content-Type` starts with
`application/json`, parse the body via `json-body` and stash the
result on the conn under `:json-body` (an assign). Other content
types pass through unchanged.

```lisp
(defroutes routes
  (:post "/api/users" 'users-create
         :pipe-through (list #'parse-json)))

(defun users-create (conn)
  (let ((body (get-assign conn :json-body)))   ; hash-table or nil
    ...))
```

Errors propagate. If `Content-Type` says JSON but the body is
malformed, `yason:parse` signals — wrap your router in
`with-error-catcher` (from `clug/errors`) to turn it into a 400/500
instead of crashing the request.

The body is cached via `read-req-body`, so calling `parse-json`
plus reading the raw body downstream is fine — the body is only
drained once.

### `(json-body conn) → HASH-TABLE | LIST | SCALAR | NIL`

Parse the request body as JSON immediately (no `Content-Type`
check). Returns:

| JSON shape | CL value |
| ---------- | -------- |
| object     | hash-table (string keys, `equal` test) |
| array      | list |
| string     | string |
| number     | number |
| `true` / `false` | `t` / `nil` (yason's choice) |
| `null`     | `nil` |
| empty body | `NIL` |

Signals an error on malformed JSON. Use this directly when you want
to parse JSON regardless of the Content-Type (e.g. handlers that
accept multiple formats).

### `(body-string conn) → STRING | NIL`

Return the request body as a string. Decodes octet vectors as
UTF-8. Cached via `read-req-body`, so safe to call from multiple
plugs.

```lisp
(defun show-body (conn)
  (put-resp conn 200 (or (body-string conn) "(no body)")
            (list "content-type" "text/plain")))
```

`NIL` if the body is empty.

---

## Response side

### `(render-json conn STATUS DATA) → conn'`

Serialise DATA to JSON via `yason:encode` and emit it as the
response body, with `Content-Type: application/json` and the given
STATUS.

DATA can be:

| Type | JSON output |
| ---- | ----------- |
| hash-table              | object |
| list                    | array |
| string                  | string |
| number                  | number |
| `t`                     | `true` |
| `nil`                   | `null` (treat as JSON null in yason) |

```lisp
(render-json conn 200 (obj "id" 1 "email" "alice@example.com"))
;; => 200, content-type: application/json, body: {"id":1,"email":"alice@example.com"}

(render-json conn 200 (list (obj "id" 1) (obj "id" 2)))
;; => 200, body: [{"id":1},{"id":2}]
```

The response body is always a string (encoded once at render time)
— no streaming. Fine for typical API payloads; if you're returning
megabytes of JSON, build the body yourself with `with-output-to-string`
and use `put-resp` directly.

### `(render-error conn STATUS MESSAGE) → conn'`

Shorthand for the canonical error shape:

```lisp
(render-error conn 400 "bad email")
;; equivalent to:
(render-json conn 400 (obj "error" "bad email"))
;; => body: {"error":"bad email"}
```

Use throughout your API for consistent error responses. Pair with
`with-error-catcher`'s `:renderer` argument to turn unhandled
exceptions into the same shape.

### `(obj &rest PLIST) → HASH-TABLE`

Build a JSON-encodable hash-table from a flat list of
`(string-key value ...)`. Convenience for assembling response
payloads inline.

```lisp
(obj "id" 1 "name" "alice")
;; => #<HASH-TABLE>
;; encodes to: {"id":1,"name":"alice"}
```

Keys must be **strings**, because yason's symbol policy is
configurable and accidentally encoding keyword symbols would
produce surprising output. The check is enforced at encode time,
not at `obj` time — you'll see the error from yason if you misuse it.

Nested objects are just nested `obj` calls:

```lisp
(obj "user" (obj "id" 1 "email" "alice@x")
     "meta" (obj "page" 1 "total" 100))
```

---

## Common pipeline shape

The canonical "JSON API" pipeline:

```lisp
(defparameter *app*
  (to-clack-app
   (pipeline
    #'tag-request-id
    (with-error-catcher
     (pipeline #'parse-json
               (router-as-plug routes))
     :renderer (lambda (conn condition)
                 (render-json conn 500
                              (obj "error" "internal_server_error"
                                   "request_id" (or (request-id conn) "")
                                   "detail" (princ-to-string condition))))))))
```

Order matters:

1. `tag-request-id` first — so the error renderer can include the ID.
2. `with-error-catcher` next — so JSON parsing failures are caught
   and rendered as JSON, not as plaintext stack traces.
3. `parse-json` inside the catcher — its errors become 500s shaped
   like the rest of the API.
4. The router last.

If you want to distinguish "bad JSON in request" (400) from "handler
threw" (500), check the condition type inside your renderer:

```lisp
:renderer
(lambda (conn condition)
  (cond
    ((typep condition 'yason:syntax-error)
     (render-error conn 400 "invalid JSON"))
    (t
     (render-json conn 500 (obj "error" "internal_server_error")))))
```

---

## Why these are opt-in

The main clug system has no JSON dependency. Most apps eventually
use JSON, but small services that serve only HTML or raw bytes get
to skip `yason` + `babel` entirely.

Loading `clug/parsers` is a one-liner once you decide you need it,
and the symbols (`json-body`, `render-json`, etc.) are pre-exported
from the `clug` package — so handler code reads the same whether
the subsystem is loaded or not.

If you forget to load it, the failure is an undefined-function
error at the call site, not a cryptic missing-system error.
