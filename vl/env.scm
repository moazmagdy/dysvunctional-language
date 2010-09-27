;;;; Environments

;;; In this code, environments are flat, restricted to the variables
;;; actually referenced by the closure whose environment it is, and
;;; sorted by the bound names.  This canonical form much simplifies
;;; comparing and unioning them during the abstract analysis.

(define-structure (env (safe-accessors #t) (constructor %make-env))
  bindings)

(define (make-env bindings)
  (%make-env
   (sort
    bindings
    (lambda (binding1 binding2)
      (symbol<? (car binding1) (car binding2))))))

(define (lookup exp env)
  (if (constant? exp)
      exp
      (let scan ((bindings (env-bindings env)))
	(if (null? bindings)
	    (error "Variable not found" exp)
	    (if (eq? exp (caar bindings))
		(cdar bindings)
		(scan (cdr bindings)))))))

(define (append-bindings new-bindings old-bindings)
  (append new-bindings
	  (remove-from-bindings
	   (map car new-bindings)
	   old-bindings)))

(define (remove-from-bindings symbols bindings)
  (filter (lambda (binding)
	    (not (memq (car binding) symbols)))
	  bindings))

(define (formal-bindings formal arg)
  (let walk ((name-tree (car formal))
	     (value-tree arg))
    (cond ((null? name-tree)
	   '())
	  ((symbol? name-tree)
	   (list (cons name-tree value-tree)))
	  ((and (pair? name-tree) (pair? value-tree))
	   (if (eq? (car name-tree) 'cons)
	       (append (walk (cadr name-tree) (car value-tree))
		       (walk (caddr name-tree) (cdr value-tree)))
	       (append (walk (car name-tree) (car value-tree))
		       (walk (cdr name-tree) (cdr value-tree)))))
	  (else
	   (error "Mismatched formal and actual parameter trees"
		  formal arg)))))

(define (extend-env env formal-tree arg)
  (if (env? env)
      (make-env (append-bindings (formal-bindings formal-tree arg)
				 (env-bindings env)))
      (extend-env arg env formal-tree)))

(define vl-user-env #f)

(define (initial-vl-user-env)
  (make-env
   (map (lambda (primitive)
	  (cons (primitive-name primitive) primitive))
	*primitives*)))

(define (initialize-vl-user-env)
  (set! vl-user-env (initial-vl-user-env)))
