(in-package #:clug)

;;; X-Request-Id middleware. Equivalent of Phoenix's Plug.RequestId:
;;; assign a unique id per request for log correlation, distributed
;;; tracing, and "send us this id" debug requests.

(defparameter *request-id-header* "x-request-id")

(defparameter *request-id-max-length* 200
  "Maximum length of an incoming request ID we'll trust. Longer values
are ignored and a fresh ID is generated instead — keeps attacker-supplied
strings from bloating logs and downstream systems.")

(defun generate-request-id ()
  "Return a 16-character hex string. Uses /dev/urandom when available;
falls back to CL's RANDOM (non-cryptographic) otherwise."
  (let ((urandom (open "/dev/urandom" :element-type '(unsigned-byte 8)
                                       :direction :input
                                       :if-does-not-exist nil)))
    (unwind-protect
         (with-output-to-string (out)
           (loop repeat 8 do
             (format out "~2,'0x" (if urandom (read-byte urandom) (random 256)))))
      (when urandom (close urandom)))))

(defun request-id (conn)
  "Return the request ID assigned to CONN, or NIL if TAG-REQUEST-ID
hasn't run yet on this conn."
  (get-assign conn :request-id))

(defun tag-request-id (conn &key (header *request-id-header*)
                                  (generator #'generate-request-id))
  "Plug: stash a request ID on CONN under :request-id and mirror it on
the response under HEADER. If the incoming request carries HEADER and
its value is at most *REQUEST-ID-MAX-LENGTH* characters, trust it
(typical when fronted by a load balancer / API gateway that injects an
upstream ID). Otherwise generate a fresh one via GENERATOR.

Place near the top of the pipeline so subsequent plugs, handlers, and
error renderers can include the ID in their logs and JSON payloads."
  (let* ((incoming (get-req-header conn header))
         (rid (if (and incoming
                       (<= (length incoming) *request-id-max-length*))
                  incoming
                  (funcall generator))))
    (put-header (assign conn :request-id rid) header rid)))
