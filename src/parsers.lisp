(in-package #:clug)

;;; JSON request parsing / response rendering helpers.
;;;
;;; These live in the optional :clug/parsers system so the core stays
;;; free of yason / babel. Loading clug/parsers binds the symbols below;
;;; the symbols themselves are exported by package.lisp so unloaded
;;; callers get a clear "undefined function" error.

(defun body-string (conn)
  "Return the request body as a string. Handles both string and octet
vector inputs (Clack adapter dependent); octets are decoded as UTF-8.
Caches via READ-REQ-BODY so it's safe to call repeatedly."
  (multiple-value-bind (b _c) (read-req-body conn)
    (declare (ignore _c))
    (etypecase b
      (null nil)
      (string b)
      ((vector (unsigned-byte 8)) (babel:octets-to-string b :encoding :utf-8)))))

(defun json-body (conn)
  "Parse the request body as JSON. Returns a hash-table (object), list
(array), or scalar. NIL if body is empty. Signals an error on malformed
JSON — pair with WITH-ERROR-CATCHER from :clug/errors."
  (let ((s (body-string conn)))
    (when (and s (> (length s) 0))
      (yason:parse s))))

(defun obj (&rest plist)
  "Build a JSON-encodable hash-table from a plist of (string-key value).
Convenience for assembling response payloads without ceremony."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on plist by #'cddr do (setf (gethash k h) v))
    h))

(defun render-json (conn status data)
  "Serialise DATA (hash-table / list / scalar) to JSON with yason and
emit as conn body with content-type: application/json."
  (put-resp conn status
            (with-output-to-string (out) (yason:encode data out))
            '("content-type" "application/json")))

(defun render-error (conn status message)
  "Render an {\"error\": MESSAGE} JSON body with STATUS."
  (render-json conn status (obj "error" message)))

(defun parse-json (conn)
  "Plug: if Content-Type starts with application/json, parse the body
into a hash-table and stash under (:json-body). Otherwise pass through.
Errors propagate — wrap the router in WITH-ERROR-CATCHER."
  (let ((ct (get-req-header conn "content-type")))
    (if (and ct (search "application/json" ct))
        (assign conn :json-body (json-body conn))
        conn)))
