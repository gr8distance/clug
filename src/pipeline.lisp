(in-package #:clug)

;;; A plug is just: (function (conn) -> conn).
;;; Pipeline = left-to-right composition with halt short-circuit.

(defun pipeline (&rest plugs)
  "Compose PLUGS into a single plug. Short-circuits when conn is halted."
  (let ((plugs (remove nil plugs)))
    (lambda (conn)
      (reduce (lambda (c plug)
                (if (conn-halted-p c) c (funcall plug c)))
              plugs
              :initial-value conn))))

(defun run-pipeline (conn &rest plugs)
  (funcall (apply #'pipeline plugs) conn))
