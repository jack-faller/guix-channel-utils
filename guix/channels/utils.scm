(define-module (guix channels utils)
  #:use-module (guix gexp)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:export (git-toplevel relative-file git-source-file?))

(define (system*/quiet command . args)
  (with-output-to-file "/dev/null"
    (lambda ()
      (with-error-to-file "/dev/null"
        (lambda ()
          (apply system* command args))))))

(define (git-toplevel)
  (let* ((pipe (with-error-to-file "/dev/null"
                 (lambda ()
                   (open-pipe* OPEN_READ "git" "rev-parse" "--show-toplevel"))))
         (output (read-line pipe)))
    (if (= 0 (close-pipe pipe))
        output
        #f)))

(define (git-source-file? file stat)
  (define old-cwd (getcwd))
  (chdir (dirname file))
  (define keep?
    (let ((root (git-toplevel)))
      (or (not root)
          (begin
            (chdir root)
            (and (not (string=? (string-append root "/.git") file))
                 (= 1 (status:exit-val (system*/quiet "git" "check-ignore" file))))))))
  (chdir old-cwd)
  keep?)

(define-syntax relative-file
  (syntax-rules ()
    ((_ path rest ...)
     (local-file
      (string-append
       (if (current-filename)
           (dirname (current-filename))
           (current-source-directory))
       "/" path)
      rest ...))))
