# conn

The `conn` is the value that flows through every plug. It holds both
the incoming request and the outgoing response. Every helper that
"modifies" the conn returns a **new** conn — treat it as a value, not
a place.

This page covers the full API for reading the request, writing the
response, and stashing per-request data.

---

## The struct

```lisp
(defstruct conn
  method     ; keyword: :get :post :put :patch :delete :head :options
  path       ; string: the request path, e.g. "/users/42"
  params     ; plist: route params + query string, merged
  req        ; the raw Clack env plist (escape hatch)
  status     ; integer: response status, defaults to 200
  headers    ; plist of (lowercase-string value ...): response headers
  body       ; string | list of strings | pathname | stream | octet vector
  halted-p   ; boolean: when t, the pipeline short-circuits
  assigns)   ; plist: per-request scratch space for plug-to-plug data
```

Slot accessors follow the Common Lisp `(conn-slot c)` convention. Use
them for one-shot reads; the helpers below cover the common patterns.

---

## Reading the request

### `(conn-method conn) → KEYWORD`

The HTTP method, normalised by the Clack adapter into a keyword like
`:get` or `:post`.

### `(conn-path conn) → STRING`

The request path. Always begins with `/`.

### `(conn-params conn) → PLIST`

A plist of merged route params + query string. The router appends
route params after a match; the query string is parsed at conn
construction.

Keys are keywords, upcased from the original names — `/users/:id`
exposes `(getf (conn-params c) :id)`. Query strings use the same
shape: `?page=2&sort=name` exposes `:page` and `:sort`.

Malformed query strings yield `NIL` rather than signalling — a bad
client should not crash the app.

### `(get-req-header conn NAME) → STRING | NIL`

Case-insensitive lookup against the request headers. NAME should be a
string; lookup downcases for you.

```lisp
(get-req-header conn "Content-Type")    ; -> "application/json"
(get-req-header conn "x-custom")        ; -> nil if absent
```

Assumes the Clack adapter delivers `(getf env :headers)` as a
hash-table keyed by lowercase strings. This is the standard
Lack/Clack convention; if your adapter doesn't follow it, normalise
in a middleware before reading headers downstream.

### `(read-req-body conn) → (values BODY conn')`

Read the raw request body. Returns two values: the body, and a new
conn with the body cached under the internal `:%req-body` key. The
first call drains the body stream; subsequent calls return the cached
value, so it's safe to use in multiple plugs.

```lisp
(multiple-value-bind (body c) (read-req-body conn)
  ;; body is the raw request body as a string or octet vector
  ;; c is the (cached) conn — use it downstream
  ...)
```

Body type depends on the adapter: strings if the adapter pre-decoded,
octet vectors otherwise. `NIL` if no body.

> ⚠️ **Request body size limits live in the Clack handler**, not
> here. `read-req-body` drains whatever the handler hands clug —
> if the handler accepted a 4 GB upload, this function will dutifully
> read 4 GB into memory. Configure the cap upstream:
>
> - **Hunchentoot**: set `hunchentoot:*hunchentoot-default-external-format*`
>   and the request-class's content-length limit.
> - **Woo**: pass `:body-buffer-limit` to `woo:run` (and reject
>   oversized bodies before they reach clug).
> - **Generic**: front clug with `lack-middleware-mount`-style
>   middleware that checks `:content-length` and short-circuits a 413.

### `(fetch-req-cookies conn) → (values ALIST conn')`

Parse the request `Cookie` header into an alist of
`(string . string)` pairs. Cached on the returned conn under
`:%req-cookies`, so subsequent calls are free.

```lisp
(multiple-value-bind (cookies c) (fetch-req-cookies conn)
  (let ((session-id (cdr (assoc "sid" cookies :test #'string=))))
    ...))
```

Values are percent-decoded (lenient — broken `%xx` sequences are
passed through rather than signalling).

### `(conn-req conn) → PLIST`

The raw Clack environment. Use as a last resort for adapter-specific
data not exposed by clug's helpers — anything you reach for here is
a hint that clug could surface it directly.

---

## Writing the response

All response writers return a new conn. Chain them with `let*`,
threading, or `pipeline`.

### `(put-status conn STATUS) → conn'`

Set the response status code.

```lisp
(put-status conn 404)
```

### `(put-header conn NAME VALUE) → conn'`

Add or replace a response header. NAME must be a **lowercase**
string matching RFC 7230's `token` grammar. VALUE must be a string
that contains no CR, LF, or NUL.

```lisp
(put-header conn "content-type" "application/json")
(put-header conn "cache-control" "no-store, max-age=0")
```

Both arguments are validated:

- Non-lowercase or non-token header names → `error`
- Header values containing CR / LF / NUL → `error`
  (response splitting / header injection defense)
- Calling with `name = "set-cookie"` → `error`
  (cookies have their own helper to avoid clobbering)

If a header with the same name already exists, it's replaced — clug
deduplicates on case-insensitive name. This matches the contract
most HTTP servers expect.

### `(put-body conn BODY) → conn'`

Set the response body. Accepted types:

| Type | Behavior |
| ---- | -------- |
| `string`           | sent as the response body |
| `list of strings`  | concatenated by the Clack adapter |
| `pathname`         | served as a file by the adapter |
| `stream`           | drained by the adapter |
| `(vector (unsigned-byte 8))` | sent as binary |
| `NIL`              | empty body |

### `(put-resp conn STATUS BODY &optional HEADERS) → conn'`

The "set everything in one go" helper. HEADERS is a plist; each
key/value pair is fed through `put-header` (so the same validations
apply).

```lisp
(put-resp conn 200 "ok"
          (list "content-type" "text/plain"))
```

### `(get-resp-header conn NAME) → STRING | NIL`

Case-insensitive lookup against the response headers. Use this rather
than `getf` — CL's `getf` compares with `eq`, which is unreliable
across compilation units for string keys.

### `(put-resp-cookie conn NAME VALUE &key path domain max-age expires http-only secure same-site)`
### `→ conn'`

Append a `Set-Cookie` header. The value is percent-encoded.

Defaults:

| Option | Default | Notes |
| ------ | ------- | ----- |
| `:path`        | `"/"`   | |
| `:domain`      | nil     | |
| `:max-age`     | nil     | seconds |
| `:expires`     | nil     | string, RFC-1123 format |
| `:http-only`   | `t`     | sets `HttpOnly` |
| `:secure`      | nil     | set to `t` in production HTTPS |
| `:same-site`   | nil     | `:strict`, `:lax`, or `:none` |

```lisp
(put-resp-cookie conn "sid" raw-session-id
                 :max-age (* 60 60 24 14)
                 :secure t
                 :same-site :lax)
```

Multiple `Set-Cookie` headers can coexist on one response — unlike
`put-header`, this helper does not dedup, so you can issue several
cookies in the same response.

NAME is validated against RFC 6265's cookie-token grammar; invalid
names signal an error.

---

## Assigns: per-request scratch space

`assigns` is a plist owned by you. Plugs use it to share data with
later plugs (and with handlers) without smuggling things through
dynamic variables or globals.

### `(assign conn KEY VALUE) → conn'`

Put VALUE under KEY in the conn's assigns. KEY should be a keyword.

```lisp
(defun load-current-user (conn)
  (let ((user (fetch-user-from-session-id ...)))
    (assign conn :current-user user)))
```

If KEY already exists, the new value replaces the old one.

### `(get-assign conn KEY &optional DEFAULT) → VALUE`

Read KEY from the assigns. Returns DEFAULT (or `NIL`) if missing.

```lisp
(get-assign conn :current-user)
```

### `(merge-params conn NEW-PARAMS) → conn'`

Prepend NEW-PARAMS to `conn-params`. The router uses this internally
to inject matched route params before running the handler. Useful in
custom middleware that wants to expose extracted values as if they
were route params.

---

## Halting the pipeline

### `(halt conn) → conn'`

Mark the conn as halted. The `pipeline` function checks
`conn-halted-p` between plugs and stops calling them once it's true.

```lisp
(defun require-auth (conn)
  (if (get-assign conn :current-user)
      conn
      (halt (put-resp conn 401 "unauthorized"
                      (list "content-type" "text/plain")))))
```

A halted conn still gets serialized into the HTTP response — `halt`
short-circuits **plug execution**, not the response itself. So the
canonical pattern is "write the response, then halt": you set the
status/body you want returned, *then* call `halt`, then the
remaining plugs don't run.

### `(conn-halted-p conn) → BOOLEAN`

Predicate. Mostly useful in tests or custom pipeline runners.

---

## Halting + writing in one shot

The common case is "respond with a status and halt." There's no
single-call helper for it because the explicit form reads clearly
enough:

```lisp
(halt (put-resp conn 403 "forbidden"
                (list "content-type" "text/plain")))
```

If you find yourself writing this many times, wrap it in a local
helper:

```lisp
(defun bail (conn status body)
  (halt (put-resp conn status body
                  (list "content-type" "text/plain"))))
```

The opt-in `clug/parsers` system ships a JSON-aware version,
`render-error`, that does this for JSON responses.

---

## Header conventions

clug enforces two rules at write time:

1. **Header names must be lowercase tokens.** This keeps lookups
   consistent and avoids the "is it `Content-Type` or `content-type`?"
   ambiguity downstream. HTTP/2 mandates lowercase anyway.
2. **Header values must not contain CR, LF, or NUL.** This is the
   classic response-splitting defense — a single bad header would
   otherwise let an attacker inject extra response headers or a fake
   body.

Both are checked by `put-header` and `put-resp`. Trying to bypass
them by hand-mutating the headers plist works mechanically but
defeats the safety property; don't.

---

## Cookie conventions

- `put-resp-cookie` is the **only** way to write cookies.
  `put-header` rejects `set-cookie` outright.
- `HttpOnly` defaults to `t` (prevents JS access; expected for
  session cookies).
- `Secure` and `SameSite` default to off — enable them per
  deployment. For session cookies in production HTTPS, set
  `:secure t :same-site :lax` at minimum.
- Cookie values are percent-encoded automatically. Read-back via
  `fetch-req-cookies` decodes them.

---

## Snippets

**Render a string with a custom header:**

```lisp
(defun handler (conn)
  (put-resp conn 200 "ok"
            (list "content-type" "text/plain"
                  "x-served-by" "demo-1")))
```

**Read JSON body without the opt-in subsystem:**

```lisp
(defun raw-json (conn)
  (multiple-value-bind (body c) (read-req-body conn)
    (let ((parsed (yason:parse body)))
      ...)))
```

(In practice, prefer `clug/parsers` and `(json-body conn)`.)

**Set a session cookie and 302:**

```lisp
(defun redirect-with-session (conn sid)
  (-> conn
      (put-status _ 302)
      (put-header _ "location" "/dashboard")
      (put-resp-cookie _ "sid" sid :secure t :same-site :lax)))
;; (substitute the thread-first macro with `let*` if you don't use one)
```

**Stash data for a later plug:**

```lisp
(defun load-user (conn)
  (assign conn :current-user (fetch-user ...)))

(defun show-greeting (conn)
  (let ((u (get-assign conn :current-user)))
    (put-resp conn 200 (format nil "hi ~a" (user-name u))
              (list "content-type" "text/plain"))))
```
