(in-package #:clug)

;;; Conn: an immutable-ish value flowing through the pipeline.
;;; All updaters return a fresh conn — never mutate in user code.

(defstruct conn
  (method   :get   :type keyword)
  (path     "/"    :type string)
  (params   nil    :type list)   ; plist: route params + query
  (req      nil)                  ; raw Clack env (plist)
  (status   200    :type integer)
  (headers  nil    :type list)   ; plist
  (body     nil)                  ; string | list of strings | pathname | stream
  (halted-p nil    :type boolean)
  (assigns  nil    :type list))  ; plist for user data passed between plugs

(defun copy-with (conn &rest overrides)
  "Return a copy of CONN with slot overrides applied (plist of :slot value)."
  (let ((c (copy-conn conn)))
    (loop for (slot val) on overrides by #'cddr do
      (ecase slot
        (:method   (setf (conn-method c) val))
        (:path     (setf (conn-path c) val))
        (:params   (setf (conn-params c) val))
        (:req      (setf (conn-req c) val))
        (:status   (setf (conn-status c) val))
        (:headers  (setf (conn-headers c) val))
        (:body     (setf (conn-body c) val))
        (:halted-p (setf (conn-halted-p c) val))
        (:assigns  (setf (conn-assigns c) val))))
    c))

(defun put-status (conn status)
  (copy-with conn :status status))

(defun valid-header-name-p (s)
  "RFC 7230 token, restricted to lowercase. Matches Plug's contract:
header names are case-sensitively lowercase so downstream HTTP/2 frames
and case-insensitive lookups stay consistent."
  (and (stringp s)
       (> (length s) 0)
       (every (lambda (c)
                (or (and (char<= #\a c) (char<= c #\z))
                    (and (char<= #\0 c) (char<= c #\9))
                    (find c "!#$%&'*+-.^_`|~")))
              s)))

(defun valid-header-value-p (s)
  "Reject CR, LF, NUL — these enable response splitting / header injection."
  (and (stringp s)
       (not (find-if (lambda (c)
                       (or (char= c #\Return)
                           (char= c #\Newline)
                           (char= c #\Nul)))
                     s))))

(defun put-header (conn name value)
  (unless (valid-header-name-p name)
    (error "Invalid header name ~s — must be a non-empty lowercase HTTP token (RFC 7230)"
           name))
  (unless (valid-header-value-p value)
    (error "Invalid header value ~s — must be a string with no CR, LF, or NUL"
           value))
  (when (string= name "set-cookie")
    (error "Use PUT-RESP-COOKIE instead of PUT-HEADER for set-cookie."))
  (copy-with conn
             :headers (list* name value
                             (remove-from-plist-string (conn-headers conn) name))))

(defun remove-from-plist-string (plist key)
  "Remove KEY (string, case-insensitive) from header plist."
  (loop for (k v) on plist by #'cddr
        unless (string-equal k key)
          append (list k v)))

(defun get-resp-header (conn name)
  "Return the response header NAME, or NIL. Case-insensitive.
Use this rather than GETF — CL's GETF compares with EQ, which is
unreliable for string keys across compilation units."
  (loop for (k v) on (conn-headers conn) by #'cddr
        when (string-equal k name) return v))

(defun put-body (conn body)
  (copy-with conn :body body))

(defun put-resp (conn status body &optional headers)
  (let ((c (put-body (put-status conn status) body)))
    (loop for (k v) on headers by #'cddr
          do (setf c (put-header c k v)))
    c))

(defun assign (conn key value)
  (copy-with conn
             :assigns (list* key value
                             (alexandria:remove-from-plist (conn-assigns conn) key))))

(defun get-assign (conn key &optional default)
  (getf (conn-assigns conn) key default))

(defun merge-params (conn new-params)
  (copy-with conn :params (append new-params (conn-params conn))))

(defun halt (conn)
  (copy-with conn :halted-p t))

;;; --- request helpers ---

(defun get-req-header (conn name)
  "Return request header NAME (case-insensitive lookup), or NIL.
Assumes Clack adapter delivers env's :headers as a hash-table keyed by
lowercase strings — the standard Lack/Clack convention."
  (let ((headers (getf (conn-req conn) :headers)))
    (when (hash-table-p headers)
      (gethash (string-downcase name) headers))))

(defun read-req-body (conn)
  "Read the raw request body once. Returns (values body conn) where the
result is cached on the returned conn under :%req-body. BODY is a string
(if the adapter handed us one), an octet vector, or NIL."
  (let ((cached (get-assign conn :%req-body 'not-cached)))
    (if (not (eq cached 'not-cached))
        (values cached conn)
        (let* ((raw  (getf (conn-req conn) :raw-body))
               (body (cond
                       ((null raw)     nil)
                       ((stringp raw)  raw)
                       ((streamp raw)  (drain-octets raw))
                       (t              raw))))
          (values body (assign conn :%req-body body))))))

(defun drain-octets (stream)
  (let ((out (make-array 256 :element-type '(unsigned-byte 8)
                             :adjustable t :fill-pointer 0)))
    (loop for byte = (read-byte stream nil nil)
          while byte do (vector-push-extend byte out))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

;;; --- cookies ---

(defun fetch-req-cookies (conn)
  "Parse the request Cookie header into an alist of (string . string) pairs.
Returns (values cookies conn) with the result cached under :%req-cookies."
  (let ((cached (get-assign conn :%req-cookies 'not-cached)))
    (if (not (eq cached 'not-cached))
        (values cached conn)
        (let ((cookies (parse-cookie-header (get-req-header conn "cookie"))))
          (values cookies (assign conn :%req-cookies cookies))))))

(defun parse-cookie-header (s)
  (when s
    (loop for kv in (split-by s #\;)
          for trimmed = (string-trim '(#\Space #\Tab) kv)
          for eq-pos = (position #\= trimmed)
          when (and eq-pos (> eq-pos 0))
            collect (cons (subseq trimmed 0 eq-pos)
                          (quri:url-decode (subseq trimmed (1+ eq-pos)) :lenient t)))))

(defun valid-cookie-name-p (s)
  (and (stringp s)
       (> (length s) 0)
       (every (lambda (c)
                (and (char> c #\Space)
                     (char< c (code-char 127))
                     (not (find c "()<>@,;:\\\"/[]?={}"))))
              s)))

(defun put-resp-cookie (conn name value
                        &key (path "/") domain max-age expires
                             (http-only t) secure same-site)
  "Append a Set-Cookie response header. VALUE is percent-encoded.
SAME-SITE is :strict, :lax, or :none. Multiple cookies coexist as
separate Set-Cookie headers (bypassing put-header's dedup)."
  (unless (valid-cookie-name-p name)
    (error "Invalid cookie name ~s — must be a non-empty cookie token (RFC 6265)" name))
  (check-type value string)
  (copy-with conn
             :headers (list* "set-cookie"
                             (serialize-cookie name value
                                               :path path :domain domain
                                               :max-age max-age :expires expires
                                               :http-only http-only :secure secure
                                               :same-site same-site)
                             (conn-headers conn))))

(defun %check-cookie-attr (name value)
  "Reject CR/LF/NUL in a cookie attribute value. PUT-RESP-COOKIE
bypasses PUT-HEADER's dedup path on purpose, so attribute strings
have to be re-validated here — otherwise an attacker who can plant a
value into :path / :domain / :expires can inject extra Set-Cookie or
arbitrary response headers."
  (unless (valid-header-value-p value)
    (error "Invalid cookie ~a ~s — must be a string with no CR, LF, or NUL"
           name value)))

(defun serialize-cookie (name value &key path domain max-age expires
                                         http-only secure same-site)
  (when path     (%check-cookie-attr "path"    path))
  (when domain   (%check-cookie-attr "domain"  domain))
  (when expires  (%check-cookie-attr "expires" expires))
  (when max-age
    (check-type max-age (integer 0 *)
                "a non-negative integer (seconds) for cookie Max-Age"))
  (with-output-to-string (s)
    (format s "~a=~a" name (quri:url-encode value))
    (when path     (format s "; Path=~a" path))
    (when domain   (format s "; Domain=~a" domain))
    (when max-age  (format s "; Max-Age=~a" max-age))
    (when expires  (format s "; Expires=~a" expires))
    (when http-only (write-string "; HttpOnly" s))
    (when secure   (write-string "; Secure" s))
    (when same-site
      (format s "; SameSite=~a"
              (ecase same-site (:strict "Strict") (:lax "Lax") (:none "None"))))))
