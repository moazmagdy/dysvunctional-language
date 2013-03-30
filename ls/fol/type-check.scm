(declare (usual-integrations))
;;;; Type checking

;;; FOL procedure definitions are annotated with their type
;;; signatures, but local variable bindings in FOL are not explicitly
;;; marked.  Type checking FOL is therefore not a completely local
;;; operation, but can be done via a recursive traversal of the code
;;; bodies.  The traversal carries down an environment indicating the
;;; type of every bound variable, and, if the subexpression is
;;; internally well typed, returns the type of the object said
;;; subexpression returns.

;;; In principle, much can be done to make a type checker emit good
;;; type error messages.  I did not do it.  This type checker does the
;;; worst possible thing, which is to signal an error in the enclosing
;;; MIT Scheme as soon as it finds anything wrong.  The context of
;;; such an error can be inspected by entering the MIT Scheme
;;; debugger.

;;; This type checker also doubles as a syntax checker.  In principle,
;;; I should derive the syntax checker mechanically from the FOL
;;; grammar, but instead of learning (or writing) a tool for doing
;;; that I put some basic syntax checks into this program.


;; To really do this right, I must first check the basic syntax of the
;; type definitions while building a list of defined type names; then
;; I check that all the slot types in the defined type definitions are
;; valid types (to wit, only use defined and pre-supplied types) and
;; build a map from defined type names to the structure types that
;; they name (the layer of indirection is needed because the types may
;; (eventually) be recursive); and then, that in hand, proceed to
;; check the syntax and then the typology of the procedure definitions
;; the way I do here.
(define (check-program-types program #!optional inferred-type-map)
  (define (check-type-defn-syntax definition)
    (if (not (= 3 (length definition)))
        (error "Malformed type definition" definition))
    (let ((name (cadr definition))
          (type (caddr definition)))
      (if (not (fol-var? name))
          (error "Malformed type name" name))
      (if (memq name '(real bool gensym escaping-function))
          (error "Defining a reserved type name"))
      (check-structure-type-syntax type)))
  (define (check-structure-type-syntax type)
    (let ((fields (cdr type)))
      (for-each
       (lambda (field-spec)
         (if (not (and (list? field-spec)
                       (= 2 (length field-spec))))
             (error "Malformed structure field spec" field-spec))
         (if (not (fol-var? (car field-spec)))
             (error "Setting a non-name as a structure field" field-spec))
         (if (not (tree-of? fol-var? (cadr field-spec)))
             (error "Malformed structure field type" field-spec)))
       fields)
      (check-unique-names (map car fields) "Repeated structure field name")))
  (define (check-proc-defn-syntax definition)
    (if (not (procedure-definition? definition))
        (error "Non-definition in a non-terminal program position"
               definition))
    (if (not (= 4 (length definition)))
        (error "Malformed definition" definition))
    (let ((formals (cadr definition))
          (types (caddr definition)))
      (if (not (list? formals))
          (error "Malformed formals list" definition))
      (if (not (list? types))
          (error "Malformed type declaration" definition))
      (if (not (= (length types) (+ 1 (length formals))))
          (error "Type declaration not parallel to formals list"
                 definition))
      (if (memq (car formals) fol-reserved)
          (error "Defining a reserved name" (car formals)))
      (for-each
       (lambda (type sub-index)
         (if (not (tree-of? fol-var? type))
             (error "Type declaring a non-type"
                    type definition sub-index)))
       (except-last-pair (cdr types))
       (iota (length (cdr formals))))
      (if (not (tree-of? fol-var? (last types)))
          (error "Malformed return type declaration" definition))
      (check-unique-names (cdr formals) "Repeated formal parameter")))
  (define (check-definition-syntax definition)
    (cond ((type-definition? definition)
           (check-type-defn-syntax definition))
          ((procedure-definition? definition)
           (check-proc-defn-syntax definition))
          (else (error "Invalid definition type" definition))))
  (if (begin-form? program)
      (begin
        (for-each check-definition-syntax
                  (except-last-pair (cdr program)))
        (check-unique-names
         (map cadr (filter type-definition? program))
         "Redefining type name")
        (check-unique-names
         (map definiendum (filter procedure-definition? program))
         "Redefining procedure name")))
  (let* ((defined-type-map (type-map program))
         (lookup-type (procedure-type-map program defined-type-map)))
    (define (check-definition-types definition)
      (let ((formals (cadr definition))
            (types (caddr definition))
            (body (cadddr definition)))
        (let ((body-type
               (check-expression-types
                body
                (augment-type-env! (empty-type-env) (cdr formals)
                                   (arg-types (lookup-type (car formals))))
                lookup-type inferred-type-map)))
          (if (not (equal? (last types) body-type))
              (error "Return type declaration doesn't match"
                     definition (last types) body-type))
          body-type)))
    (define (check-entry-point-types expression)
      (check-expression-types
       expression (empty-type-env)
       lookup-type inferred-type-map))
    (if (begin-form? program)
        (begin
          (check-unique-names
           (append (map definiendum (filter procedure-definition? program))
                   (map car (implicit-procedures defined-type-map)))
           "Name clash involving implicit procedure")
          (for-each check-definition-types (filter procedure-definition? program))
          (check-entry-point-types (last program)))
        (check-entry-point-types program))))

(define (check-expression-types expr env global-type #!optional inferred-type-map)
  ;; A type environment maps every bound local name to its type.  The
  ;; global-type procedure returns the (function) type of any global
  ;; name passed to it.  CHECK-EXPRESSION-TYPES either returns the
  ;; type of the expression or signals an error if the expression is
  ;; either malformed or not type correct.
  ;; For this purpose, a VALUES is the same as any other polymorphic
  ;; construction, but in other contexts they may need to be
  ;; distinguished.
  (define (polymorphic-construction? expr)
    (and (pair? expr)
         (memq (car expr) '(cons vector values))))
  (define (loop expr env)
    (let ((type (%loop expr env)))
      (if (not (default-object? inferred-type-map))
          (hash-table/put! inferred-type-map expr type))
      type))
  (define (%loop expr env)
    (cond ((fol-var? expr) (lookup-type expr env))
          ((number? expr) 'real)
          ((boolean? expr) 'bool)
          ((null? expr) '())
          ((if-form? expr) (check-if-types expr env))
          ((let-form? expr) (check-let-types expr env))
          ((let-values-form? expr) (check-let-values-types expr env))
          ((lambda-form? expr) (check-lambda-types expr env))
          ((cons-ref? expr) (check-cons-ref-types expr env))
          ((vector-ref? expr) (check-vector-ref-types expr env))
          ((polymorphic-construction? expr) (check-polymorphic-construction-types expr env))
          (else (check-application-types expr env))))
  (define (check-if-types expr env)
    (if (not (= 4 (length expr)))
        (error "Malformed IF" expr))
    (let ((pred-type (loop (cadr expr) env))
          (cons-type (loop (caddr expr) env))
          (alt-type (loop (cadddr expr) env)))
      (if (not (eq? 'bool pred-type))
          (error "IF predicate not of boolean type" expr))
      (if (not (equal? cons-type alt-type))
          ;; Note: this place will need to change to support union types
          (error "Different IF branches return different types" expr))
      cons-type))
  (define (check-let-types expr env)
    (if (not (= 3 (length expr)))
        (error "Malformed LET (excess body forms?)" expr))
    (let ((bindings (cadr expr))
          (body (caddr expr)))
      (if (not (list? bindings))
          (error "Malformed LET (non-list bindings)" expr))
      (for-each
       (lambda (binding index)
         (if (not (list? binding))
             (error "Malformed LET binding (not a list)" bindings index))
         (if (not (= 2 (length binding)))
             (error "Malformed LET binding (not a list of length 2)" bindings index)))
       bindings
       (iota (length bindings)))
      (check-unique-names (map car bindings) "Repeated LET binding")
      (let ((binding-types
             (map (lambda (exp) (loop exp env)) (map cadr bindings))))
        (for-each
         (lambda (binding-type index)
           (if (values-form? binding-type)
               (error "LET binds a VALUES shape"
                      expr binding-type index)))
         binding-types
         (iota (length binding-types)))
        (abegin1
            (loop body (augment-type-env!
                        env (map car bindings) binding-types))
          (degment-type-env! env (map car bindings))))))
  (define (check-let-values-types expr env)
    (if (not (= 3 (length expr)))
        (error "Malformed LET-VALUES (excess body forms?)" expr))
    (let ((bindings (cadr expr))
          (body (caddr expr)))
      (if (not (list? bindings))
          (error "Malformed LET-VALUES (non-list bindings)" expr))
      (if (not (= 1 (length bindings)))
          (error "Malformed LET-VALUES (multiple binding expressions)"
                 expr))
      (if (not (list? (car bindings)))
          (error "Malformed LET-VALUES binding (not a list)" bindings))
      (if (not (= 2 (length (car bindings))))
          (error "Malformed LET-VALUES binding (not a list of length 2)" bindings))
      (check-unique-names (caar bindings) "Repeated LET-VALUES binding")
      (let ((binding-type (loop (cadar bindings) env)))
        (if (not (values-form? binding-type))
            (error "LET-VALUES binds a non-VALUES shape"
                   expr binding-type))
        (if (not (= (length (caar bindings)) (length (cdr binding-type))))
            (error "LET-VALUES binds the wrong number of VALUES"
                   expr binding-type))
        (abegin1
            (loop body (augment-type-env!
                        env (caar bindings) (cdr binding-type)))
          (degment-type-env! env (caar bindings))))))
  (define (check-lambda-types expr env)
    (if (not (= 3 (length expr)))
        (error "Malformed LAMBDA (excess body forms?)" expr))
    (let ((formal (cadr expr))
          (body (caddr expr)))
      (if (not (list? formal))
          (error "Malformed LAMBDA (formal not a list)" expr))
      (if (not (= 1 (length formal)))
          (error "Malformed LAMBDA (multiple args not allowed)" expr))
      (let ((body-type (loop body (augment-type-env! env formal (list 'real)))))
        (degment-type-env! env formal)
        ;; TODO Do I want to actually declare and check lambda expression types?
        ;; TODO Extend to checking other foreign types
        #;(function-type 'real body-type)
        'escaping-function)))
  (define (check-cons-ref-types expr env)
    (if (not (= (length expr) 2))
        (error "Malformed pair access" expr))
    (let ((accessee-type (loop (cadr expr) env)))
      (if (not (eq? 'cons (car accessee-type)))
          (if (eq? 'car (car expr))
              (error "Taking the CAR of a non-CONS" accessee-type)
              (error "Taking the CDR of a non-CONS" accessee-type)))
      (select-by-access accessee-type expr)))
  (define (check-vector-ref-types expr env)
    (if (not (= (length expr) 3))
        (error "Malformed vector reference" expr))
    (if (not (number? (caddr expr)))
        (error "Trying to access a computed vector slot" expr))
    (let ((accessee-type (loop (cadr expr) env)))
      (if (not (eq? 'vector (car accessee-type)))
          (error "Trying to VECTOR-REF a non-VECTOR"
                 accessee-type))
      (if (not (< (caddr expr) (length (cdr accessee-type))))
          (error "Index out of bounds"
                 (caddr expr) accessee-type))
      (select-by-access accessee-type expr)))
  (define (check-polymorphic-construction-types expr env)
    (let ((element-types (map (lambda (exp) (loop exp env)) (cdr expr))))
      (for-each
       (lambda (element-type index)
         (if (values-form? element-type)
             (error "Trying to put a VALUES shape into a data structure"
                    expr element-type index)))
       element-types
       (iota (length element-types)))
      (construct-type element-types (car expr))))
  (define (check-application-types expr env)
    (if (not (fol-var? (car expr)))
        (error "Calling a statically unknown procedure" expr))
    (let ((expected-types (arg-types (global-type (car expr))))
          (argument-types (map (lambda (exp) (loop exp env)) (cdr expr))))
      (if (not (= (length expected-types) (length argument-types)))
          (error "Trying to call function with wrong number of arguments"
                 expr))
      (for-each
       (lambda (expected given index)
         ;; TODO Type aliases for named or cons types would break this
         ;; test.
         (if (not (equal? expected given))
             (error "Mismatched argument at function call"
                    expr index expected given)))
       expected-types
       argument-types
       (iota (length argument-types)))
      (return-type (global-type (car expr)))))
  (loop expr env))

(define (empty-type-env) (make-strong-eq-hash-table))
(define (augment-type-env! env names shapes)
  (for-each (lambda (name shape)
              (hash-table/put! env name
                               (cons shape (hash-table/get env name '()))))
            names shapes)
  env)
(define (lookup-type name env)
  (define (lose) (error "Refencing an unbound variable" name))
  (hash-table/lookup env name
   (lambda (stack) (if (null? stack) (lose) (car stack)))
   lose))
(define (degment-type-env! env names)
  (define (lose) (error "Degmenting an unbound variable" name))
  (for-each (lambda (name)
              (hash-table/lookup
               env name
               (lambda (stack)
                 (if (null? stack)
                     (lose)
                     (if (null? (cdr stack))
                         (hash-table/remove! env name)
                         (hash-table/put! env name (cdr stack)))))
               lose))
            names)
  env)

(define (check-unique-names names message)
  (pair-for-each
   (lambda (names)
     (if (memq (car names) fol-reserved)
         (error "Trying to bind reserved name" (car names)))
     (if (memq (car names) (cdr names))
         (error message (car names))))
   names))

;;; A type map maps the name of any FOL type to an object representing
;;; that type.  I implement this as a hash table.  This is useful here
;;; to type-check FOL, and will also be used for other FOL stages that
;;; need to look up FOL type information.

(define (type-map program)
  (let ((type-map (make-eq-hash-table)))
    (for-each
     (lambda (basic-type)
       (hash-table/put! type-map basic-type basic-type))
     '(real bool gensym escaping-function))
    (define (check-valid-type-level ok-constructors type)
      (cond ((fol-var? type)
             (if (hash-table/get type-map type #f)
                 'ok
                 (error "Referencing unknown type name" type)))
            ((pair? type)
             (if (not (list? type))
                 (error "Malformed type spec" type))
             (if (not (memq (car type) ok-constructors))
                 (error "Incorrect type constructor" type))
             (if (and (eq? 'cons (car type)) (not (= 2 (length (cdr type)))))
                 (error "Wrong size cons" type)))
            ((null? type) 'ok)
            (else (error "Malformed type spec" type))))
    (define (check-valid-anonymous-type type)
      (check-valid-type-level '(cons vector values) type)
      (if (pair? type)
          (for-each check-valid-anonymous-type (cdr type))))
    (define (check-valid-named-type type)
      (check-valid-type-level '(structure) type)
      (if (pair? type)
          (for-each check-valid-anonymous-type (map cadr (cdr type)))))
    (if (begin-form? program)
        (let ((type-defns (filter type-definition? program)))
          (for-each
           (lambda (name) (hash-table/put! type-map name #t))
           (map cadr type-defns))
          (for-each
           (lambda (defn)
             (let ((name (cadr defn))
                   (body (caddr defn)))
               (check-valid-named-type body)
               (hash-table/put! type-map name body)))
           type-defns)
          (for-each
           (rule `(define ((? name ,fol-var?) (?? formals))
                    (argument-types (?? args) (? return))
                    (? body))
                 (begin
                   (for-each check-valid-anonymous-type args)
                   (check-valid-anonymous-type return)))
           program))
        'ok)
    type-map))

;;; Every structure type defintion of the form (define-type foo (structure (bar real)))
;;; defines implicit constructor and accessor procedures, in this case
;;; make-foo :: real -> foo and foo-bar :: foo -> real.  This function
;;; computes the names and types of those procedures from a type map.
(define (implicit-procedures type-map)
  (append-map
   (lambda (pair)
     (let ((name (car pair))
           (type (cdr pair)))
       (if (structure-type? type)
           (let ((fields (map car (cdr type)))
                 (types (map cadr (cdr type))))
             `((,(symbol 'make- name) . ,(function-type types name))
               ,@(map (lambda (field type)
                        (cons (symbol name '- field)
                              (function-type (list name) type)))
                      fields types)))
           '())))
   (hash-table->alist type-map)))

;;; A procedure type map maps the name of any FOL procedure to a function-type
;;; object representing its argument types and return type.  I
;;; implement this as a hash table backed procedure that returns that
;;; information when given the name in question, or #f if the given
;;; name is not the name of a global procedure.  This is useful here
;;; to type-check FOL, and will also be used for other FOL stages that
;;; need to look up type information of FOL procedures.

;; TODO require the type map argument when all call sites supply it.
(define (procedure-type-map program #!optional type-map)
  (define (make-initial-type-map)
    (alist->eq-hash-table
     (map (lambda (prim)
            (cons (primitive-name prim) (primitive-type prim)))
          *primitives*)))
  (let ((procedure-type-map (make-initial-type-map)))
    (if (not (default-object? type-map))
        (hash-table/put-alist!
         procedure-type-map (implicit-procedures type-map)))
    (if (begin-form? program)
        (for-each
         (rule `(define ((? name ,fol-var?) (?? formals))
                  (argument-types (?? args) (? return))
                  (? body))
               (hash-table/put!
                procedure-type-map name (function-type args return)))
         (cdr program))
        'ok)
    (define (lookup-type name)
      (or (hash-table/get procedure-type-map name #f)
          (error "Looking up unknown name" name)))
    lookup-type))

(define (equal-type? type1 type2)
  (cond ((and (function-type? type1) (function-type? type2))
         (and (equal-type? (arg-types type1) (arg-types type2))
              (equal-type? (return-type type1) (return-type type2))))
        ((and (pair? type1) (pair? type2))
         (and (equal-type? (car type1) (car type2))
              (equal-type? (cdr type1) (cdr type2))))
        (else (equal? type1 type2))))

;;;; Types

;;; Some procedures for manipulating (the syntactic structure of) FOL
;;; types.

(define (construct-type subshapes kind)
  `(,kind ,@subshapes))

(define (primitive-type? type)
  (or (function-type? type)
      (memq type '(real bool gensym escaping-function))))

(define (type-factors type)
  (cond ((construction? type)
         (cdr type))
        ((values-form? type)
         (cdr type))
        ((primitive-type? type)
         (list type))
        ((structure-type? type)
         (map cadr (cdr type)))
        ((and *type-map* (hash-table/get *type-map* type #f))
         (type-factors (hash-table/get *type-map* type #f)))
        (else (error "Weird type" type))))
