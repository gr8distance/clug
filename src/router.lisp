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

(defun %scope (prefix &rest args)
  "Runtime form of SCOPE. Takes already-built entry lists as children."
  (multiple-value-bind (pipes children) (parse-scope-args args)
    (let ((prefix-segs (compile-path prefix)))
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
  (multiple-value-bind (opts children) (split-scope-head rest)
    `(%scope ,prefix ,@opts ,@(mapcar #'rewrite-route-form children))))

(defun split-scope-head (forms)
  "Split FORMS into ((:pipe-through X) and remaining children)."
  (if (eq (first forms) :pipe-through)
      (values (list :pipe-through (second forms)) (cddr forms))
      (values nil forms)))

(defun parse-scope-args (args)
  "Split ARGS into (pipe-through-list, list-of-child-entry-lists)."
  (let ((pipes nil)
        (rest args))
    (when (eq (first rest) :pipe-through)
      (setf pipes (alexandria:ensure-list (second rest))
            rest (cddr rest)))
    (values pipes rest)))

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
            (list "Content-Type" "text/plain")))

(defun add-route (router entry)
  (setf (router-entries router)
        (append (router-entries router) (list entry)))
  router)

(defun match-entry (entries method path)
  "Return (values entry params) for first match, or NIL."
  (dolist (e entries)
    (when (eq (getf e :method) method)
      (let ((m (match-path (getf e :compiled) path)))
        (when m
          (return-from match-entry
            (values e (if (eq m t) nil m)))))))
  nil)

(defun resolve-plug (plug)
  "PLUG may be a function, symbol, or (function FN)."
  (etypecase plug
    (function plug)
    (symbol (symbol-function plug))))

(defmethod call-router ((router router) conn)
  (multiple-value-bind (entry params)
      (match-entry (router-entries router)
                   (conn-method conn)
                   (conn-path conn))
    (if entry
        (let* ((c (merge-params conn params))
               (plugs (append (mapcar #'resolve-plug (getf entry :pipes))
                              (list (resolve-plug (getf entry :handler))))))
          (apply #'run-pipeline c plugs))
        (funcall (resolve-plug (router-not-found router)) conn))))

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
