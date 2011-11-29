(declare (usual-integrations))
(declare (integrate-external "syntax"))
(declare (integrate-external "../support/pattern-matching"))
;;;; Dead code elimination

;;; Variables that hold values that are never used can be eliminated.
;;; The code that computes those values can also be eliminated.

;;; Intraprocedural dead variable elimination can be done by recursive
;;; traversal of the code, traversing LET bodies before LET bindings.
;;; In the absence of multiple value returns, the recursion need not
;;; carry any information down, because the mere fact of being
;;; considered would mean that any given expression were live.  In the
;;; presence of multiple value returns, however, some of the returned
;;; values might be live while others are dead.  Therefore, the
;;; recursion carries down a list indicating which of the values that
;;; are expected to come out of the subexpression are live and which
;;; are not.  The recursive call must return both the subexpression
;;; with dead code removed, and the set of variables it uses to
;;; compute its live outputs.  Variables not in that set at their
;;; binding site are dead and may be removed.

;;; In this setup:
;;; - Constants use nothing.
;;; - Variables use themselves.
;;; - If any of the outputs of an IF form are live, then its predicate
;;;   is live.  Both branches' returns inherit the liveness of the
;;;   entire IF's return.  Every output of the IF form uses everything
;;;   its predicate uses, and the appropriate things its branches use.
;;; - A LET body is processed first; any variables (and their
;;;   expressions) the LET binds that its body doesn't use are dead
;;;   and can be skipped.  A LET uses all the variables that are used
;;;   by its body less those bound by the LET itself, and all the
;;;   variables that are used by the expressions that the LET binds to
;;;   its live variables.
;;; - A LET-VALUES is analagous, except that it has only one
;;;   expression binding several variables, some of which may be live
;;;   and others not.  In that case, the LET-VALUES drops the dead
;;;   variables, and recurs on the subexpression giving it that mask
;;;   for what to keep and what to leave off.
;;; - A VALUES form must conversely interpret the incoming mask and
;;;   only keep those of its subexpressions that are actually needed.
;;; - Procedure applications: Since the analysis is intraprocedural,
;;;   it assumes that all the arguments of a live procedure call are
;;;   live.

;;; A procedure call may return multiple values, not all of which may
;;; be wanted by the caller.  The transformation cannot change the set
;;; of values the procedure will return, but the caller will be
;;; tranformed to expect to be given only live values.  At this point,
;;; the transformation pulls a trick: it binds all the values that the
;;; procedure will emit in a LET-VALUES, and immediately returns the
;;; live ones with a VALUES.  The others are bound to a special name
;;; that any future dead variable transform will recognize as "Yes, I
;;; know this variable is dead, but I have to bind it anyway because
;;; it's coming here whether I want it or not."  Analagously,
;;; procedure formal parameters are not removed even if they may be
;;; dead in the body.

;;; In principle, masking similar to what is used for VALUES could be
;;; used to do elimination on the slots of structures, but for
;;; simplicity I have chosen instead to rely on SRA to separate said
;;; structures into individually named variables and just do
;;; elimination on those variables.  I may revisit this decision when
;;; I add union types.

(define (%eliminate-intraprocedural-dead-code program)
  (define eliminate-in-definition
    (rule `(define ((? name ,fol-var?) (?? formals))
             (argument-types (?? stuff) (? return))
             (? body))
          `(define (,name ,@formals)
             (argument-types ,@stuff ,return)
             ,(eliminate-in-expression
               body (or (not (values-form? return))
                        (map (lambda (x) #t) (cdr return)))))))
  (if (begin-form? program)
      (append
       (map eliminate-in-definition (except-last-pair program))
       (list (eliminate-in-expression
              (last program) #t)))
      (eliminate-in-expression program #t)))

(define (eliminate-in-expression expr live-out)
  (define (ignore? name)
    (eq? (name-base name) '_))
  ;; The live-out parameter indicates which of the return values of
  ;; this expression are needed by the context in whose tail position
  ;; this expression is evaluated.  It will be #t unless the context
  ;; is a LET-VALUES, in which case it will indicate which of those
  ;; multiple values are needed.  If I were eliminating dead structure
  ;; slots as well, this would be hairier.
  ;; The recursive call returns two things: the transformed expression
  ;; and the set of variables that it needs to compute its live
  ;; results.
  (define (loop expr live-out)
    (case* expr
      ((fol-var var)
       (values expr (single-used-var var)))
      ((fol-const _)
       (values expr (no-used-vars)))
      ((if-form pred cons alt)
       (eliminate-in-if pred cons alt live-out))
      ((let-form bindings body)
       (eliminate-in-let bindings body live-out))
      ((let-values-form names subexp body)
       (eliminate-in-let-values names subexp body live-out))
      ((lambda-form formals body)
       (eliminate-in-lambda formals body live-out))
      ;; If used post SRA, there may be constructions to build the
      ;; answer for the outside world, but there should be no
      ;; accesses.
      ((construction ctor operands)
       (eliminate-in-construction ctor operands live-out))
      ((accessor kind arg extra)
       (eliminate-in-access kind arg extra live-out))
      ((values-form subforms)
       (eliminate-in-values subforms live-out))
      ((pair operator operands) ; general application
       (eliminate-in-application operator operands live-out))))
  (define (eliminate-in-if predicate consequent alternate live-out)
    (let-values (((new-predicate pred-needs) (loop predicate #t))
                 ((new-consequent cons-needs) (loop consequent live-out))
                 ((new-alternate alt-needs) (loop alternate live-out)))
      (values `(if ,new-predicate
                   ,new-consequent
                   ,new-alternate)
              (var-set-union
               pred-needs (var-set-union cons-needs alt-needs)))))
  (define (eliminate-in-let bindings body live-out)
    (receive (new-body body-needs) (loop body live-out)
      (let ((new-bindings
             (filter (lambda (binding)
                       (var-used? (car binding) body-needs))
                     bindings)))
        (receive (new-exprs exprs-need) (loop* (map cadr new-bindings))
          (let ((used (var-set-union* exprs-need)))
            (values (tidy-empty-let
                     `(let ,(map list (map car new-bindings)
                                 new-exprs)
                        ,new-body))
                    (var-set-union
                     (var-set-difference
                      body-needs (map car bindings))
                     used)))))))
  (define (eliminate-in-let-values names sub-expr body live-out)
    (receive (new-body body-needs) (loop body live-out)
      (define (slot-used? name)
        (or (and (ignore? name)
                 ;; Ignored names are a hack for when the source
                 ;; of the values is a procedure call.
                 ;; Interprocedural dead code elimination may
                 ;; replace such a call with a further let or
                 ;; let-values, in which case the ignore
                 ;; instruction is out of date.
                 (not (or (let-form? sub-expr)
                          (let-values-form? sub-expr))))
            (and (var-used? name body-needs)
                 #t)))
      (let ((sub-expr-live-out (map slot-used? names)))
        (if (any (lambda (x) x) sub-expr-live-out)
            (receive (new-sub-expr sub-expr-needs) (loop sub-expr sub-expr-live-out)
              (values (tidy-let-values
                       `(let-values ((,(filter slot-used? names)
                                      ,new-sub-expr))
                          ,new-body))
                      (var-set-union
                       sub-expr-needs
                       (var-set-difference body-needs names))))
            (values new-body body-needs)))))
  (define (eliminate-in-lambda formals body live-out)
    (receive (new-body body-needs) (loop body #t) ; Nothing that escapes can be dead
      (values `(lambda ,formals
                 ,new-body)
              (var-set-difference body-needs formals))))
  ;; Given that I decided not to do proper elimination of dead
  ;; structure slots, I will say that if a structure is needed then
  ;; all of its slots are needed, and any access to any slot of a
  ;; structure causes the entire structure to be needed.
  (define (eliminate-in-construction ctor operands live-out)
    (receive (new-args args-need) (loop* operands)
      (values `(,ctor ,@new-args)
              (var-set-union* args-need))))
  (define (eliminate-in-access kind arg extra live-out)
    (receive (new-accessee accessee-uses) (loop arg #t)
      (values `(,kind ,new-accessee ,@extra)
              accessee-uses)))
  (define (eliminate-in-values subforms live-out)
    (assert (list? live-out))
    (let ((wanted-elts (filter-map (lambda (wanted? elt)
                                     (and wanted? elt))
                                   live-out
                                   subforms)))
      (receive (new-elts elts-need) (loop* wanted-elts)
        (values (if (= 1 (length new-elts))
                    (car new-elts)
                    `(values ,@new-elts))
                (var-set-union* elts-need)))))
  (define (eliminate-in-application operator operands live-out)
    (receive (new-args args-need) (loop* operands)
      (define (all-wanted? live-out)
        (or (equal? live-out #t)
            (every (lambda (x) x) live-out)))
      (define (invent-name wanted?)
        (if wanted?
            (make-name 'receipt)
            (make-name '_)))
      (let ((simple-new-call `(,operator ,@new-args)))
        (let ((new-call
               (if (all-wanted? live-out)
                   simple-new-call
                   (let* ((receipt-names (map invent-name live-out))
                          (useful-names (filter (lambda (x) (not (ignore? x)))
                                                receipt-names)))
                     `(let-values ((,receipt-names ,simple-new-call))
                        ,(if (> (length useful-names) 1)
                             `(values ,@useful-names)
                             (car useful-names)))))))
          (values new-call (var-set-union* args-need))))))
  (define (loop* exprs)
    (if (null? exprs)
        (values '() '())
        (let-values (((new-expr expr-needs) (loop (car exprs) #t))
                     ((new-exprs exprs-need) (loop* (cdr exprs))))
          (values (cons new-expr new-exprs)
                  (cons expr-needs exprs-need)))))
  (receive (new-expr used-vars) (loop expr live-out) new-expr))

(define (no-used-vars) '())

(define (single-used-var var) (list var))

(define (var-set-union vars1 vars2)
  (lset-union eq? vars1 vars2))

(define (var-set-union* vars-lst)
  ;; This reduce is semantically what I'm doing, but it turns out to
  ;; be *cubic*.
  #;(reduce var-set-union (no-used-vars) vars-lst)
  ;; So I reach under the abstraction barrier.
  ((unique strong-eq-hash-table-type) (apply append vars-lst)))

(define (var-set-difference vars1 vars2)
  (lset-difference eq? vars1 vars2))

(define (var-set-union-map f vars)
  (var-set-union* (var-set-map f vars)))

(define (var-set-map f vars)
  (map f vars))

(define var-used? memq)

(define var-set-size length)

(define (var-set-equal? vars1 vars2)
  (lset= eq? vars1 vars2))

;;; To do interprocedural dead variable elimination I have to proceed
;;; as follows:
;;; -1) Run a round of intraprocedural dead variable elimination to
;;;     diminish the amount of work in the following (assume all
;;;     procedure calls need all their inputs)
;;; 0) Treat the final expression as a nullary procedure definition
;;; 1) Initialize a map for each procedure, mapping from output that
;;;    might be desired to set of inputs that are known to be needed
;;;    to compute that output.
;;;    - I know the answer for primitives
;;;    - All compound procedures start mapping every output to the
;;;      empty set of inputs known to be needed.
;;; 2) I can improve the map by walking the body of a procedure,
;;;    computing a map saying which outputs require which inputs.
;;;    This is exactly analagous to the intraprocedural dead code
;;;    recursion, except for distinguishing which inputs are needed
;;;    for which outputs.
;;;    - A constant requires no inputs for one output.
;;;    - A variable requires itself for one output.
;;;    - A VALUES maps the requirements of subexpressions to its
;;;      outputs.
;;;    - A LET is processed body first:
;;;      - Get the map for which of the returned values need what
;;;        variables from the environment.
;;;      - Process the expressions generating the bound variables to
;;;        determine what they need.
;;;      - For each of its outputs, the LET form as a whole needs the
;;;        variables the body needs for it that the LET didn't bind,
;;;        and all the variables needed by the LET's expressions for
;;;        the variables the body needed that the LET did bind.
;;;    - A LET-VALUES is analagous, except that there is only one
;;;      expression for all the bound names.
;;;    - An IF recurs on the predicate, the consequent and the
;;;      alternate.  When the answers come back, it needs to union the
;;;      consequent and alternate maps, and then add the predicate
;;;      requirements as inputs to all outputs of the IF.
;;;    - A procedure call refers to the currently known map for that
;;;      procedure.
;;;    - Whatever comes out of the top becomes the new map for this
;;;      procedure.
;;; 3) Repeat step 2 until no more improvements are possible.
;;; 4) Initialize a table of which inputs and outputs to each compound
;;;    procedure are actually needed.
;;;    - I actually only need to store the outputs, because the inputs
;;;      can be deduced from them using the map computed in steps 1-3.
;;;    - All procedures start not needed.
;;;    - The entry point starts fully needed.
;;; 5) I can improve this table by pretending to do an intraprocedural
;;;    dead code elimination on the body of a procedure some of whose
;;;    outputs are needed, except
;;;    - At a procedure call, mark outputs of that procedure as needed
;;;      in the table if I found that I needed them on the walk; then
;;;      take back up the set of things that that procedure says it
;;;      needs to produce what I needed from it.
;;;    - Otherwise walk as for intraprocedural (without rewriting)
;;; 6) Repeat step 5 until no more improvements are possible.
;;; 7) Replace all definitions to
;;;    - Accept only those arguments they need (internally LET-bind all
;;;      others to tombstones)
;;;    - Return only those outputs that are needed (internally
;;;      LET-VALUES everything the body will generate, and VALUES out
;;;      that which is wanted)
;;; 8) Replace all call sites to
;;;    - Supply only those arguments that are needed (just drop the
;;;      rest)
;;;    - Solicit only those outputs that are needed (LET-VALUES them,
;;;      and VALUES what the body expects, filling in with tombstones).
;;; 9) Run a round of intraprocedural dead variable elimination to
;;;    clean up (all procedure calls now do need all their inputs).

(define (program->procedure-definitions program)
  (define (expression->procedure-definition entry-point return-type)
    `(define (%%main)
       (argument-types ,return-type)
       ,entry-point))
  (let ((return-type (check-program-types program)))
    (if (begin-form? program)
        (append (cdr (except-last-pair program))
                (list (expression->procedure-definition (last program) return-type)))
        (list (expression->procedure-definition program return-type)))))

(define (procedure-definitions->program defns)
  (tidy-begin
   `(begin
      ,@(except-last-pair defns)
      ,(cadddr (last defns)))))

(define (%interprocedural-dead-code-elimination program)
  (let* ((defns (program->procedure-definitions program))
         (dependency-map (compute-dependency-map defns))
         (liveness-map (compute-liveness-map dependency-map defns))
         (rewritten (rewrite-definitions dependency-map liveness-map defns)))
    (procedure-definitions->program
     rewritten)))

(define (interprocedural-dead-code-elimination program)
  ((on-subexpressions
    (rule `(let-values ((((?? names)) (? exp)))
              (values (?? names)))
           exp))
   (%eliminate-intraprocedural-dead-code ; TODO Check for absence of tombstones
    (%interprocedural-dead-code-elimination
     program))))

;;; The dependency-map is the structure built by steps 1-3 above.  It
;;; maps every procedure name to a list of boolean lists.  The outer
;;; list is parallel to the values that the procedure returns, each
;;; inner list is parallel to the procedure's inputs, and each boolean
;;; answers the question of whether that input is needed for the
;;; procedure to compute that output.

(define (compute-dependency-map defns)
  (let loop ((overall-map (initial-dependency-map defns))
             (maybe-done? #t))
    (for-each
     (lambda (defn)
       (let ((local-map (improve-dependency-map defn overall-map)))
         (if (every equal? local-map (hash-table/get overall-map (definiendum defn) #f))
             'ok
             (begin
               (hash-table/put! overall-map (definiendum defn) local-map)
               (set! maybe-done? #f)))))
     defns)
    (if (not maybe-done?)
        (loop overall-map #t)
        overall-map)))

(define (initial-dependency-map defns)
  (define (primitive-dependency-map)
    (define (needs-all primitive)
      (cons (primitive-name primitive)
            (list ;; TODO Assumes all primitives return only one value
             (map (lambda (arg) #t)
                  (arg-types (primitive-type primitive))))))
    (alist->eq-hash-table
     (map needs-all *primitives*)))
  (abegin1
   (primitive-dependency-map)
   (for-each
    (rule `(define ((? name) (?? args))
             (argument-types (?? stuff) (? return))
             (? body))
          (hash-table/put! it name
           (map (lambda (item) (map (lambda (x) #f) args))
                (desirable-slot-list return))))
    defns)))

(define (improve-dependency-map defn dependency-map)
  ;; This loop is like the one in ELIMINATE-IN-EXPRESSION, except that
  ;; 1) It accumulates a more detailed answer structure (namely one
  ;;    mapping all the possible outputs to which variables are needed
  ;;    to compute each one).
  ;; 2) It does not rewrite the expression, so it returns only one
  ;;    value.
  ;; 3) It is always interested in all return values, so it needn't
  ;;    pass down a LIVE-OUT list.
  (define-case* loop
    ((fol-var var) (list (single-used-var var)))
    ((fol-const _) (list (no-used-vars)))
    (if-form => study-if)
    (let-form => study-let)
    (let-values-form => study-let-values)
    (lambda-form => study-lambda)
    ;; If used post SRA, there may be constructions to build the
    ;; answer for the outside world, but there should be no
    ;; accesses.
    (construction => study-construction)
    (accessor => study-access)
    (values-form => study-values)
    (pair => study-application))        ; general application
  (define (study-if predicate consequent alternate)
    (let ((pred-needs (car (loop predicate)))
          (cons-needs (loop consequent))
          (alt-needs (loop alternate)))
      (map
       (lambda (needed-in)
         (var-set-union pred-needs needed-in))
       (map var-set-union cons-needs alt-needs))))
  (define (study-let bindings body)
    (let ((body-needs (loop body))
          (bindings-need (map (lambda (binding)
                                (cons (car binding)
                                      (car (loop (cadr binding)))))
                              bindings)))
      (map (interpolate-let-bindings bindings-need) body-needs)))
  (define (study-let-values names sub-expr body)
    (let ((body-needs (loop body))
          (bindings-need (map cons names (loop sub-expr))))
      (map (interpolate-let-bindings bindings-need) body-needs)))
  (define (study-lambda formals body)
    (let ((body-needs (loop body)))
      (var-set-difference body-needs formals)))
  (define (interpolate-let-bindings bindings-need)
    (lambda (need-set)
      (var-set-union-map
       (lambda (needed-var)
         (let ((binding.need (assq needed-var bindings-need)))
           (if binding.need
               (cdr binding.need)
               (single-used-var needed-var))))
       need-set)))
  (define (study-construction ctor operands)
    (list
     (var-set-union*
      (map (lambda (arg)
             (car (loop arg)))
           operands))))
  (define (study-access kind arg extra)
    (loop arg))
  (define (study-values sub-exprs)
    (map
     (lambda (sub-expr)
       (car (loop sub-expr)))
     sub-exprs))
  (define (study-application operator operands)
    (let ((operator-dependency-map (hash-table/get dependency-map operator #f))
          (operands-need (map (lambda (operand)
                                (car (loop operand)))
                              operands)))
      (map
       (lambda (operands-live)
         (var-set-union*
          (select-masked
           operands-live
           operands-need)))
       operator-dependency-map)))
  (define improve-dependency-map
    (rule `(define ((? name) (?? args))
             (argument-types (?? stuff) (? return))
             (? body))
          (map
           (lambda (out-needs)
             (map (lambda (arg)
                    (and (var-used? arg out-needs) #t))
                  args))
           (loop body))))
  (improve-dependency-map defn))

(define (desirable-slot-list shape)
  (if (values-form? shape)
      (cdr shape)
      (list shape)))

;;; The liveness map is the structure constructed during steps 4-6
;;; above.  It maps every procedure name to the set of its outputs
;;; that are actually needed (represented as a parallel list of
;;; booleans).  The needed inputs can be inferred from this given the
;;; dependency-map.

(define (compute-liveness-map dependency-map defns)
  (let ((liveness-map (initial-liveness-map defns))
        (input-liveness-map (initial-input-liveness-map defns)))
    (let loop ()
      (clear-changed! liveness-map)
      (clear-changed! input-liveness-map)
      (for-each
       (lambda (defn)
         (improve-liveness-map! dependency-map liveness-map input-liveness-map defn))
       defns)
      (if (or (changed? liveness-map) (changed? input-liveness-map))
          (loop)
          liveness-map))))

(define (clear-changed! thing)
  (eq-put! thing 'changed #f))

(define (changed? thing)
  (eq-get thing 'changed))

(define (changed! thing)
  (eq-put! thing 'changed #t))

(define (initial-liveness-map defns)
  (abegin1
   (alist->eq-hash-table
    (map (rule `(define ((? name) (?? args))
                  (argument-types (?? stuff) (? return))
                  (? body))
               (cons name
                     (map (lambda (x) #f) (desirable-slot-list return))))
         defns))
   (hash-table/put! it (definiendum (last defns)) (list #t))))

(define (initial-input-liveness-map defns)
  (abegin1
   (alist->eq-hash-table
    (map (rule `(define ((? name) (?? args))
                  (argument-types (?? stuff) (? return))
                  (? body))
               (cons name (map (lambda (x) #f) stuff)))
         defns))))

(define (improve-liveness-map! dependency-map liveness-map input-liveness-map defn)
  ;; This loop is identical with the one in ELIMINATE-IN-EXPRESSION,
  ;; except that
  ;; 1) It doesn't rewrite the expression (so returns one value).
  ;; 2) It refers to the given DEPENDENCY-MAP for what callees need.
  ;; 3) When it encounters a procedure call, it updates the
  ;;    LIVENESS-MAP with a side effect.
  (define (loop expr live-out)
    (if (any (lambda (x) x) live-out)
        (%loop expr live-out)
        (no-used-vars)))
  (define (%loop expr live-out)
    (case* expr
      ((fol-var var)
       (single-used-var var))
      ((fol-const _)
       (no-used-vars))
      ((if-form pred cons alt)
       (study-if pred cons alt live-out))
      ((let-form bindings body)
       (study-let bindings body live-out))
      ((let-values-form names subexpr body)
       (study-let-values names subexpr body live-out))
      ((lambda-form formals body)
       (study-lambda formals body live-out))
      ;; If used post SRA, there may be constructions to build the
      ;; answer for the outside world, but there should be no
      ;; accesses.
      ((construction ctor operands)
       (study-construction ctor operands live-out))
      ((accessor kind arg extra)
       (study-access kind arg extra live-out))
      ((values-form subforms)
       (study-values subforms live-out))
      ((pair operator operands) ; general application
       (study-application operator operands live-out))))
  (define (study-if predicate consequent alternate live-out)
    (let ((pred-needs (loop predicate (list #t)))
          (cons-needs (loop consequent live-out))
          (alt-needs (loop alternate live-out)))
      (var-set-union pred-needs (var-set-union cons-needs alt-needs))))
  (define (study-let bindings body live-out)
    (let ((body-needs (loop body live-out)))
      (var-set-union-map
       (lambda (needed-var)
         (let ((binding (assq needed-var bindings)))
           (if binding
               (loop (cadr binding) (list #t))
               (single-used-var needed-var))))
       body-needs)))
  (define (study-let-values names sub-expr body live-out)
    (let ((body-needs (loop body live-out)))
      (define (slot-used? name)
        (var-used? name body-needs))
      (let ((sub-expr-live-out (map slot-used? names)))
        (var-set-union (var-set-difference body-needs names)
                       (loop sub-expr sub-expr-live-out)))))
  (define (study-lambda formals body live-out)
    (let ((body-needs (loop body (list #t))))
      (var-set-difference body-needs formals)))
  (define (study-construction ctor operands live-out)
    (var-set-union*
     (map (lambda (arg)
            (loop arg (list #t)))
          operands)))
  (define (study-access kind arg extra live-out)
    (loop arg (list #t)))
  (define (study-values subforms live-out)
    (var-set-union*
     (map (lambda (sub-expr) (loop sub-expr (list #t)))
          (select-masked live-out subforms))))
  (define (study-application operator operands live-out)
    (outputs-needed! liveness-map operator live-out)
    (let* ((operator-dependency-map (hash-table/get dependency-map operator #f))
           ;; The default in the hash table get is the full operands list because
           ;; needed primitives are assumed to always need everything.
           (operands-live (hash-table/get input-liveness-map operator operands)))
      (var-set-union*
       (map (lambda (operand) (loop operand (list #t)))
            (select-masked operands-live operands)))))
  (define improve-liveness-map
    (rule `(define ((? name) (?? args))
             (argument-types (?? stuff) (? return))
             (? body))
          (let ((body-live-out (hash-table/get liveness-map name #f)))
            ;; The loop does return information on which inputs are
            ;; needed, but I can safely throw it away because the
            ;; dependency-map of this operator already allows one to
            ;; deduce which inputs the operator needs, given which of
            ;; the operator's outputs are needed.
            (outputs-needed!
             input-liveness-map name
             (let ((live-in (loop body body-live-out)))
               (map (lambda (arg)
                      (var-used? arg live-in))
                    args))))))
  (define (outputs-needed! liveness-map name live)
    ;; TODO Actually identical for needing inputs as well.
    (let ((needed-outputs (hash-table/get liveness-map name #f)))
      (if needed-outputs
          (pair-for-each
           (lambda (known-needed new-needed)
             (if (and (car new-needed) (not (car known-needed)))
                 (begin
                   (set-car! known-needed #t)
                   (changed! liveness-map))
                 'ok))
           needed-outputs
           live)
          ;; I don't care which outputs of primitives are needed.
          'ok)))
  (improve-liveness-map defn))

(define (rewrite-definitions dependency-map liveness-map defns)
  ;; This bogon has to do with the entry point being a definition now
  (define the-type-map (type-map `(begin ,@defns 'bogon)))
  (define (rewrite-definition name args arg-types return body)
    (let* ((needed-outputs (hash-table/get liveness-map name #f))
           (i/o-map (hash-table/get dependency-map name #f))
           (needed-inputs (find-needed-inputs needed-outputs i/o-map))
           (all-outs-needed? (every (lambda (x) x) needed-outputs)))
      (define new-return-type
        (tidy-values
         `(values ,@(select-masked needed-outputs (if (values-form? return)
                                                      (cdr return)
                                                      (list return))))))
      `(define (,name ,@(select-masked needed-inputs args))
         (argument-types ,@(select-masked needed-inputs arg-types)
                         ,new-return-type)
         ,(let* ((body (rewrite-call-sites
                        the-type-map dependency-map liveness-map body))
                 (the-body
                  (tidy-empty-let
                   `(let ,(map (lambda (name)
                                 `(,name ,(make-tombstone)))
                               (select-masked
                                (map not needed-inputs) args))
                      ,body))))
            (if all-outs-needed?
                the-body ; All the outs of the entry point will always be needed
                (let ((output-names
                       (invent-names-for-parts 'receipt return)))
                  (tidy-let-values
                   `(let-values ((,output-names ,the-body))
                      ,(tidy-values
                        `(values
                          ,@(select-masked
                             needed-outputs output-names)))))))))))
  (map
   (rule `(define ((? name) (?? args))
            (argument-types (?? arg-types) (? return))
            (? body))
         (rewrite-definition name args arg-types return body))
   defns))

(define (rewrite-call-sites type-map dependency-map liveness-map form)
  (define (procedure? name)
    (hash-table/get liveness-map name #f))
  (define (rewrite-call-site operator operands)
    (let* ((needed-outputs (hash-table/get liveness-map operator #f))
           (i/o-map (hash-table/get dependency-map operator #f))
           (needed-inputs (find-needed-inputs needed-outputs i/o-map))
           (all-outs-needed? (every (lambda (x) x) needed-outputs)))
      (let ((the-call
             ;; TODO One could, actually, eliminate even more dead
             ;; code than this: imagine a call site that only needs
             ;; some of the needed outputs of the callee, where the
             ;; callee only needs some of its needed inputs to compute
             ;; those outputs.  Then the remaining inputs need to be
             ;; supplied, because the callee's interface has to
             ;; support callers that may need the outputs those inputs
             ;; help it compute, but it would be safe to put
             ;; tombstones there, because the analysis just proved
             ;; that they will not be needed.
             `(,operator ,@(select-masked needed-inputs operands))))
        (if all-outs-needed?
            the-call
            (let* ((output-names
                    (invent-names-for-parts
                     'receipt (return-type (type-map operator))))
                   (needed-names
                    (select-masked needed-outputs output-names)))
              (tidy-let-values
               `(let-values ((,needed-names ,the-call))
                  ,(tidy-values
                    `(values
                      ,@(map (lambda (live? name)
                               (if live? name (make-tombstone)))
                             needed-outputs
                             output-names))))))))))
  ((on-subexpressions
    (rule `((? operator ,procedure?) (?? operands))
          (rewrite-call-site operator operands)))
   form))

(define (find-needed-inputs needed-outputs i/o-map)
  (define (parallel-list-or lists)
    (if (null? lists)
        (map (lambda (x) #f) (car i/o-map))
        (apply map boolean/or lists)))
  (parallel-list-or
   (select-masked needed-outputs i/o-map)))

(define (select-masked liveness items)
  (filter-map (lambda (live? item)
                (and live? item))
              liveness items))

(define (make-tombstone)
  ;; A tombstone is a value that needs to be supplied but I know will
  ;; never be used.  TODO Make the tombstones distinctive so I can
  ;; check whether they all disappear?
  '())
