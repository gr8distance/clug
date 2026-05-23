(in-package #:clug)

;;; Error-handling helpers. Conn-level catcher only for now; env-level
;;; shield (for errors raised inside Lack middleware below clug) will
;;; arrive in a follow-up.

(defun default-error-renderer (conn condition)
  (put-resp conn 500
            (format nil "Internal Server Error: ~a" condition)
            '("content-type" "text/plain; charset=utf-8")))

(defun with-error-catcher (plug &key (renderer #'default-error-renderer))
  "Wrap PLUG so any unhandled error during the call becomes a 500
response rather than crashing the request. RENDERER receives (conn
condition) and must return a conn — pass RENDER-ERROR from
:clug/parsers to get JSON 500s.

Place this immediately outside the router (or any plug whose handlers
might error)."
  (lambda (conn)
    (handler-case (funcall plug conn)
      (error (e) (funcall renderer conn e)))))
