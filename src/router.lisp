(in-package #:clug)

;;; Routes are normalized data:
;;;   (:method KEYWORD :pattern STRING :compiled LIST :handler FN :pipes LIST)
;;;
;;; `route' and `scope' are plain functions returning lists of such plists,
;;; so `defroutes' is just data assembly.

(defun route (method pattern handler &key pipe-through)
  "Build a single route entry. METHOD is a keyword (:get :post ...).
HANDLER is a symbol or function — a plug. PIPE-THROUGH is a list of plugs."
  (list (list :method method
              :pattern pattern
              :compiled (compile-path pattern)
              :handler handler
              :pipes (alexandria:ensure-list pipe-through))))

(defun split-pipe-through (forms)
  "Strip a leading :pipe-through pair from FORMS.
Returns (values pipes-form rest). Used at both macroexpansion and runtime."
  (if (eq (first forms) :pipe-through)
      (values (second forms) (cddr forms))
      (values nil forms)))

(defun %scope (prefix &rest args)
  "Runtime form of SCOPE. Takes already-built entry lists as children."
  (multiple-value-bind (pipes-value children) (split-pipe-through args)
    (let ((pipes (alexandria:ensure-list pipes-value))
          (prefix-segs (compile-path prefix)))
      (loop for child-list in children
            append (loop for entry in child-list
                         collect (extend-entry entry prefix-segs prefix pipes))))))

(defun rewrite-route-form (form)
  "Rewrite (:method path handler ...) into (route :method path handler ...).
Leave (scope ...) calls alone — the SCOPE macro handles its own body."
  (cond
    ((atom form) form)
    ((keywordp (car form))
     (cons 'route form))
    (t form)))

(defmacro scope (prefix &rest rest)
  "Group routes under PREFIX with optional :pipe-through plugs.

  (scope \"/api\" :pipe-through '(auth)
    (:get \"/users\"     'users-index)
    (:get \"/users/:id\" 'users-show)
    (scope \"/admin\" :pipe-through '(require-admin)
      (:get \"/stats\" 'admin-stats)))"
  (multiple-value-bind (pipes children) (split-pipe-through rest)
    `(%scope ,prefix
             ,@(when (eq (first rest) :pipe-through) `(:pipe-through ,pipes))
             ,@(mapcar #'rewrite-route-form children))))

(defun extend-entry (entry prefix-segs prefix pipes)
  (list :method   (getf entry :method)
        :pattern  (concatenate 'string prefix (getf entry :pattern))
        :compiled (append prefix-segs (getf entry :compiled))
        :handler  (getf entry :handler)
        :pipes    (append pipes (getf entry :pipes))))

;;; Router: list of compiled entries + miss handler.

(defstruct router
  (entries nil :type list)
  (not-found #'default-not-found :type (or function symbol)))

(defun default-not-found (conn)
  (put-resp conn 404 "Not Found"
            (list "content-type" "text/plain")))

(defun add-route (router entry)
  (setf (router-entries router)
        (append (router-entries router) (list entry)))
  router)

(defun path-matches (entries path)
  "Return list of (entry . params) for every entry whose pattern matches PATH."
  (loop for e in entries
        for m = (match-path (getf e :compiled) path)
        when m
          collect (cons e (if (eq m t) nil m))))

(defun allowed-methods (matches)
  "Methods of MATCHES, plus OPTIONS and (if GET is present) HEAD."
  (let ((ms (delete-duplicates (mapcar (lambda (p) (getf (car p) :method)) matches))))
    (setf ms (adjoin :options ms))
    (when (member :get ms) (setf ms (adjoin :head ms)))
    ms))

(defun format-allow (methods)
  (format nil "~{~a~^, ~}"
          (sort (mapcar (lambda (m) (string-upcase (symbol-name m))) methods)
                #'string<)))

(defun resolve-plug (plug)
  "PLUG may be a function or symbol."
  (etypecase plug
    (function plug)
    (symbol (symbol-function plug))))

(defun run-entry (entry params conn)
  (let* ((c (merge-params conn params))
         (plugs (append (mapcar #'resolve-plug (getf entry :pipes))
                        (list (resolve-plug (getf entry :handler))))))
    (apply #'run-pipeline c plugs)))

(defmethod call-router ((router router) conn)
  (let* ((method  (conn-method conn))
         (matches (path-matches (router-entries router) (conn-path conn))))
    (cond
      ;; No path matched at all -> 404.
      ((null matches)
       (funcall (resolve-plug (router-not-found router)) conn))
      ;; OPTIONS preflight: respond with Allow listing supported methods.
      ((eq method :options)
       (put-resp conn 204 nil
                 (list "allow" (format-allow (allowed-methods matches)))))
      (t
       (let ((hit (find method matches :key (lambda (p) (getf (car p) :method)))))
         (cond
           (hit (run-entry (car hit) (cdr hit) conn))
           ;; HEAD falls back to GET handler; body is stripped in conn->clack.
           ((eq method :head)
            (let ((get-hit (find :get matches
                                 :key (lambda (p) (getf (car p) :method)))))
              (if get-hit
                  (run-entry (car get-hit) (cdr get-hit) conn)
                  (method-not-allowed conn matches))))
           (t (method-not-allowed conn matches))))))))

(defun method-not-allowed (conn matches)
  (put-resp conn 405 "Method Not Allowed"
            (list "content-type" "text/plain"
                  "allow" (format-allow (allowed-methods matches)))))

;;; The router itself is a plug.
(defun router-as-plug (router)
  (lambda (conn) (call-router router conn)))

;;; DSL macro: bind a router to a name.
(defmacro defroutes (name &body body)
  "Define NAME as a router. Body forms are either:

  (:method path handler &key pipe-through)   ; shorthand for (route ...)
  (scope prefix [:pipe-through xs] ...)      ; nested group
  (route :method path handler ...)           ; explicit form"
  `(defparameter ,name
     (make-router
      :entries (append ,@(mapcar #'rewrite-route-form body)))))
