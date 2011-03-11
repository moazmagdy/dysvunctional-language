(load-relative "../../testing/load")

(define (analyzed-answer program)
  (let ((candidate
	 (let ((full-prog (macroexpand program)))
	   (let loop ((bindings (analysis-bindings (analyze program))))
	     (cond ((null? bindings) #f)
		   ((equal? full-prog (binding-exp (car bindings)))
		    (car bindings))
		   (else (loop (cdr bindings))))))))
    (if (not candidate)
	(error "Analysis makes no binding for the original program"
	       program)
	(binding-value candidate))))

(define (determined-form-breakage value form)
  (cond ((not (equal? (macroexpand form) (macroexpand (macroexpand form))))
	 `(not (equal? ,(macroexpand form) ,(macroexpand (macroexpand form)))))
	((not (equal? value (dvl-eval form #t)))
	 `(not (equal? ,value (interpreted ,(dvl-eval form #t)))))
	((not (equal? value (analyzed-answer form)))
	 `(not (equal? ,value (analyzed ,(analyzed-answer form)))))
	((not (equal? `(begin ,value) (analyze-and-generate form)))
	 `(not (equal? ,value (compiled ,(analyze-and-generate form)))))
	(else #f)))

(define (%scheme-eval code)
  (eval code (nearest-repl/environment)))

(define (eval-through-scheme program)
  (let* ((interpreted-answer (dvl-eval program #t))
	 (analysis (analyze program))
	 (compiled-program (generate program analysis))
	 (compiled-answer (%scheme-eval compiled-program))
	 (pretty-compiled-answer (%scheme-eval (prettify-compiler-output compiled-program)))
	 (direct-pretty-compiled-answer (%scheme-eval (compile-to-scheme program))))
    (if (and (equal? interpreted-answer compiled-answer)
	     (equal? interpreted-answer pretty-compiled-answer)
	     (equal? interpreted-answer direct-pretty-compiled-answer))
	compiled-answer
	(error "DVL compiler disagreed with DVL interpreter"
	       `((interpreted: ,interpreted-answer)
		 (compiled: ,compiled-answer)
		 (compiled-and-prettified ,pretty-compiled-answer)
		 (pretty-compiled ,direct-pretty-compiled-answer))))))

(in-test-group
 dvl
 (define-each-check
   (not (determined-form-breakage 3 '(+ 1 2)))
   (not (determined-form-breakage #f '(gensym= (gensym) (gensym))))
   (not (determined-form-breakage #t '(let ((x (gensym))) (gensym= x x))))
   (not (determined-form-breakage #f '(let ((x (gensym))) (gensym= x (gensym)))))

   (equal? #t (eval-through-scheme
	       '(let ((x (gensym))) (gensym= x (if (> (real 2) (real 1)) x (gensym))))))
   (equal? #f (eval-through-scheme
	       '(let ((x (gensym))) (gensym= x (if (< (real 2) (real 1)) x (gensym))))))
   )

 (with-input-from-file "../vl/examples.scm"
   (lambda ()
     (let loop ((program (read)))
       (if (not (eof-object? program))
	   (begin (define-test
		    ;; Check that dvl-eval and compile-to-scheme agree
		    (eval-through-scheme program))
		  (loop (read)))))))

 (with-input-from-file "../vl/test/test-vl-programs.scm"
   (lambda ()
     (let loop ((program (read)))
       (if (not (eof-object? program))
	   (begin (define-test
		    ;; Check that dvl-eval and compile-to-scheme agree
		    (eval-through-scheme program))
		  (loop (read)))))))

 ;; TODO Make the tangent-of-function test acceptably fast
 #;
 (define-test (tangent-of-function)
   (check (equal? 1 (eval-through-scheme
                     (dvl-prepare
                      '(let ()
                         (define (adder n)
                           (lambda (x)
                             (g:+ x n)))
                         (((derivative adder) (real 3)) (real 4))))))))
 )
