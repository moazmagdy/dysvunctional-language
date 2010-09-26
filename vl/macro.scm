(define (macroexpand exp)
  (cond ((variable? exp)
	 exp)
	((null? exp)
	 '())
	((pair? exp)
	 (cond ((eq? (car exp) 'lambda)
		`(lambda ,(macroexpand-formals (cadr exp))
		   ,(macroexpand (caddr exp))))
	       ((eq? (car exp) 'cons)
		`(cons ,(macroexpand (cadr exp))
		       ,(macroexpand (caddr exp))))
	       ((vl-macro? exp)
		(macroexpand (expand-vl-macro exp)))
	       (else
		`(,(macroexpand (car exp))
		  ,(macroexpand-operands (cdr exp))))))
	(else
	 (error "Invalid expression syntax" exp))))

(define (macroexpand-operands operands)
  (cond ((null? operands)
	 '())
	((null? (cdr operands))
	 (macroexpand (car operands)))
	(else
	 `(cons ,(macroexpand (car operands))
		,(macroexpand-operands (cdr operands))))))

(define (macroexpand-formals formals)
  (cond ((null? formals)
	 (list formals))
	((and (pair? formals) (null? (cdr formals)))
	 formals)
	((pair? formals)
	 (list
	  (let walk ((formals (apply cons* formals)))
	    (cond ((symbol? formals) formals)
		  ((null? formals) formals)
		  ((pair? formals)
		   (if (eq? (car formals) 'cons)
		       `(cons ,(walk (cadr formals))
			      ,(walk (caddr formals)))
		       `(cons ,(walk (car formals))
			      ,(walk (cdr formals)))))
		  (else
		   (error "Invalid formal parameter tree" formals))))))
	(else
	 (error "Invalid formal parameter tree" formals))))

(define *vl-macros* '())

(define (vl-macro? form)
  (memq (car form) (map car *vl-macros*)))

(define (expand-vl-macro form)
  (let ((transformer (assq (car form) *vl-macros*)))
    (if transformer
	((cdr transformer) form)
	(error "Undefined macro" form))))

(define (define-vl-macro! name transformer)
  (set! *vl-macros* (cons (cons name transformer) *vl-macros*)))

(define (normal-let-transformer form)
  (let ((bindings (cadr form))
	(body (cddr form)))
    `((lambda ,(map car bindings)
	,@body)
      ,@(map cadr bindings))))

(define (named-let-transformer form)
  (let ((name (cadr form))
	(bindings (caddr form))
	(body (cdddr form)))
    `(letrec ((,name (lambda ,(map car bindings)
		       ,@body)))
       (,name ,@(map cadr bindings)))))

(define-vl-macro! 'let
  (lambda (form)
    (if (symbol? (cadr form))
	(named-let-transformer form)
	(normal-let-transformer form))))

(define-vl-macro! 'if
  (lambda (form)
    `(if-procedure
      ,(cadr form)
      (lambda () ,(caddr form))
      (lambda () ,(cadddr form)))))

(define (letrec-transformer form)
  (let ((bindings (cadr form))
	(body (cddr form)))
    (cond ((= 0 (length bindings))
	   `(let ()
	      ,@body))
	  ((= 1 (length bindings))
	   (let ((bound-name (caar bindings))
		 (bound-form (cadar bindings)))
	     `(let ((the-Z-combinator
		     (lambda (f)
		       ((lambda (x)
			  (f (lambda (y)
			       ((x x) y))))
			(lambda (x)
			  (f (lambda (y)
			       ((x x) y))))))))
		(let ((,bound-name 
		       (the-Z-combinator
			(lambda (,bound-name)
			  ,bound-form))))
		  ,@body))))
	  (else
	   (let ((names (map car bindings))
		 (forms (map cadr bindings)))
	     (define (recursive-variant name)
	       `(,name ,@(map (lambda (name-1)
				`(lambda (y)
				   (Z* ,@names
				       (lambda (,@names)
					 (,name-1 y)))))
			      names)))
	     `(letrec ((Z* (lambda (,@names Z*-k)
			     (Z*-k ,@(map recursive-variant names)))))
		(Z* ,@(map (lambda (form)
			     `(lambda (,@names)
				,form))
			   forms)
		    (lambda (,@names)
		      ,@body))))))))

(define-vl-macro! 'letrec letrec-transformer)
