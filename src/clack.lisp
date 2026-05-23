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
  (when (and qs (> (length qs) 0))
    (loop for pair in (split-by qs #\&)
          for eq-pos = (position #\= pair)
          when eq-pos
            append (list (alexandria:make-keyword
                          (string-upcase (subseq pair 0 eq-pos)))
                         (subseq pair (1+ eq-pos))))))

(defun split-by (s ch)
  (loop with start = 0
        with len = (length s)
        for i from 0 to len
        when (or (= i len) (char= (char s i) ch))
          collect (subseq s start i)
          and do (setf start (1+ i))))

(defun conn->clack (conn)
  "Convert conn to Clack response: (status headers body)."
  (let ((body (conn-body conn)))
    (list (conn-status conn)
          (or (conn-headers conn) (list :content-type "text/plain"))
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
