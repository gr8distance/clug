(in-package #:clug)

;;; Path matching: "/users/:id/posts/:pid" -> segments with :param markers.
;;; Pure functions only; no regex.

(defun split-path (path)
  "Split PATH on '/', dropping empty segments. \"/\" -> NIL."
  (loop with start = 0
        with len = (length path)
        for i from 0 to len
        when (or (= i len) (char= (char path i) #\/))
          when (> i start) collect (subseq path start i) end
          and do (setf start (1+ i))))

(defun compile-path (pattern)
  "Return list of segments. Each segment is either a literal string
or (:param NAME) where NAME is a keyword."
  (mapcar (lambda (seg)
            (if (and (> (length seg) 0) (char= (char seg 0) #\:))
                (list :param (alexandria:make-keyword (string-upcase (subseq seg 1))))
                seg))
          (split-path pattern)))

(defun match-path (compiled path)
  "Return params plist if COMPILED matches PATH, else NIL.
Empty match (both root) returns T to distinguish from no-match."
  (let ((segs (split-path path)))
    (when (= (length segs) (length compiled))
      (let ((params nil)
            (ok t))
        (loop for c in compiled
              for s in segs
              while ok
              do (cond
                   ((stringp c)
                    (unless (string= c s) (setf ok nil)))
                   ((and (consp c) (eq (car c) :param))
                    (setf params (list* (cadr c) s params)))))
        (when ok
          (or params t))))))
