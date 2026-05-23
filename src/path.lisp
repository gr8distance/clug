(in-package #:clug)

;;; Path matching: "/users/:id/posts/:pid" -> segments with :param markers.
;;; Pure functions only; no regex.

(defun split-by (s ch &key omit-empty)
  "Split string S on CH. If OMIT-EMPTY, drop zero-length segments."
  (loop with start = 0
        with len = (length s)
        for i from 0 to len
        when (or (= i len) (char= (char s i) ch))
          when (or (not omit-empty) (> i start))
            collect (subseq s start i)
          end
          and do (setf start (1+ i))))

(defun split-path (path)
  "Split PATH on '/', dropping empty segments. \"/\" -> NIL."
  (split-by path #\/ :omit-empty t))

(defun compile-segment (seg)
  (cond
    ((and (> (length seg) 0) (char= (char seg 0) #\:))
     (list :param (alexandria:make-keyword (string-upcase (subseq seg 1)))))
    ((and (> (length seg) 0) (char= (char seg 0) #\*))
     (list :glob  (alexandria:make-keyword (string-upcase (subseq seg 1)))))
    (t seg)))

(defun compile-path (pattern)
  "Return a list of segments. Each segment is one of:
  - a literal string
  - (:param NAME)   — single-segment param via ':name'
  - (:glob  NAME)   — multi-segment catch-all via '*name', must be last"
  (let ((segs (mapcar #'compile-segment (split-path pattern))))
    (let ((glob-pos (position-if (lambda (s) (and (consp s) (eq (car s) :glob))) segs)))
      (when (and glob-pos (< glob-pos (1- (length segs))))
        (error "Glob segment must be the last segment in path pattern: ~s" pattern)))
    segs))

(defun match-path (compiled path)
  "Match COMPILED against PATH. Returns params plist, T (empty match), or NIL.
Segments are percent-decoded before matching, so '%2F' in a request stays
inside a single segment rather than acting as a separator. A trailing
(:glob NAME) captures remaining segments as a list."
  (let ((segs (mapcar (lambda (s) (quri:url-decode s :lenient t))
                      (split-path path))))
    (match-segs compiled segs nil)))

(defun match-segs (pattern segs acc)
  (cond
    ((and (null pattern) (null segs))
     (or acc t))
    ((null pattern) nil)
    ((and (consp (car pattern)) (eq (caar pattern) :glob))
     ;; Glob must be last; compile-path enforces this, but stay defensive.
     (when (null (cdr pattern))
       (list* (cadar pattern) segs acc)))
    ((null segs) nil)
    ((stringp (car pattern))
     (when (string= (car pattern) (car segs))
       (match-segs (cdr pattern) (cdr segs) acc)))
    ((and (consp (car pattern)) (eq (caar pattern) :param))
     (match-segs (cdr pattern) (cdr segs)
                 (list* (cadar pattern) (car segs) acc)))))
