(ql:quickload :clack-handler-hunchentoot :silent t)
(ql:quickload :clug :silent t)
(load (merge-pathnames "hello.lisp" *load-pathname*))
(defparameter *handler*
  (clack:clackup (symbol-value (find-symbol "*APP*" "CLUG-EXAMPLE"))
                 :port 5123))
(format t "~&clug listening on http://localhost:5123~%")
(finish-output)
(sleep 60)
