# session

Cookie-based session middleware. A session is a hash-table of
arbitrary keyed data, keyed by a session ID stored in a cookie. The
middleware reads the cookie, looks up the data in a pluggable
**store**, runs your app with the session available on the conn, and
persists the data back to the store if you wrote to it.

Lives in the **opt-in `clug/session`** ASD system:

```lisp
(ql:quickload :clug/session)
```

Brings in `bordeaux-threads` (for store locking).

---

## Quick example

```lisp
(defparameter *store* (make-memory-store))

(defparameter *app*
  (with-session
   (to-clack-app routes)
   :store *store*
   :secure t        ; production HTTPS only
   :same-site :lax))

(clack:clackup *app* :port 5000)
```

```lisp
(defun login (conn)
  ;; ... authenticate user ...
  (put-session-value conn :user-id 1)
  (rotate-session-id conn)                ; defend against session fixation
  (put-resp conn 200 "logged in" '("content-type" "text/plain")))

(defun me (conn)
  (let ((uid (get-session-value conn :user-id)))
    (if uid
        (put-resp conn 200 (format nil "user ~a" uid))
        (put-resp conn 401 "not logged in"))))

(defun logout (conn)
  (clear-session conn)
  (put-resp conn 200 "bye"))
```

---

## How it's layered

`with-session` is a **Clack middleware**, not a clug plug. It wraps
the entire Clack app (the result of `to-clack-app`), not the
router. The reason: the Clack env is where the session state lives,
and the middleware needs to inspect it before and after the app
runs to decide what `Set-Cookie` to emit on the response.

This means session-aware code accesses the session through clug
conn helpers (`get-session-value`, `put-session-value`,
`clear-session`, `rotate-session-id`) which read from
`(conn-req conn)`'s session entries.

```
clack:clackup
   ↓
with-session          ← reads Cookie, loads session, persists on response
   ↓
to-clack-app
   ↓
clug pipeline / router / handlers   ← session helpers read/write here
```

If you wrap your clug app in other Clack middleware (e.g.
`lack-middleware-accesslog`), put `with-session` close to the app
— other middleware doesn't need to see the session state.

---

## `with-session`

```lisp
(with-session app &key store cookie-key path domain max-age
                       secure http-only same-site sid-generator)
  → CLACK-APP
```

| Key | Default | Meaning |
| --- | ------- | ------- |
| `:store`        | `(make-memory-store)` | session store; see below |
| `:cookie-key`   | `"clug.session"`      | name of the cookie that holds the SID |
| `:path`         | `"/"`                 | cookie path |
| `:domain`       | nil                   | cookie domain |
| `:max-age`      | `2592000` (30 days)   | cookie lifetime in seconds |
| `:secure`       | nil                   | set `t` in production HTTPS |
| `:http-only`    | `t`                   | block JS access — recommended for session cookies |
| `:same-site`    | `:lax`                | `:strict` / `:lax` / `:none` |
| `:sid-generator` | `#'generate-sid`     | thunk returning a fresh SID string |

What the middleware does on each request:

1. Parses the `Cookie` header.
2. Looks up `:cookie-key` to find the SID.
3. `store-load`s the session data (or makes an empty hash-table).
4. Stashes both on the Clack env under `:clug.session` and
   `:clug.session-state`.
5. Runs the inner app.
6. If the app called `put-session-value` (dirty) → `store-save` and
   emit `Set-Cookie` if the SID is new.
7. If the app called `clear-session` (destroy) → `store-delete` and
   emit an expiring `Set-Cookie`.
8. If the app called `rotate-session-id` (rotate) → generate a new
   SID, copy data, delete the old SID, emit `Set-Cookie`.

---

## Conn-level helpers

These read from / write to the session via the conn. They're
exported from the `clug` package; they work as long as
`with-session` wraps the app — otherwise they return `NIL` /
no-op.

### `(get-session-value conn KEY &optional DEFAULT) → VALUE`

Read a session key. Returns DEFAULT (or `NIL`) if absent.

### `(put-session-value conn KEY VALUE) → conn`

Store a value in the session. Flags the session as **dirty** so the
middleware persists it on response.

Note: this **mutates** the session hash-table in place (the table
itself is stored on the env, not on each conn copy). The return is
just `conn` for chaining.

### `(clear-session conn) → conn`

Mark the session for destruction. After the app returns, the
middleware:

- Deletes the SID from the store.
- Emits a `Set-Cookie` that immediately expires the cookie
  (`Max-Age=0`).

Use this for logout.

### `(rotate-session-id conn) → conn`

Defense against **session fixation**: generate a new SID, copy the
current session data to it, delete the old SID from the store, emit
a `Set-Cookie` with the new SID. Call this **immediately after a
privilege change** (login, password change, account elevation).

Why rotation matters: if an attacker can plant a known SID on a
target's browser before they log in (e.g. via a different page on
the same domain), the attacker would otherwise inherit the logged-in
session on the *fixed* SID. Rotating after login means the
post-privilege session lives under a fresh SID the attacker can't
predict.

### `(session-id conn) → STRING | NIL`

Return the current session ID, if any. Mostly useful in logging /
testing.

---

## The store protocol

A store is anything that responds to three generic functions:

```lisp
(defgeneric store-load   (store sid))      ; → hash-table or NIL
(defgeneric store-save   (store sid data)) ; persist
(defgeneric store-delete (store sid))      ; remove
```

### `memory-store` (default)

Thread-safe in-process hash table. Lost on restart, not shared
across worker processes. Fine for development and single-process
deployments.

```lisp
(make-memory-store)
```

### Implementing a custom store

Define methods on your store class:

```lisp
(defclass redis-store () ((conn :initarg :conn)))

(defmethod store-load ((s redis-store) sid)
  (let ((bytes (redis:get (redis-store-conn s) (key-for sid))))
    (when bytes (decode-session bytes))))

(defmethod store-save ((s redis-store) sid data)
  (redis:setex (redis-store-conn s) (key-for sid) (* 60 60 24 30)
               (encode-session data)))

(defmethod store-delete ((s redis-store) sid)
  (redis:del (redis-store-conn s) (key-for sid)))

;; usage:
(with-session app :store (make-instance 'redis-store :conn ...))
```

Contract:

- `store-load` must return either a hash-table (with `:test 'equal`)
  or `NIL`. The middleware treats `NIL` as "fresh session" and
  starts an empty hash-table.
- `store-save` should persist atomically. If you're sharing the
  store across processes, ensure your storage layer is consistent.
- `store-delete` should be idempotent — deleting an already-absent
  SID must not signal.

The store interface is intentionally tiny: three operations on
opaque hash-tables of data. The middleware handles cookie
serialization, SID generation, and dirty tracking — your store
only persists.

---

## SID generation

### `(generate-sid &optional (BYTES 16)) → STRING`

Return a hex-encoded session ID. Uses `/dev/urandom` when
available (Unix / macOS); falls back to `RANDOM` otherwise.

Default 16 bytes = 32 hex characters. That's plenty for
collision-resistance and brute-force resistance.

For platforms without `/dev/urandom` (or for deterministic tests),
override with `:sid-generator`:

```lisp
(with-session app :sid-generator (lambda () "fixed-test-sid"))
```

---

## Why not `lack-middleware-session`?

The standard Lack session middleware works fine for most apps, but
its `extract-sid` calls `lack/request:make-request`, which eagerly
invokes `http-body:parse` on every request whose body has a known
content type. For JSON APIs this is painful:

- **Performance**: yason runs the full body on every `POST/PUT`,
  even when the handler doesn't read it (or rejects with 401 before
  reading).
- **DoS surface**: a malformed `{` body crashes the session
  middleware before any handler-level rescue can fire.
- **Multipart uploads**: the entire upload is buffered + parsed just
  to read a cookie.

`clug/session` reads the `Cookie` header directly and never touches
the body. The session middleware is body-blind.

If your app doesn't have these problems and you'd rather use the
standard Lack stack, `lack-middleware-session` is a drop-in
alternative — clug doesn't require its own session.

---

## Snippets

**A logged-in plug:**

```lisp
(defun require-login (conn)
  (if (get-session-value conn :user-id)
      conn
      (halt (put-resp conn 302 nil
                      (list "location" "/login")))))

(defroutes routes
  (:get "/login"  'login-form)
  (:post "/login" 'login-submit)
  (scope "/app" :pipe-through (list #'require-login)
    (:get "/"           'dashboard)
    (:get "/settings"   'settings)))
```

**Storing flash messages across a redirect:**

```lisp
(defun set-flash (conn message)
  (put-session-value conn :flash message)
  conn)

(defun consume-flash (conn)
  (let ((msg (get-session-value conn :flash)))
    (when msg (put-session-value conn :flash nil))
    msg))
```

(A real flash needs the value to clear after the next request reads
it — the helper above does that.)

**Production cookie options:**

```lisp
(with-session app
              :store (make-instance 'redis-store ...)
              :secure t                 ; HTTPS only
              :same-site :strict        ; or :lax if cross-origin needed
              :max-age (* 60 60 24 7))  ; 7 days
```

**Forcing rotation on every privilege escalation:**

```lisp
(defun login (conn)
  (let ((user (authenticate ...)))
    (when user
      (-> conn
          (put-session-value :user-id (user-id user))
          (rotate-session-id)
          (put-resp 200 "welcome"
                    '("content-type" "text/plain"))))))
;; (substitute the thread-first macro with let* if you don't use one)
```
