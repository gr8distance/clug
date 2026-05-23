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

(defun put-header (conn name value)
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
  (let ((c (put-status conn status)))
    (setf c (put-body c body))
    (when headers
      (dolist (pair (loop for (k v) on headers by #'cddr collect (cons k v)))
        (setf c (put-header c (car pair) (cdr pair)))))
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
