#|
TODO:
- parsing try/catch
* parsing typealias
* semicolons in argument lists, for keywords
|#

(define ops-by-prec
  '#((= := += -= *= /= //= .//= .*= ./= |\\=| |.\\=| ^= .^= %= |\|=| &= $= => <<= >>=)
     (?)
     (|\|\||)
     (&&)
     ; note: there are some strange-looking things in here because
     ; the way the lexer works, every prefix of an operator must also
     ; be an operator.
     (-> <- -- -->)
     (> < >= <= == != |.>| |.<| |.>=| |.<=| |.==| |.!=| |.=| |.!| |<:| |:>|)
     (: ..)
     (<< >>)
     (+ - |\|| $)
     (* / // .// |./| % & |.*| |\\| |.\\|)
     (^ |.^|)
     (|::|)
     (|.|)))

(define (prec-ops n) (vector-ref ops-by-prec n))

; unused characters: @ prefix'
; no character literals; unicode kind of makes them obsolete. strings instead.

(define unary-ops '(- + ! ~ $))

; operators that are special forms, not function names
(define syntactic-operators
  '(= := += -= *= /= //= .//= .*= ./= |\\=| |.\\=| ^= .^= %= |\|=| &= $= =>
      <<= >>= -> --> |\|\|| && : |::| |.|))
(define syntactic-unary-operators '($))

(define reserved-words '(begin while if for try function type typealias local
			       return break continue struct global macro))

(define (syntactic-op? op) (memq op syntactic-operators))
(define (syntactic-unary-op? op) (memq op syntactic-unary-operators))

(define trans-op (string->symbol ".'"))
(define ctrans-op (string->symbol "'"))
(define vararg-op (string->symbol "..."))

(define operators (list* '~ ctrans-op trans-op vararg-op
			 (delete-duplicates
			  (apply append (vector->list ops-by-prec)))))

(define op-chars
  (delete-duplicates
   (apply append
	  (map string->list (map symbol->string operators)))))

; --- lexer ---

(define special-char?
  (let ((chrs (string->list "()[]{},;`")))
    (lambda (c) (memv c chrs))))
(define (newline? c) (eqv? c #\newline))
(define (identifier-char? c) (or (and (char>=? c #\A)
				      (char<=? c #\Z))
				 (and (char>=? c #\a)
				      (char<=? c #\z))
				 (and (char>=? c #\0)
				      (char<=? c #\9))
				 (eqv? c #\_)))
(define (opchar? c) (memv c op-chars))
(define (operator? c) (memq c operators))

(define (skip-ws port newlines?)
  (let ((c (peek-char port)))
    (if (and (not (eof-object? c)) (char-whitespace? c)
	     (or newlines? (not (newline? c))))
	(begin (read-char port)
	       (skip-ws port newlines?)))))

(define (skip-to-eol port)
  (let ((c (peek-char port)))
    (cond ((eof-object? c)    c)
	  ((eqv? c #\newline) c)
	  (else               (read-char port)
			      (skip-to-eol port)))))

; pred - should we consider a character?
; valid - does adding the next character to the token produce
;         a valid token?
(define (accum-tok c pred valid port)
  (let loop ((str '())
	     (c c)
	     (first? #t))
    (if (and (not (eof-object? c)) (pred c)
	     (or first?
		 (valid (string-append (list->string (reverse str))
				       (string c)))))
	(begin (read-char port)
	       (loop (cons c str) (peek-char port) #f))
	(list->string (reverse str)))))

(define (yes x) #t)

(define (read-number port . leadingdot)
  (let ((str (open-output-string)))
    (define (allow ch)
      (let ((c (peek-char port)))
	(and (eqv? c ch)
	     (begin (write-char (read-char port) str) #t))))
    (define (read-digs)
      (let ((d (accum-tok (peek-char port) char-numeric? yes port)))
	(and (not (equal? d ""))
	     (not (eof-object? d))
	     (display d str)
	     #t)))
    (if (pair? leadingdot)
	(write-char #\. str)
	(allow #\.))
    (read-digs)
    (allow #\.)
    (read-digs)
    (if (or (allow #\e) (allow #\E))
	(begin (or (allow #\+) (allow #\-))
	       (read-digs)))
    (let* ((s (get-output-string str))
	   (n (string->number s)))
      (if n n
	  (error "Invalid numeric constant " s)))))

(define (read-operator port c)
  (string->symbol
   (accum-tok c opchar?
	      (lambda (x) (operator? (string->symbol x)))
	      port)))

(define (skip-ws-and-comments port)
  (skip-ws port #t)
  (if (eqv? (peek-char port) #\#)
      (begin (skip-to-eol port)
	     (skip-ws-and-comments port)))
  #t)

(define (next-token port)
  (skip-ws port #f)
  (let ((c (peek-char port)))
    (cond ((or (eof-object? c) (newline? c) (special-char? c))
	   (read-char port))

	  ((eqv? c #\#) (skip-to-eol port) (next-token port))
	  
	  ((char-numeric? c) (read-number port))
	  
	  ; . is difficult to handle; it could start a number or operator
	  ((and (eqv? c #\.)
		(let ((c (read-char port))
		      (nextc (peek-char port)))
		  (cond ((char-numeric? nextc)
			 (read-number port c))
			((opchar? nextc)
			 (string->symbol
			  (string-append (string c)
					 (symbol->string
					  (read-operator port nextc)))))
			(else '|.|)))))
	  
	  ((opchar? c)  (read-operator port c))

	  ((identifier-char? c) (string->symbol (accum-tok c identifier-char?
							   yes port)))

	  ((eqv? c #\")  (read port))

	  (else (error "Invalid character" (read-char port))))))

; --- parser ---

(define (make-token-stream s) (vector #f s))
(define (ts:port s)       (vector-ref s 1))
(define (ts:last-tok s)   (vector-ref s 0))
(define (ts:set-tok! s t) (vector-set! s 0 t))

(define (peek-token s)
  (let ((port     (ts:port s))
	(last-tok (ts:last-tok s)))
    (if last-tok last-tok
	(begin (ts:set-tok! s (next-token port))
	       (ts:last-tok s)))))

(define (require-token s)
  (define (req-token s)
    (let ((port     (ts:port s))
	  (last-tok (ts:last-tok s)))
      (if (and last-tok (not (eof-object? last-tok)))
	  last-tok
	  (let ((t (next-token port)))
	    (if (eof-object? t)
		(error "Premature end of input")
		(begin (ts:set-tok! s t)
		       (ts:last-tok s)))))))
  (let ((t (req-token s)))
    ; when an actual token is needed, skip newlines
    (if (newline? t)
	(begin (take-token s)
	       (require-token s))
	t)))

(define (take-token s)
  (begin0 (ts:last-tok s)
	  (ts:set-tok! s #f)))

; parse left-to-right binary operator
; produces structures like (+ (+ (+ 2 3) 4) 5)
(define (parse-LtoR s down ops)
  (let loop ((ex (down s)))
    (let ((t (peek-token s)))
      (if (not (memq t ops))
	  ex
	  (begin (take-token s)
		 (if (syntactic-op? t)
		     (loop (list t ex (down s)))
		     (loop (list 'call t ex (down s)))))))))

; parse right-to-left binary operator
; produces structures like (= a (= b (= c d)))
(define (parse-RtoL s down ops)
  (let ((ex (down s)))
    (let ((t (peek-token s)))
      (if (not (memq t ops))
	  ex
	  (begin (take-token s)
		 (if (syntactic-op? t)
		     (list t ex (parse-RtoL s down ops))
		     (list 'call t ex (parse-RtoL s down ops))))))))

(define (parse-cond s)
  (let ((ex (parse-or s)))
    (if (not (eq? (peek-token s) '?))
	ex
	(begin (take-token s)
	       (let ((then (parse-shift s)))
		 (if (not (eq? (take-token s) ':))
		     (error "colon expected in ? expression")
		     (let ((els  (parse-shift s)))
		       (if (eq? (peek-token s) ':)
			   (error "ambiguous use of colon in ? expression")
			   (list 'if ex then els)))))))))

(define (invalid-initial-token? tok)
  (or (eof-object? tok)
      (memv tok '(#\) #\] #\} else elseif catch))))

; parse a@b@c@... as (@ a b c ...) for some operator @
; op: the operator to look for
; head: the expression head to yield in the result, e.g. "a;b" => (block a b)
; closers: a list of tokens that will stop the process
;          however, this doesn't consume the closing token, just looks at it
; allow-empty: if true will ignore runs of the operator, like a@@@@b
; ow, my eyes!!
(define (parse-Nary s down op head closers allow-empty)
  (if (invalid-initial-token? (require-token s))
      (error "Unexpected token" (peek-token s)))
  (if (memv (require-token s) closers)
      (list head)  ; empty block
      (let loop ((ex
                  ; in allow-empty mode skip leading runs of operator
		  (if (and allow-empty (eqv? (require-token s) op))
		      '()
		      (list (down s))))
		 (first? #t))
	(let ((t (peek-token s)))
	  (if (not (eqv? t op))
	      (if (or (null? ex) (pair? (cdr ex)) (not first?))
	          ; () => (head)
	          ; (ex2 ex1) => (head ex1 ex2)
	          ; (ex1) ** if operator appeared => (head ex1) (handles "x;")
		  (cons head (reverse ex))
	          ; (ex1) => ex1
		  (car ex))
	      (begin (take-token s)
		     ; allow input to end with the operator, as in a;b;
		     (if (or (eof-object? (peek-token s))
			     (memv (peek-token s) closers)
			     (and allow-empty
				  (eqv? (peek-token s) op)))
			 (loop ex #f)
			 (loop (cons (down s) ex) #f))))))))

; colon is strange; 3 arguments with 2 colons yields one call:
; 1:2   => (: 1 2)
; 1:2:3 => (: 1 2 3)
; 1:    => (: 1 :)
; :2    => (: 2)
; 1:2:  => (: 1 2 :)
; :1:2  => (: (: 1 2))
; :1:   => (: (: 1 :))
; a simple state machine is up to the task.
; we will leave : expressions as a syntax form, not a call to ':',
; so they can be processed by syntax passes.
(define (parse-range s)
  (if (eq? (peek-token s) ':)
      (begin (take-token s)
	     (if (closing-token? (peek-token s))
		 ':
		 (list ': (parse-range s))))
      (let loop ((ex (parse-shift s))
		 (first? #t))
	(let ((t (peek-token s)))
	  (if (not (eq? t ':))
	      ex
	      (begin (take-token s)
		     (let ((argument
			    (if (closing-token? (peek-token s))
				':  ; missing last argument
				(parse-shift s))))
		       (if first?
			   (loop (list t ex argument) #f)
			   (loop (append ex (list argument)) #t)))))))))

; the principal non-terminals follow, in increasing precedence order

(define (parse-block s) (parse-Nary s parse-block-stmts #\newline 'block
				    '(end else elseif catch) #t))
(define (parse-block-stmts s) (parse-Nary s parse-eq #\; 'block
					  '(end else elseif catch #\newline)
					  #t))
(define (parse-stmts s) (parse-Nary s parse-eq    #\; 'block '(#\newline) #t))

(define (parse-eq s)    (parse-RtoL s parse-comma (prec-ops 0)))
; parse-eq* is used where commas are special, for example in an argument list
(define (parse-eq* s)   (parse-RtoL s parse-cond  (prec-ops 0)))
; parse-comma is needed for commas outside parens, for example a = b,c
(define (parse-comma s) (parse-Nary s parse-cond  #\, 'tuple '( #\) ) #f))
(define (parse-or s)    (parse-LtoR s parse-and   (prec-ops 2)))
(define (parse-and s)   (parse-LtoR s parse-arrow (prec-ops 3)))
(define (parse-arrow s) (parse-RtoL s parse-ineq  (prec-ops 4)))
(define (parse-ineq s)  (parse-comparison s (prec-ops 5)))
		      ; (parse-LtoR s parse-range (prec-ops 5)))
;(define (parse-range s) (parse-LtoR s parse-shift  (prec-ops 6)))
(define (parse-shift s) (parse-LtoR s parse-expr (prec-ops 7)))
(define (parse-expr s)  (parse-LtoR/chains s parse-term  (prec-ops 8) '(+)))
;(define (parse-term s)  (parse-LtoR/chains s parse-unary (prec-ops 9) '(*)))

; parse left to right, combining chains of certain operators into 1 call
; e.g. a+b+c => (call + a b c)
(define (parse-LtoR/chains s down ops chain-ops)
  (let loop ((ex       (down s))
	     (chain-op #f))
    (let ((t (peek-token s)))
      (cond ((not (memq t ops))
	     ex)
	    ((eq? t chain-op)
	     (begin (take-token s)
		    (loop (append ex (list (down s)))
			  chain-op)))
	    (else
	     (begin (take-token s)
		    (loop (list 'call t ex (down s))
			  (and (memq t chain-ops) t))))))))

; given an expression and the next token, is there a juxtaposition
; operator between them?
(define (juxtapose? expr t)
  (and (not (operator? t))
       (not (closing-token? t))
       (not (newline? t))
       (or (number? expr)
	   (not (memv t '(#\( #\[ #\{))))))

(define (parse-term s)
  (let ((ops (prec-ops 9)))
    (let loop ((ex       (parse-unary s))
	       (chain-op #f))
      (let ((t (peek-token s)))
	(cond ((juxtapose? ex t)
	       (if (eq? chain-op '*)
		   (loop (append ex (list (parse-unary s)))
			 chain-op)
		   (loop (list 'call '* ex (parse-unary s))
			 '*)))
	      ((not (memq t ops))
	       ex)
	      ((eq? t chain-op)
	       (begin (take-token s)
		      (loop (append ex (list (parse-unary s)))
			    chain-op)))
	      (else
	       (begin (take-token s)
		      (loop (list 'call t ex (parse-unary s))
			    (and (memq t '(*)) t)))))))))

(define (parse-comparison s ops)
  (let loop ((ex (parse-range s))
	     (first #t))
    (let ((t (peek-token s)))
      (if (not (memq t ops))
	  ex
	  (begin (take-token s)
		 (if first
		     (loop (list 'comparison ex t (parse-range s)) #f)
		     (loop (append ex (list t (parse-range s))) #f)))))))

; flag an error for tokens that cannot begin an expression
(define (closing-token? tok)
  (or (eof-object? tok)
      (memv tok '(#\, #\) #\] #\} #\; end else elseif catch))))

(define (parse-unary s)
  (let ((t (require-token s)))
    (if (closing-token? t)
	(error "Unexpected token" t))
    (if (memq t unary-ops)
	(let ((op (take-token s))
	      (next (peek-token s)))
	  (if (closing-token? next)
	      ; return operator by itself, as in (+)
	      op
	      (if (syntactic-unary-op? op)
		  (list op (parse-unary s))
		  (list 'call op (parse-unary s)))))
	(parse-factor s))))

; handle ^, .^, and postfix transpose operator
(define (parse-factor-h s down ops)
  (let ((ex (down s)))
    (let ((t (peek-token s)))
      (cond ((eq? t ctrans-op)
	     (take-token s)
	     (list 'call 'ctranspose ex))
	    ((eq? t trans-op)
	     (take-token s)
	     (list 'call 'transpose ex))
	    ((not (memq t ops))
	     ex)
	    (else
	     (list 'call
		   (take-token s) ex (parse-factor-h s parse-unary ops)))))))

; -2^3 is parsed as -(2^3), so call parse-call for the first argument,
; and parse-unary from then on (to handle 2^-3)
(define (parse-factor s)
  (parse-factor-h s parse-decl (prec-ops 10)))

(define (parse-decl s) (parse-LtoR s parse-call (prec-ops 11)))

; parse function call, indexing, dot, and :: expressions
; also handles looking for syntactic reserved words
(define (parse-call s)
  (define (loop ex)
    (let ((t (peek-token s)))
      (case t
	((|.|)
	 (loop (list (take-token s) ex (parse-atom s))))
	((#\( )   (take-token s)
	 ; some names are syntactic and not function calls
	 (cond ((eq? ex 'do)
		(loop (list* 'block   (parse-arglist s #\) ))))
	       ((eq? ex 'quote)
		(loop (list* ex       (parse-arglist s #\) ))))
	       (else
		(loop (list* 'call ex (parse-arglist s #\) ))))))
	((#\[ )   (take-token s)
	 ; ref is syntax, so we can distinguish
	 ; a[i] = x  from
	 ; ref(a,i) = x  which is invalid
	 (loop (list* 'ref  ex (parse-arglist s #\] ))))
	(else ex))))
  
  (let* (#;(do-kw? (not (eqv? (peek-token s) #\`)))
	 (ex (parse-atom s)))
    (if (and #;do-kw?
	 (memq ex reserved-words))
	(parse-resword s ex)
	(loop ex))))

;(define (parse-dot s)  (parse-LtoR s parse-atom (prec-ops 12)))

; parse expressions or blocks introduced by syntactic reserved words
(define (parse-resword s word)
  (define (expect-end s)
    (let ((t (peek-token s)))
      (if (eq? t 'end)
	  (take-token s)
	  (error "Expected end"))))
  (case word
    ((begin)  (begin0 (parse-block s)
		      (expect-end s)))
    ((while)  (begin0 (list 'while (parse-cond s) (parse-block s))
		      (expect-end s)))
    ((for)    (begin0 (list 'for (parse-eq* s) (parse-block s))
		      (expect-end s)))
    ((if)
     (let* ((test (parse-cond s))
	    (then (parse-block s))
	    (nxt  (require-token s)))
       (take-token s)
       (case nxt
	 ((end)     (list 'if test then))
	 ((elseif)  (list 'if test then (parse-resword s 'if)))
	 ((else)    (list 'if test then (parse-resword s 'begin)))
	 (else (error "Improperly terminated if statement")))))
    ((local)  (list 'local (parse-eq s)))
    ((function macro)
     (let ((sig (parse-call s)))
       (begin0 (list word sig (parse-block s))
	       (expect-end s))))
    ((struct)
     (let ((sig (parse-ineq s)))
       (begin0 (list word sig (parse-block s))
	       (expect-end s))))
    ((type)
     (list 'type (parse-ineq s)))
    ((typealias)
     (list 'typealias (parse-call s) (parse-arrow s)))
    ((try) #f ; TODO
     )
    ((return)          (list 'return (parse-eq s)))
    ((break continue)  (list word))
    (else (error "Unhandled reserved word"))))

; handle function call argument list, or any comma-delimited list.
; . an extra comma at the end is allowed
; . expressions after a ; are enclosed in (parameters ...)
; . an expression followed by ... becomes (... x)
(define (parse-arglist s closer)
  (let loop ((lst '()))
    (let ((t (require-token s)))
      (if (equal? t closer)
	  (begin (take-token s)
		 (reverse lst))
	  (if (equal? t #\;)
	      (begin (take-token s)
		     (if (equal? (peek-token s) closer)
			 ; allow f(a, b; )
			 (begin (take-token s)
				(reverse lst))
			 (reverse (cons (cons 'parameters (loop '()))
					lst))))
	      (let* ((nxt (parse-eq* s))
		     (c (peek-token s))
		     (nxt (if (eq? c '...)
			      (list '... nxt)
			      nxt))
		     (c (if (eq? c '...)
			    (begin (take-token s)
				   (peek-token s))
			    c)))
		(cond ((equal? c #\,)
		       (begin (take-token s) (loop (cons nxt lst))))
		      ((equal? c #\;)        (loop (cons nxt lst)))
		      ((equal? c closer)     (loop (cons nxt lst)))
		      (else (error "Comma expected")))))))))

; parse [] concatenation expressions
(define (parse-vector s)
  (define (fix head v) (cons head (reverse v)))
  (let loop ((vec '())
	     (outer '()))
    (let ((update-outer (lambda (v)
			  (cond ((null? v)       outer)
				((null? (cdr v)) (cons (car v) outer))
				(else            (cons (fix 'hcat v) outer))))))
      (if (eqv? (require-token s) #\])
	  (begin (take-token s)
		 (if (pair? outer)
		     (fix 'vcat (update-outer vec))
		     (fix 'hcat vec)))
	  (let ((nv (cons (parse-eq* s) vec)))
	    (case (require-token s)
	      ((#\]) (loop nv outer))
	      ((#\;) (begin (take-token s) (loop '() (update-outer nv))))
	      ((#\,) (begin (take-token s) (loop  nv outer)))
	      (else  (error "Comma expected"))))))))

; parse numbers, identifiers, parenthesized expressions, lists, vectors, etc.
(define (parse-atom s)
  (let ((t (require-token s)))
    (cond ((or (string? t) (number? t)) (take-token s))

	  ((eqv? t #\( )
	   (take-token s)
	   (if (eqv? (peek-token s) #\) )
	       (begin (take-token s) '(tuple))
	       ; here we parse the first subexpression separately, so
	       ; we can look for a comma to see if it's a tuple. if we
	       ; just called parse-arglist instead, we couldn't distinguish
	       ; (x) from (x,)
	       (let* ((ex (parse-eq* s))
		      (t (require-token s)))
		 (cond ((eqv? t #\) )
			(begin (take-token s) ex))
		       ((eqv? t #\, )
			(begin (take-token s)
			       (list* 'tuple ex (parse-arglist s #\) ))))
		       ((eq? t '...)
			(begin (take-token s)
			       (if (eqv? (peek-token s) #\,)
				   (take-token s))
			       (list* 'tuple (list '... ex)
				      (parse-arglist s #\) ))))
		       (else
			(error "Expected )"))))))

	  ((eqv? t #\{ )
	   (take-token s)
	   (cons 'list (parse-arglist s #\})))

	  ((eqv? t #\[ )
	   (take-token s)
	   (parse-vector s))

	  ((eqv? t #\` )
	   (take-token s)
	   (list 'quote (parse-decl s)))

	  (else (take-token s)))))

; --- main entry point ---

(define (julia-parse s)
  (cond ((string? s)
	 (julia-parse (make-token-stream (open-input-string s))))
	((port? s)
	 (julia-parse (make-token-stream s)))
	((eof-object? s)
	 s)
	(else
	 ; as a special case, allow early end of input if there is
	 ; nothing left but whitespace
	 (skip-ws-and-comments (ts:port s))
	 (if (eqv? (peek-token s) #\newline) (take-token s))
	 (let ((t (peek-token s)))
	   (if (eof-object? t)
	       t
	       (parse-stmts s))))))

(define (check-end-of-input s)
  (skip-ws-and-comments (ts:port s))
  (if (eqv? (peek-token s) #\newline) (take-token s))
  (if (not (eof-object? (peek-token s)))
      (error "Extra input after end of expression:"
	     (peek-token s))))

; call f on a stream until the stream runs out of data
(define (read-all-of f s)
  (let loop ((lines '())
	     (curr  (f s)))
    (if (eof-object? curr)
	(reverse lines)
	(loop (cons curr lines) (f s)))))

; for testing. generally no need to tokenize a whole stream in advance.
(define (julia-tokenize port)
  (read-all-of next-token port))

(define (julia-parse-file filename)
  (read-all-of julia-parse (make-token-stream (open-input-file filename))))
