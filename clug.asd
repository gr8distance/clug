(defsystem "clug"
  :description "A tiny Clack routing plugin in the spirit of Phoenix Plug."
  :version "0.1.0"
  :author "ug <gr8.distance@gmail.com>"
  :license "MIT"
  :depends-on ("clack" "alexandria" "quri")
  :pathname "src/"
  :components ((:file "package")
               (:file "path"     :depends-on ("package"))
               (:file "conn"     :depends-on ("package" "path"))
               (:file "pipeline" :depends-on ("conn"))
               (:file "router"   :depends-on ("conn" "pipeline" "path"))
               (:file "clack"    :depends-on ("conn" "router")))
  :in-order-to ((test-op (test-op "clug/tests"))))

(defsystem "clug/tests"
  :depends-on ("clug" "fiveam" "flexi-streams")
  :pathname "tests/"
  :components ((:file "main"))
  :perform (test-op (op c) (symbol-call :fiveam :run! :clug)))
