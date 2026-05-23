(defsystem "clug"
  :description "A tiny Clack routing plugin in the spirit of Phoenix Plug."
  :version "0.3.0"
  :author "ug <gr8.distance@gmail.com>"
  :license "MIT"
  :depends-on ("clack" "alexandria" "quri")
  :pathname "src/"
  :components ((:file "package")
               (:file "path"     :depends-on ("package"))
               (:file "conn"     :depends-on ("package" "path"))
               (:file "pipeline"   :depends-on ("conn"))
               (:file "request-id" :depends-on ("conn"))
               (:file "router"     :depends-on ("conn" "pipeline" "path"))
               (:file "clack"      :depends-on ("conn" "router")))
  :in-order-to ((test-op (test-op "clug/tests"))))

(defsystem "clug/parsers"
  :description "JSON request/response helpers for clug (opt-in)."
  :version "0.3.0"
  :depends-on ("clug" "yason" "babel")
  :pathname "src/"
  :components ((:file "parsers")))

(defsystem "clug/errors"
  :description "Error-handling plugs for clug (opt-in)."
  :version "0.3.0"
  :depends-on ("clug")
  :pathname "src/"
  :components ((:file "errors")))

(defsystem "clug/session"
  :description "Self-contained cookie-based session middleware for clug (opt-in).
Avoids lack-middleware-session's eager body parsing."
  :version "0.3.0"
  :depends-on ("clug" "bordeaux-threads")
  :pathname "src/"
  :components ((:file "session")))

(defsystem "clug/tests"
  :depends-on ("clug" "clug/parsers" "clug/errors" "clug/session"
               "fiveam" "flexi-streams" "babel")
  :pathname "tests/"
  :components ((:file "main"))
  :perform (test-op (op c) (symbol-call :fiveam :run! :clug)))
