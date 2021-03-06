;;; ----------------------------------------------------------------------
;;; Copyright 2010-2011 National University of Ireland.
;;; ----------------------------------------------------------------------
;;; This file is part of DysVunctional Language.
;;; 
;;; DysVunctional Language is free software; you can redistribute it and/or modify
;;; it under the terms of the GNU Affero General Public License as
;;; published by the Free Software Foundation, either version 3 of the
;;;  License, or (at your option) any later version.
;;; 
;;; DysVunctional Language is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;; 
;;; You should have received a copy of the GNU Affero General Public License
;;; along with DysVunctional Language.  If not, see <http://www.gnu.org/licenses/>.
;;; ----------------------------------------------------------------------

(declare (usual-integrations))

(define-structure
  (closure
   safe-accessors
   (constructor %make-closure (exp env))
   (print-procedure
    (simple-unparser-method 'closure
     (lambda (closure)
       (list (closure-exp closure)
             (closure-env closure))))))
  exp
  env
  (cached-abstract-hash #f))

(define (closure-formal closure)
  (lambda-formal (closure-exp closure)))

(define (closure-body closure)
  (lambda-body (closure-exp closure)))

(define (env-slice env variables)
  (make-env
   (filter (lambda (binding)
             (member (car binding) variables))
           (env-bindings env))))

;;; To keep environments in canonical form, closures only keep the
;;; variables they want.
(define (make-closure exp env)
  (let ((free (free-variables exp)))
    (%make-closure exp (env-slice env free))))

(define (closure-free-variables closure)
  (free-variables (closure-exp closure)))

(define (object-map f object)
  (cond ((closure? object)
         (make-closure (closure-exp object) (f (closure-env object))))
        ((env? object)
         (env-map f object))
        ((pair? object)
         (cons (f (car object)) (f (cdr object))))
        (else
         object)))

(define (congruent-map f object1 object2 lose)
  (cond ((and (closure? object1) (closure? object2)
              (equal? (closure-exp object1) (closure-exp object2)))
         (make-closure
          (closure-exp object1)
          (f (closure-env object1) (closure-env object2))))
        ((and (env? object1) (env? object2))
         (congruent-env-map f object1 object2 lose))
        ((and (pair? object1) (pair? object2))
         (cons (f (car object1) (car object2))
               (f (cdr object1) (cdr object2))))
        (else
         (lose))))

(define (object-reduce reducer object)
  (cond ((closure? object)
         (reducer (list (closure-env object))))
        ((env? object)
         (reducer (map cdr (env-bindings object))))
        ((pair? object)
         (reducer (list (car object) (cdr object))))
        ((binding? object)
         ;; See note in abstract-values for which this clause is here.
         (reducer (list (binding-part1 object) (binding-part2 object))))
        (else
         (reducer '()))))

(define (congruent-reduce reducer object1 object2 lose)
  (cond ((and (closure? object1) (closure? object2)
              (equal? (closure-exp object1) (closure-exp object2)))
         (reducer (list (closure-env object1))
                  (list (closure-env object2))))
        ((and (env? object1) (env? object2)
              (equal? (map car (env-bindings object1))
                      (map car (env-bindings object2))))
         (reducer (map cdr (env-bindings object1))
                  (map cdr (env-bindings object2))))
        ((and (pair? object1) (pair? object2))
         (reducer (list (car object1) (cdr object1))
                  (list (car object2) (cdr object2))))
        (else
         (lose))))

(define free-variables-cache (make-eq-hash-table))
(define free-variables
  (memoize free-variables-cache
   (lambda (form)
     (cond ((constant? form)
            '())
           ((variable? form)
            (list form))
           ((pair-form? form)
            (lset-union equal? (free-variables (car-subform form))
                        (free-variables (cdr-subform form))))
           ((lambda-form? form)
            (lset-difference equal? (free-variables (lambda-body form))
                             (free-variables (lambda-formal form))))
           ((pair? form)
            (lset-union equal? (free-variables (car form))
                        (free-variables (cdr form))))
           (else
            (syntax-error "Invalid expression type" form))))))

(define-structure
  (world
   safe-accessors
   (print-procedure
    (simple-unparser-method 'world
     (lambda (world)
       (list (world-gensym world))))))
  gensym)

(define (initial-world)
  (make-world 0))

;; IMPOSSIBLE-WORLD is a token that is always used together with
;; ABSTRACT-NONE.  If the shape of an expression evaluated in an
;; abstract environment and in a world is ABSTRACT-NONE (i.e.,
;; it is effectively unknown), then we also don't know how the
;; evaluation of this expression in this environment affects the
;; world, in which case we return IMPOSSIBLE-WORLD.
(define impossible-world (make-world #f))
(define (impossible-world? thing)
  (eq? thing impossible-world))

(define (world-equal? world1 world2)
  (equal? (world-gensym world1) (world-gensym world2)))

(define (union-world world1 world2)
  (cond ((impossible-world? world1) world2)
        ((impossible-world? world2) world1)
        (else
         (make-world
          (max (world-gensym world1) (world-gensym world2))))))

(define (current-gensym world)
  (make-gensym (world-gensym world)))

(define (do-gensym world)
  (make-world
   (+ 1 (world-gensym world))))
