(define (self-relatively thunk)
  (if (current-eval-unit #f)
      (with-working-directory-pathname
       (directory-namestring (current-load-pathname))
       thunk)
      (thunk)))

(define (load-relative filename #!optional environment)
  (self-relatively (lambda () (load filename environment))))

(load-relative "../support/auto-compilation")

;;; FOL is loaded into its own environment to keep the names separate
;;; from those of its clients.  You can put your REPL into the FOL
;;; environment with (ge fol-environment), and get back to the usual
;;; place with (ge user-initial-environment).

(define *environment* (the-environment))
(define fol-environment (make-top-level-environment))

(environment-define fol-environment 'fol-environment fol-environment)
(environment-define fol-environment '*environment* fol-environment)

(load-relative "../support/rules/load" fol-environment)

(load-option 'format)

(for-each
 (lambda (file)
   (load-relative-compiled file fol-environment))
 '("../support/utils"
   "../support/hash-tables"
   "../support/two-way-table"
   "../support/srfi-11"
   "../support/pattern-case/load"
   "stages"
   "nomenclature"
   "syntax"
   "lift-lets"
   "runtime"
   "primitives"
   "alpha-renaming"
   "structs"
   "type-check"
   "feedback-vertex-set"
   "inlinees"
   "inline"
   "a-normal-form"
   "sra"
   "dead-types"
   "cse"
   "dead-code"
   "optimize"
   "mit-scheme"
   "stalin"
   "common-lisp"
   "asm-js"
   "backends"
   "entry-point"))

;;; Exports

(let ((client-environment (the-environment)))
  (for-each
   (lambda (export)
     (environment-define
      client-environment export (environment-lookup fol-environment export)))
   '(;; Evaluation and further compilation
     fol-eval
     fol->mit-scheme
     fol->floating-mit-scheme
     run-mit-scheme
     fol->standalone-mit-scheme
     run-standalone-mit-scheme
     fol->stalin
     run-stalin
     fol->common-lisp
     run-common-lisp
     fol->asm.js

     ;; Optimization
     equal-type? ; TODO
     fol-optimize
     loopy-fol-optimize

     ;; Form checkers and converters
     structure-definitions->vectors
     check-fol-types
     alpha-rename
     unique-names?
     alpha-rename?
     approximate-anf ; TODO The stage is called a-normal-form, but that's wrong
     approximate-anf?
     lift-lets
     lets-lifted?

     ;; Individual stages
     inline
     intraprocedural-cse
     eliminate-intraprocedural-dead-code
     scalar-replace-aggregates
     eliminate-dead-types
     eliminate-interprocedural-dead-code
     reverse-anf

     ;; Visualizations
     strip-argument-types
     let->let*
     print-fol-statistics
     print-short-fol-stats

     ;; The underlying type checker
     check-program-types ;; TODO For testing

     ;; The FOL runtime system.  It is exported because it is part of
     ;; the implementation of VL and DVL (the concrete implementations
     ;; of some primitives).
     real read-real write-real make-gensym gensym-number gensym? gensym= gensym<

     ;; The FOL names subsystem (see nomenclature.scm).
     make-name name->symbol reset-fol-names!

     ;; Stage manipulation TODO
     stage-pipeline visibly volubly measuring-memory watching-memory type-safely parse-stage
     present? property-value
     name execution-function
     reads computes generates preserves destroys

     ;; The entry point for the command line
     fol-main
     ))
  (environment-define-macro
   client-environment 'define-stage
   (environment-lookup-macro fol-environment 'define-stage)))

(if (not (lexical-unbound? (the-environment) 'stop-scmutils-print))
    (begin
      (warn "Turning off the SCMUtils fancy printer because it will choke on FOL programs.")
      (warn "You can re-enable it by executing (start-scmutils-print),")
      (warn "and re-disable it by executing (stop-scmutils-print).")
      (stop-scmutils-print)))