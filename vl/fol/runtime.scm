(declare (usual-integrations))

;;;; Runtime system

;;; Here is the complement of definitions that needs to be loaded into
;;; MIT Scheme in order to execute FOL code (in addition to SRFI 11).

(define-syntax argument-types
  (syntax-rules ()
    ((_ arg ...)
     (begin))))

(define (real x)
  (if (real? x)
      x
      (error "A non-real object is asserted to be real" x)))

(define read-real read)

(define (write-real x)
  (write x)
  (newline)
  x)

(define-structure
  (gensym
   safe-accessors
   (print-procedure
    (simple-unparser-method 'gensym
     (lambda (gensym)
       (list (gensym-number gensym))))))
  number)

(define *the-gensym* 0)

(define (gensym)
  (set! *the-gensym* (+ *the-gensym* 1))
  (make-gensym (- *the-gensym* 1)))

(define (gensym= gensym1 gensym2)
  (= (gensym-number gensym1) (gensym-number gensym2)))