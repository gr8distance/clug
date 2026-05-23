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
  (copy-with conn
             :headers (list* name value
                             (remove-from-plist-string (conn-headers conn) name))))

(defun remove-from-plist-string (plist key)
  "Remove KEY (string, case-insensitive) from header plist."
  (loop for (k v) on plist by #'cddr
        unless (string-equal k key)
          append (list k v)))

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
