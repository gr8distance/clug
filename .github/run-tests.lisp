;;; CI test runner. Loads clug/tests and exits non-zero if any test failed.

(ql:quickload :clug/tests :silent t)

(let ((results (fiveam:run :clug)))
  (fiveam:explain! results)
  (unless (every (lambda (r) (typep r 'fiveam::test-passed)) results)
    (uiop:quit 1)))
