# router

The router matches an incoming `(method, path)` against a list of
routes, runs the matched route's pipeline (route plugs +
handler), and returns the resulting conn.

A router is itself a plug — you can put it anywhere in a pipeline.

---

## `defroutes`

The DSL macro that binds a router to a name.

```lisp
(defroutes routes
  (:get  "/"           'home)
  (:get  "/users"      'users-index)
  (:get  "/users/:id"  'users-show)
  (:post "/users"      'users-create))
```

Each body form is one of:

| Form | Meaning |
| ---- | ------- |
| `(:method "path" 'handler)` | shorthand for `(route :method "path" 'handler)` |
| `(:method "path" 'handler :pipe-through ...)` | route with extra plugs in front of the handler |
| `(route :method "path" 'handler ...)` | the explicit form — same as above |
| `(scope "/prefix" :pipe-through ... ...)` | nested group |

`defroutes` expands into a `defparameter` that holds a router struct.
You use the result wherever a plug is expected — most commonly fed
through `to-clack-app`.

---

## `(route METHOD PATTERN HANDLER &key pipe-through) → ENTRIES`

Build a single route as a list of one entry. Use this directly when
you'd rather build the router programmatically:

```lisp
(make-router
 :entries
 (append (route :get  "/"      'home)
         (route :post "/login" 'login-handler
                :pipe-through (list #'parse-json))))
```

HANDLER may be a function or a symbol naming a function. Symbols
resolve at request time, which means you can redefine the handler in
the REPL and the next request picks up the change.

PIPE-THROUGH is a list of plugs (functions or symbols) inserted
before the handler. The order is: pipe-through plugs in order, then
the handler.

---

## Path patterns

Patterns are split on `/` into segments. Each segment is one of:

| Segment | Behavior | Example |
| ------- | -------- | ------- |
| literal text  | must match exactly             | `/users` |
| `:name`       | captures one segment as param  | `/users/:id` |
| `*name`       | catch-all: captures the rest   | `/static/*path` (must be last segment) |

Matching is **percent-decoded** before comparison — a request for
`/users/foo%2Fbar` does not split the encoded `/`; it captures the
whole decoded string `foo/bar` into the `:id` param. (This matches
the typical expectation for URL-safe identifier handling.)

A `*name` segment must appear at the end of the pattern. `compile-path`
signals an error if you put one in the middle.

Captured params land in `(conn-params c)` as keywords with the
segment name upcased:

```lisp
(defroutes routes
  (:get "/users/:id"          'show)
  (:get "/users/:id/posts/:p" 'post-show)
  (:get "/static/*rest"       'static))

;; in show:    (getf (conn-params conn) :id)
;; in post-show: (getf (conn-params conn) :id)  + :p
;; in static:  (getf (conn-params conn) :rest)  -> a list of segments
```

Glob params (`*name`) capture the **list** of remaining segments,
not a single joined string. Join with `(format nil "~{~a~^/~}" segs)`
if you need the original-looking path.

---

## Query strings

Query strings are parsed once when the conn is built from the Clack
env. Parsed pairs land in `(conn-params c)` alongside route params:

```
GET /search?q=foo&limit=10
```

```lisp
(getf (conn-params conn) :q)       ; -> "foo"
(getf (conn-params conn) :limit)   ; -> "10"
```

Values are percent-decoded; `+` is treated as space; UTF-8 aware.
Malformed query strings yield `NIL` rather than signalling.

If a route param and a query param have the same name, the **route
param wins** (route params are prepended to the plist, so `getf`
finds them first).

---

## `scope`

Group routes under a path prefix and a shared set of plugs.

```lisp
(defroutes routes
  (:get "/"        'home)
  (:get "/health"  'health)

  (scope "/api" :pipe-through (list #'parse-json #'tag-request-id)
    (:get  "/users"      'users-index)
    (:get  "/users/:id"  'users-show)
    (:post "/users"      'users-create)

    (scope "/admin" :pipe-through (list #'require-admin)
      (:get    "/users"          'admin-users)
      (:delete "/users/:id"      'admin-delete-user))))
```

What `scope` does:

- Prepends the prefix to every nested route's path.
- Prepends the `:pipe-through` plugs to every nested route's
  `:pipes` list — including routes inside deeper `scope`s.
- Nesting is unlimited. Plugs accumulate (outer first, inner next,
  handler last).

`:pipe-through` is **optional**. A bare `(scope "/prefix" ...)` just
prefixes paths without adding any plugs.

The argument to `:pipe-through` is a Lisp expression evaluated at
the time the scope runs (`defroutes` expansion time, when the router
is being assembled). Typical forms are:

```lisp
:pipe-through (list #'plug-a #'plug-b)              ; preferred
:pipe-through '(plug-a plug-b)                      ; symbols, resolved per call
```

Symbols are looked up via `symbol-function` at request time, so
redefining the function in the REPL takes effect immediately.

---

## Auto-handled methods

The router handles a few HTTP-specified behaviors for you so you
don't write them per-route:

### `HEAD` falls back to `GET`

If a `HEAD` request matches a route that only has `GET` defined,
the router runs the GET handler and strips the body when sending
the response. You typically don't define `HEAD` routes yourself.

### `OPTIONS` returns an `Allow` header

For any matched path, a request with method `OPTIONS` gets a `204
No Content` with an `Allow:` header listing the methods you've
defined for that path (plus `OPTIONS`, plus `HEAD` if `GET` is
defined). No handler runs.

### `405 Method Not Allowed`

If a path matches but no route covers the request method, the
router returns 405 with an `Allow:` header listing the supported
methods. This happens before any handler or pipe-through plug runs.

### `404 Not Found`

If no route's pattern matches the path, the router returns 404 with
`content-type: text/plain` and the body `"Not Found"`.

You can replace the 404 handler by setting `(router-not-found
router)` to your own plug:

```lisp
(setf (router-not-found routes)
      (lambda (conn)
        (put-resp conn 404 "{\"error\":\"not_found\"}"
                  (list "content-type" "application/json"))))
```

This is helpful for JSON APIs that want their 404s to match the rest
of the response format.

---

## Programmatic router assembly

If you'd rather not use `defroutes`, build the router directly:

```lisp
(defparameter *r*
  (make-router
   :entries (append
              (route :get  "/"           'home)
              (route :get  "/users/:id"  'show)
              (route :post "/users"      'create
                     :pipe-through (list #'parse-json)))
   :not-found #'my-404-plug))

;; later:
(add-route *r* (first (route :get "/health" 'health)))
```

`add-route` mutates the router struct — useful for plugin systems or
test fixtures. Production code usually defines all routes up front
with `defroutes`.

---

## Mounting

A router is a plug. There are two equivalent ways to mount it:

```lisp
;; (a) wrap into a Clack app explicitly
(clack:clackup (to-clack-app routes) :port 5000)

;; (b) pipeline it with middleware first
(clack:clackup
 (to-clack-app
  (pipeline #'tag-request-id
            (router-as-plug routes)))
 :port 5000)
```

`to-clack-app` accepts a router, a plug function, or a symbol; it
returns a Clack app `(lambda (env) ...)`. The Clack handler (e.g.
`clack-handler-hunchentoot`) takes it from there.

If you mount a pipeline with the router at the tail, the middleware
runs **once per request**, before route matching. If you put a plug
in `:pipe-through` on a `scope`, it runs **only for routes inside
that scope**, after route matching.

| Place | Runs |
| ----- | ---- |
| Pipeline before `router-as-plug` | every request, before routing |
| `scope :pipe-through` | every request that matches the scope, after routing |
| Route `:pipe-through` | every request that matches that specific route |

---

## Lookup order

Within a single path that has multiple methods defined, the first
matching route in declaration order wins. Across paths, all routes
are tried in order until one matches; there is no priority weighting
beyond the order you wrote them in.

This means:

- More specific routes should come before more general ones
  (`/users/me` before `/users/:id`).
- Catch-all globs (`*rest`) should come last in their scope —
  otherwise they'll swallow more specific routes that follow.

---

## Snippets

**Per-scope authentication:**

```lisp
(defroutes routes
  (:get  "/"             'home)
  (:get  "/login"        'login-form)
  (:post "/login"        'login-submit)

  (scope "/dashboard" :pipe-through (list #'require-auth)
    (:get "/"            'dashboard-home)
    (:get "/settings"    'dashboard-settings)))
```

**Programmatic mounting with a request-id plug:**

```lisp
(clack:clackup
 (to-clack-app
  (pipeline #'tag-request-id
            (router-as-plug routes)))
 :port 5000)
```

**A custom 404 that includes the request id:**

```lisp
(defun json-404 (conn)
  (put-resp conn 404
            (format nil "{\"error\":\"not_found\",\"request_id\":\"~a\"}"
                    (or (request-id conn) ""))
            (list "content-type" "application/json")))

(setf (router-not-found routes) #'json-404)
```

**Multiple methods on the same path:**

```lisp
(defroutes routes
  (:get    "/users/:id"  'users-show)
  (:patch  "/users/:id"  'users-update)
  (:delete "/users/:id"  'users-delete))
```

A request to `OPTIONS /users/42` returns `Allow: DELETE, GET, HEAD,
OPTIONS, PATCH` automatically.
