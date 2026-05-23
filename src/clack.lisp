(in-package #:clug)

;;; Boundary between Clack and clug. Pure translation, nothing else.

(defun env->conn (env)
  (make-conn
   :method  (getf env :request-method)
   :path    (or (getf env :path-info) "/")
   :req     env
   :params  (parse-query-string (getf env :query-string))
   :headers nil
   :body    nil))

(defun parse-query-string (qs)
  "Parse application/x-www-form-urlencoded query into a plist.
Percent-decoded, '+' treated as space, UTF-8 aware. Malformed input
yields NIL rather than signalling — bad clients shouldn't crash the app."
  (when (and qs (> (length qs) 0))
    (handler-case
        (loop for (k . v) in (quri:url-decode-params qs)
              append (list (alexandria:make-keyword (string-upcase k)) v))
      (error () nil))))

(defun conn->clack (conn)
  "Convert conn to Clack response: (status headers body)."
  (let ((body (conn-body conn)))
    (list (conn-status conn)
          (or (conn-headers conn) (list "content-type" "text/plain"))
          (etypecase body
            (null '(""))
            (string (list body))
            (cons body)
            (pathname body)))))

(defun to-clack-app (plug-or-router)
  "Adapt a plug (or router) to a Clack app: (lambda (env) ...)."
  (let ((plug (etypecase plug-or-router
                (function plug-or-router)
                (router (router-as-plug plug-or-router))
                (symbol (symbol-function plug-or-router)))))
    (lambda (env)
      (conn->clack (funcall plug (env->conn env))))))
