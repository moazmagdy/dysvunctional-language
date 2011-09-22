(declare (usual-integrations))
;;;; Simplistic FOL to Common Lisp compiler.

(define (compile-program program)
  (define (%compile-program program)
    (let ((inferred-type-map (make-eq-hash-table)))
      (check-program-types program inferred-type-map)
      (define (lookup-inferred-type expr)
        (or (hash-table/get inferred-type-map expr #f)
            (error "Looking up unknow expression" expr)))
      (define compile-definition
        (rule `(define ((? name ,fol-var?) (?? formals))
                 (argument-types (?? formal-types) (? return-type))
                 (? body))
              `(defun ,name (,@formals)
                 (declare ,@(map (lambda (formal-type formal)
                                   `(type ,(fol-shape->type-specifier formal-type)
                                          ,formal))
                                 formal-types
                                 formals))
                 ,(compile-expression body lookup-inferred-type))))
      (if (begin-form? program)
          `(progn
            (declaim (optimize (speed 3) (safety 0)))
            ,@prelude
            ,@(map compile-definition
                   (cdr (except-last-pair program)))
            ,(compile-expression (last program) lookup-inferred-type))
          (compile-expression program lookup-inferred-type))))
  (%compile-program (alpha-rename program)))

(define (fol-shape->type-specifier shape)
  (cond ((eq? 'real shape)
         'double-float)
        ((eq? 'bool shape)
         'boolean)
        ((null? shape)
         'null)
        ((eq? 'cons (car shape))
         `(cons ,(fol-shape->type-specifier (cadr  shape))
                ,(fol-shape->type-specifier (caddr shape))))
        ;; Heterogenious vector types are not supported by CL.
        ((eq? 'vector (car shape))
         `(simple-vector ,(length (cdr shape))))
        ((eq? 'values (car shape))
         `(values ,@(map fol-shape->type-specifier (cdr shape))))
        (else
         (error "Bogus shape " shape))))

(define prelude
  '((declaim (inline zero?
                     positive?
                     negative?
                     read-real
                     write-real
                     gensym=))
    (defun zero? (x)
      (declare (type double-float x))
      (zerop x))
    (defun positive? (x)
      (declare (type double-float x))
      (plusp x))
    (defun negative? (x)
      (declare (type double-float x))
      (minusp x))
    (defun read-real ()
      (read))
    (defun write-real (x)
      (declare (type double-float x))
      (format t "~F~%" x))
    (defun gensym= (gensym1 gensym2)
      (declare (type symbol gensym1 gensym2))
      (eq gensym1 gensym2))))

(define (compile-expression expr lookup-inferred-type)
  (define (%compile-expression expr)
    `(the ,(fol-shape->type-specifier (lookup-inferred-type expr))
          ,(%%compile-expression expr)))
  (define (%%compile-expression expr)
    (cond ((fol-var? expr) expr)
          ((fol-const? expr)
           (compile-const expr))
          ((if-form? expr)
           (compile-if expr))
          ((let-form? expr)
           (compile-let expr))
          ((let-values-form? expr)
           (compile-let-values expr))
          ((lambda-form? expr)
           (compile-lambda expr))
          ((vector-ref-form? expr)
           (compile-vector-ref expr))
          (else
           (compile-application expr))))
  (define (compile-const expr)
    (cond ((number? expr)
           `(coerce ,expr 'double-float))
          ((boolean? expr)
           (if expr 't 'nil))
          (else
           'nil)))
  (define compile-if
    (rule `(if (? pred)
               (? cons)
               (? alt))
          `(if ,(%compile-expression pred)
               ,(%compile-expression cons)
               ,(%compile-expression alt))))
  (define compile-let
    (rule `(let ((?? bindings))
             (? body))
          `(let (,@(map (lambda (binding)
                          `(,(car binding)
                            ,(%compile-expression (cadr binding))))
                        bindings))
             ,(%compile-expression body))))
  (define compile-let-values
    (rule `(let-values ((?? names) (? expr))
             (? body))
          `(muliple-values-bind (,@names)
                                ,(%compile-expression expr)
                                ,(%compile-expression body))))
  (define compile-lambda
    (rule `(lambda ((? var))
             (? body))
          `(function
            (lambda (,var)
              ,(%compile-expression body)))))
  (define compile-vector-ref
    (rule `(vector-ref (? expr) (? index))
          `(svref ,(%compile-expression expr) ,index)))
  (define vector-ref-form? (tagged-list? 'vector-ref))
  (define (compile-application expr)
    `(,(if  (eq? 'real (car expr))
            'identity
            (car expr))
      ,@(map %compile-expression (cdr expr))))
  (%compile-expression expr))
