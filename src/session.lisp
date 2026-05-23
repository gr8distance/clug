(in-package #:clug)

;;; Self-contained cookie-based session middleware.
;;;
;;; Why not lack-middleware-session? Its EXTRACT-SID calls
;;; lack/request:make-request, which eagerly invokes http-body:parse on
;;; every request whose body has a known content-type. For JSON APIs this
;;; means:
;;;   - perf tax: yason runs the full body on every POST/PUT, even when
;;;     the handler doesn't read the body or returns 401 early
;;;   - DoS vector: a malformed `{` body crashes the session middleware
;;;     before any handler-level rescue can fire
;;;   - multipart: the entire upload is buffered+parsed just to read a
;;;     cookie
;;; This implementation reads the Cookie header directly and never
;;; touches the body.

;;; --- store protocol -------------------------------------------------------

(defgeneric store-load (store sid)
  (:documentation "Return the session hash-table for SID, or NIL when absent."))

(defgeneric store-save (store sid data)
  (:documentation "Persist DATA (hash-table) under SID."))

(defgeneric store-delete (store sid)
  (:documentation "Remove SID's session from the store."))

;;; --- default in-memory store ----------------------------------------------

(defclass memory-store ()
  ((table :initform (make-hash-table :test 'equal) :reader memory-store-table)
   (lock  :initform (bordeaux-threads:make-lock "clug-session-store")
          :reader memory-store-lock))
  (:documentation "Thread-safe in-process session store. Loses data on
restart and doesn't share across worker processes — fine for dev and
single-process deployments; swap for a Redis/DB store in production."))

(defun make-memory-store () (make-instance 'memory-store))

(defmethod store-load ((store memory-store) sid)
  (bordeaux-threads:with-lock-held ((memory-store-lock store))
    (gethash sid (memory-store-table store))))

(defmethod store-save ((store memory-store) sid data)
  (bordeaux-threads:with-lock-held ((memory-store-lock store))
    (setf (gethash sid (memory-store-table store)) data)))

(defmethod store-delete ((store memory-store) sid)
  (bordeaux-threads:with-lock-held ((memory-store-lock store))
    (remhash sid (memory-store-table store))))

;;; --- SID generation -------------------------------------------------------

(defun generate-sid (&optional (bytes 16))
  "Return a hex-encoded session ID. Uses /dev/urandom when available;
falls back to CL's RANDOM (non-cryptographic) otherwise — Unix and macOS
get crypto-grade IDs out of the box, other platforms should bind a
custom generator via the :sid-generator key."
  (let ((urandom (open "/dev/urandom" :element-type '(unsigned-byte 8)
                                       :direction :input
                                       :if-does-not-exist nil)))
    (unwind-protect
         (with-output-to-string (out)
           (loop repeat bytes do
             (format out "~2,'0x" (if urandom (read-byte urandom) (random 256)))))
      (when urandom (close urandom)))))

;;; --- conn-level helpers ---------------------------------------------------

(defun get-session-value (conn key &optional default)
  (let ((sess (getf (conn-req conn) :clug.session)))
    (if (hash-table-p sess) (gethash key sess default) default)))

(defun put-session-value (conn key value)
  "Set KEY=VALUE in the session. Mutates the hash-table stored on the env
and flags the session for persistence on response."
  (let ((sess  (getf (conn-req conn) :clug.session))
        (state (getf (conn-req conn) :clug.session-state)))
    (when (hash-table-p sess)
      (setf (gethash key sess) value))
    (when state (setf (getf state :dirty) t)))
  conn)

(defun clear-session (conn)
  "Mark the session for destruction. The middleware will delete the
server-side data and expire the client cookie on response."
  (let ((state (getf (conn-req conn) :clug.session-state)))
    (when state (setf (getf state :destroy) t)))
  conn)

(defun session-id (conn)
  (getf (getf (conn-req conn) :clug.session-state) :sid))

;;; --- middleware -----------------------------------------------------------

(defparameter *default-session-cookie-key* "clug.session")

(defun add-set-cookie (response cookie-value)
  "Append a Set-Cookie header to a list-shaped Clack response. Streaming
responses (function-shaped) aren't supported yet — the middleware leaves
them untouched."
  (when (and (listp response) (= 3 (length response)))
    (destructuring-bind (status headers body) response
      (return-from add-set-cookie
        (list status (append headers (list "set-cookie" cookie-value)) body))))
  response)

(defun %expire-cookie-value (key path domain http-only secure same-site)
  (serialize-cookie key ""
                    :path path :domain domain
                    :max-age 0
                    :http-only http-only :secure secure
                    :same-site same-site))

(defun with-session (app &key (store (make-memory-store))
                              (cookie-key *default-session-cookie-key*)
                              (path "/")
                              domain
                              (max-age (* 60 60 24 30))   ; 30 days
                              secure
                              (http-only t)
                              (same-site :lax)
                              (sid-generator #'generate-sid))
  "Clack-level middleware: parse Cookie -> load session from STORE ->
stash on env -> run APP -> persist if dirty, Set-Cookie on new/destroy.

The session is accessible to clug handlers via GET-SESSION-VALUE /
PUT-SESSION-VALUE / CLEAR-SESSION."
  (lambda (env)
    (let* ((cookies   (parse-cookie-header
                       (and (hash-table-p (getf env :headers))
                            (gethash "cookie" (getf env :headers)))))
           (sid       (cdr (assoc cookie-key cookies :test #'equal)))
           (data      (or (and sid (store-load store sid))
                          (make-hash-table :test 'equal)))
           (state     (list :sid sid :dirty nil :destroy nil :original-sid sid))
           (response  (funcall app (list* :clug.session data
                                          :clug.session-state state
                                          env))))
      (cond
        ;; Destruction requested (logout).
        ((getf state :destroy)
         (when sid (store-delete store sid))
         (add-set-cookie response
                         (%expire-cookie-value cookie-key path domain
                                               http-only secure same-site)))
        ;; Dirty: persist; if SID is new, emit Set-Cookie.
        ((getf state :dirty)
         (let ((sid (or sid (funcall sid-generator))))
           (store-save store sid data)
           (if (getf state :original-sid)
               response
               (add-set-cookie response
                               (serialize-cookie cookie-key sid
                                                 :path path :domain domain
                                                 :max-age max-age
                                                 :http-only http-only
                                                 :secure secure
                                                 :same-site same-site)))))
        (t response)))))
