# errors

A small wrapper that turns an unhandled error inside any plug into
a `500 Internal Server Error` response, instead of crashing the
request. Lives in the **opt-in `clug/errors`** ASD system:

```lisp
(ql:quickload :clug/errors)
```

The subsystem has no external dependencies beyond clug core.

---

## Quick example

```lisp
(defparameter *app*
  (to-clack-app
   (with-error-catcher
    (router-as-plug routes))))
```

A handler that signals an error now produces a 500 response. The
request thread doesn't die, the connection isn't dropped, and the
next request comes in cleanly.

---

## `(with-error-catcher PLUG &key renderer) → PLUG'`

Wrap PLUG so any condition signalled during its call is caught and
turned into a response by RENDERER.

Returns a new plug. PLUG is invoked with the conn; if it returns
normally, that conn is returned. If a `cl:error` (or subclass) is
signalled, RENDERER is called with `(conn condition)` and **its**
result is returned.

RENDERER must be a function `(conn condition) → conn`. The default
emits a 500 with the condition's printed form as the body, content
type `text/plain; charset=utf-8`:

```
500 Internal Server Error
content-type: text/plain; charset=utf-8

Internal Server Error: <condition>
```

The default is **fine for development**. For production, you'll
want a custom renderer — see the next section.

---

## `(default-error-renderer conn condition) → conn'`

The default renderer. Exposed as a function so you can compose with
it (e.g. log first, then delegate):

```lisp
(defun logged-renderer (conn condition)
  (format *error-output* "[error] ~a~%" condition)
  (default-error-renderer conn condition))

(with-error-catcher (router-as-plug routes)
                    :renderer #'logged-renderer)
```

---

## Where to place the catcher

Place `with-error-catcher` **immediately outside the router** — or
any plug whose downstream might error. The boundary you want is:

> Everything past this point should never crash the request.

```
incoming ─▶ tag-request-id ─▶ with-error-catcher
                                     │
                                     ▼
                              parse-json ─▶ router ─▶ handler
                              (errors here become 500s)
```

What this gives you:

- Plugs inside the wrapper can `error` freely; the response is
  always shaped (status + headers + body).
- Plugs **outside** the wrapper (e.g. `tag-request-id`, session
  middleware) are not protected — so they need to be robust on
  their own, or you wrap them too.
- Multiple catchers can nest. An inner catcher handles errors from
  its scope; an outer one is the safety net if the inner renderer
  itself signals.

---

## Custom renderers

The canonical JSON-API renderer pairs `clug/errors` with
`clug/parsers`:

```lisp
(ql:quickload '(:clug/parsers :clug/errors))

(defun json-500 (conn condition)
  (render-json conn 500
               (obj "error" "internal_server_error"
                    "request_id" (or (request-id conn) "")
                    "detail" (princ-to-string condition))))

(defparameter *app*
  (to-clack-app
   (pipeline
    #'tag-request-id
    (with-error-catcher
     (pipeline #'parse-json (router-as-plug routes))
     :renderer #'json-500))))
```

Notes:

- The renderer receives the **conn at the time of the error** —
  any plugs that ran successfully before the error already applied
  their changes (assigns, response headers etc.). You can read
  `request-id` because `tag-request-id` ran before the catcher.
- Errors signalled **inside the renderer itself** are not caught —
  they propagate. Keep renderers small and total.

### Distinguishing condition types

If you want different statuses for different error classes
(typically 400 for bad input vs 500 for unexpected errors):

```lisp
(defun shaped-renderer (conn condition)
  (cond
    ((typep condition 'yason:syntax-error)
     (render-error conn 400 "invalid JSON"))
    ((typep condition 'my-app:not-found-error)
     (render-error conn 404 "not_found"))
    (t
     (render-json conn 500
                  (obj "error" "internal_server_error"
                       "request_id" (or (request-id conn) ""))))))
```

The pattern: pre-match the condition types you control; fall back
to a generic 500 for everything else. Do NOT swallow the condition
silently — the fallback should still log it.

### Hiding implementation details

In production you usually don't want to leak the condition's
printed form to the client (which may include internal paths,
variable names, etc.). Log the full condition; respond with a
sanitised summary:

```lisp
(defun prod-renderer (conn condition)
  (log:error "[req=~a] ~a" (request-id conn) condition)
  (render-json conn 500
               (obj "error" "internal_server_error"
                    "request_id" (or (request-id conn) ""))))
```

Now the client gets only `request_id`; the operator sees the full
stack via logs.

---

## What this does NOT catch

`with-error-catcher` catches errors signalled during the plug call
on the conn it received. It does **not** catch:

- **Async errors** in background threads spawned by the handler —
  those run outside the plug call. Use a `handler-case` inside the
  thread body.
- **Errors in the Clack adapter** itself, below clug. Many adapters
  have their own error handling; configure those separately.
- **Errors signalled before** `with-error-catcher` runs. If
  `tag-request-id` blows up (it shouldn't, but), you get whatever
  the Clack handler does for unhandled signals — typically a 500
  with no body.

For the third case, wrap further out:

```lisp
(with-error-catcher
 (pipeline #'tag-request-id            ; protected now
           #'parse-json
           (router-as-plug routes))
 :renderer #'json-500)
```

But then `tag-request-id` errors lose the chance to log the
request ID (because it hasn't run yet). The usual layering puts
the request-ID plug outside the catcher and accepts that bug; it
matches the cost/benefit of the typical case.

---

## A planned future addition

The current catcher is conn-level only — it wraps a plug. A future
addition will wrap at the **Clack env level**, so errors raised by
middleware *below* clug (anywhere in the Lack stack) also become
500s. That's a separate concern from this page; the conn-level
catcher will remain regardless.
