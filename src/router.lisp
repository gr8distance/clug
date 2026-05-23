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

(defun scope (prefix &rest args)
  "Apply PREFIX and optional :pipe-through to nested route entries.
Usage: (scope \"/api\" :pipe-through '(auth) entry-list ...)"
  (multiple-value-bind (pipes children) (parse-scope-args args)
    (let ((prefix-segs (compile-path prefix)))
      (loop for child-list in children
            append (loop for entry in child-list
                         collect (extend-entry entry prefix-segs prefix pipes))))))

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
  "Define NAME as a router built from BODY forms (each returning entry lists)."
  `(defparameter ,name
     (make-router
      :entries (append ,@body))))
