(declare (usual-integrations))

(define (minimum-by cost list win)
  (if (null? list)
      (error "empty list")
      (let loop ((x0 (car list))
                 (c0 (cost (car list)))
                 (xs (cdr list)))
        (if (null? xs)
            (win x0 c0)
            (let* ((x (car xs))
                   (c (cost x)))
              (if (< c c0)
                  (loop x c (cdr xs))
                  (loop x0 c0 (cdr xs))))))))

(define (acceptable-inlinees threshold graph)
  (define-structure (node safe-accessors)
    out-edges
    in-edges
    size)

  (define (multiplicity name map)
    (hash-table/get map name 0))

  (define (out-multiplicity name node)
    (multiplicity name (node-out-edges node)))

  (define (in-multiplicity name node)
    (multiplicity name (node-in-edges node)))

  (define (total-degree map)
    (hash-table/fold + 0 map))

  (define (total-out-degree node)
    (total-degree (node-out-edges node)))

  (define (total-in-degree node)
    (total-degree (node-in-edges node)))

  (define (add-out-edge! name1 name2)
    (hash-table/adjust!
     (lambda (node1)
       (hash-table/insert-with! + name2 1 (node-out-edges node1))
       node1)
     name1
     node-map))

  (define (add-in-edge! name1 name2)
    (hash-table/adjust!
     (lambda (node1)
       (hash-table/insert-with! + name2 1 (node-in-edges node1))
       node1)
     name1
     node-map))

  (define (attach-edge! name1 name2)
    (add-out-edge! name1 name2)
    (add-in-edge!  name2 name1))

  ;; NODE-MAP is a hash-table mapping names (symbols) to NODE objects.
  (define node-map (make-eq-hash-table))
  ;; RECORD is of the shape (NAME . (SIZE . NEIGHBORS)).
  (define (insert-vertex! record)
    (let ((name      (car  record))
          (neighbors (cddr record)))
      (for-each
       (lambda (neighbor)
         (attach-edge! name neighbor))
       neighbors)))
  (for-each
   (lambda (record)
     (let ((name (car  record))
           (size (cadr record)))
       (hash-table/put!
        node-map
        name
        (make-node
         (make-eq-hash-table)
         (make-eq-hash-table)
         size))))
   graph)
  (for-each insert-vertex! graph)

  (define (inline-cost node)
    (* (node-size node)
       ;; The -1 here approximates the size benefit of eliminating the
       ;; procedure definition once all instances have been inlined.
       ;; It's not quite right, though, because the node size is
       ;; exclusive of type annotations, whereas the definition being
       ;; removed is not.  Oh well.
       (- (total-in-degree node) 1)))

  (define (inline-node! name)
    (hash-table/lookup
     node-map
     name
     (lambda (node)
       (%inline-node! name node))
     (lambda () #f)))

  (define (%inline-node! name node)
    (define (update-out-neighbor! neighbor-name)
      (hash-table/adjust-with-key!
       %update-out-neighbor!
       neighbor-name
       node-map))
    (define (update-in-neighbor! neighbor-name)
      (hash-table/adjust-with-key!
       %update-in-neighbor!
       neighbor-name
       node-map))
    (define (%update-out-neighbor! neighbor-name neighbor-node)
      (let ((d (multiplicity neighbor-name (node-out-edges node))))
        (hash-table/remove! (node-in-edges neighbor-node) name)
        (hash-table/for-each
         (node-in-edges node)
         (lambda (in-node-name in-node-multiplicity)
           (hash-table/insert-with!
            +
            in-node-name
            (* d in-node-multiplicity)
            (node-in-edges neighbor-node))))
        neighbor-node))
    (define (%update-in-neighbor! neighbor-name neighbor-node)
      (let ((d (multiplicity neighbor-name (node-in-edges node))))
        (hash-table/remove! (node-out-edges neighbor-node) name)
        (hash-table/for-each
         (node-out-edges node)
         (lambda (out-node-name out-node-multiplicity)
           (hash-table/insert-with!
            +
            out-node-name
            (* d out-node-multiplicity)
            (node-out-edges neighbor-node))))
        (set-node-size! neighbor-node
                        (+ (node-size neighbor-node)
                           (* d (node-size node))))
        neighbor-node))
    (hash-table/remove! node-map name)
    (for-each
     update-out-neighbor!
     (hash-table/key-list (node-out-edges node)))
    (for-each
     update-in-neighbor!
     (hash-table/key-list (node-in-edges node))))

  (define (prune inlinees old-cost-increase)
    (define (inlinable? name node)
      (zero? (out-multiplicity name node)))
    (let ((inlinable '()))
      (hash-table/for-each
       node-map
       (lambda (name node)
         (if (inlinable? name node)
             (set! inlinable
                   (cons (cons name (inline-cost node))
                         inlinable)))))
      (if (null? inlinable)
          inlinees
          (minimum-by
           cdr
           inlinable
           (lambda (candidate candidate-cost)
             (let ((candidate-name (car candidate))
                   (new-cost-increase (+ old-cost-increase
                                      candidate-cost)))
               (if (<= new-cost-increase threshold)
                   (begin
                     (inline-node! candidate-name)
                     (prune (cons candidate-name inlinees)
                            new-cost-increase))
                   inlinees)))))))
  (prune '() 0))
