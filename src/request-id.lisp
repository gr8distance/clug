(in-package #:clug)

;;; X-Request-Id middleware. Equivalent of Phoenix's Plug.RequestId:
;;; assign a unique id per request for log correlation, distributed
;;; tracing, and "send us this id" debug requests.

;;; --- shared CSPRNG-required failure mode ---------------------------------
;;;
;;; Both this file's GENERATE-REQUEST-ID and clug/session's GENERATE-SID
;;; need /dev/urandom. We define the condition here in core so the opt-in
;;; clug/session system can re-signal it without dragging a new
;;; condition class into the public surface.

(define-condition insecure-random-unavailable (error)
  ((reason :initarg :reason :reader insecure-random-reason))
  (:report (lambda (c stream)
             (format stream
                     "Cryptographic randomness source (/dev/urandom) is ~
                      unavailable: ~a.~@
                      clug refuses to fall back to a non-cryptographic ~
                      generator. On platforms without /dev/urandom, ~
                      supply a real CSPRNG-backed thunk via the :generator ~
                      / :sid-generator keyword arguments."
                     (insecure-random-reason c)))))

(defun %read-urandom-hex (bytes)
  "Read BYTES bytes from /dev/urandom and return them as a lowercase
hex string. Signals INSECURE-RANDOM-UNAVAILABLE when the device can't
be opened — never falls back to CL:RANDOM."
  (handler-case
      (with-open-file (in "/dev/urandom"
                          :element-type '(unsigned-byte 8)
                          :direction :input
                          :if-does-not-exist :error)
        (with-output-to-string (out)
          (loop repeat bytes do
            (format out "~2,'0x" (read-byte in)))))
    (file-error (e)
      (error 'insecure-random-unavailable :reason e))
    (stream-error (e)
      (error 'insecure-random-unavailable :reason e))))

(defparameter *request-id-header* "x-request-id")

(defparameter *request-id-max-length* 200
  "Maximum length of an incoming request ID we'll trust. Longer values
are ignored and a fresh ID is generated instead — keeps attacker-supplied
strings from bloating logs and downstream systems.")

(defparameter *request-id-allowed-charset*
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.+"
  "Characters allowed in an incoming X-Request-Id we'll trust. Anything
else — control chars, ANSI escape sequences, whitespace, header
delimiters — causes the upstream value to be rejected and a fresh ID
to be generated. The set covers what every load balancer / tracing
header standard actually emits (alphanumerics, dash, underscore, dot,
plus).")

(defun safe-request-id-p (s)
  "T iff S is a non-empty string, within the length cap, made entirely
of *REQUEST-ID-ALLOWED-CHARSET*. Used to gate trust of an upstream
header value before it lands in logs."
  (and (stringp s)
       (plusp (length s))
       (<= (length s) *request-id-max-length*)
       (every (lambda (c) (find c *request-id-allowed-charset*)) s)))

(defun generate-request-id ()
  "Return a 16-character hex request ID. Reads from /dev/urandom.

On platforms without /dev/urandom (Windows) this signals
INSECURE-RANDOM-UNAVAILABLE — the request ID is opaque so a
non-crypto fallback would be acceptable in isolation, but reusing
the same CSPRNG path as session IDs makes the contract simpler:
clug never silently downgrades randomness. Pass :generator to
TAG-REQUEST-ID on Windows to override."
  (%read-urandom-hex 8))

(defun request-id (conn)
  "Return the request ID assigned to CONN, or NIL if TAG-REQUEST-ID
hasn't run yet on this conn."
  (get-assign conn :request-id))

(defun tag-request-id (conn &key (header *request-id-header*)
                                  (generator #'generate-request-id))
  "Plug: stash a request ID on CONN under :request-id and mirror it on
the response under HEADER. If the incoming request carries HEADER and
its value passes SAFE-REQUEST-ID-P (length cap + safe charset), trust
it (typical when fronted by a load balancer / API gateway that
injects an upstream ID). Otherwise generate a fresh one via GENERATOR.

The charset gate keeps ANSI escape sequences, control chars, and
header-injection probes out of the value before it reaches logs.
Phoenix's Plug.RequestId leaves this to the log writer; clug shifts
the responsibility one layer earlier since most CL logging libraries
don't escape control chars by default.

Place near the top of the pipeline so subsequent plugs, handlers, and
error renderers can include the ID in their logs and JSON payloads."
  (let* ((incoming (get-req-header conn header))
         (rid (if (safe-request-id-p incoming)
                  incoming
                  (funcall generator))))
    (put-header (assign conn :request-id rid) header rid)))
