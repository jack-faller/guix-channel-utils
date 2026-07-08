;;@load-paths@
(define-module (guix extensions channel)
  #:use-module (guix build utils)
  #:use-module (guix channels utils)
  #:use-module (guix scripts)
  #:use-module (ice-9 format)
  #:use-module (ice-9 getopt-long)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 pretty-print)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:export (guix-channel))

(define (log message . objects)
  (apply format (current-error-port) message objects))

(define (set-PATH)
  ;;@set-PATH-body@
  (values))

(define (general-help)
  (display "Usage: guix channel init|authorize|export"))

(define (init-help)
  (display "Usage: guix channel init [--key=] [--directory=] [--keyring-reference=] [--url=]")
  (newline)
  (display "Initialise a new channel with the given configuration, possibly creating a git repository and adding keys to the keyring.")
  (newline)
  (define (arg name description) (format #t "  ~a\t~a~%" name description))
  (arg "-k|--key" "Add key to authoriztions as in `guix channel authorize`.")
  (arg "-d|--directory" "Set the channel directory, default is either the current directory or the root of the present Git repository if one exists.")
  (arg "--keyring-reference" "Set the keyring branch name.")
  (arg "-u|--url" "Set the upstream URL."))

(define (authorize-help)
  (display "Usage: guix channel authorize key...")
  (newline)
  (display "Add the keys provided as arguments to the keyring branch and to `.guix-authorizations`.")
  (newline))
(define (export-help)
  (display "Usage: guix channel export")
  (newline)
  (display "Export the Scheme code to instance this channel.")
  (newline))

(define (log-program program . args)
  (log "Running: ~a" program)
  (for-each (cut log " ~a" <>) args)
  (log "~%"))
(define (invoke* program . args)
  (apply log-program program args)
  (apply invoke program args))

(define init-options
  '((url (single-char #\u) (value #t))
    (directory (single-char #\d) (value #t))
    (keyring-reference (value #t))
    (key (single-char #\k) (value #t))
    (help (single-char #\h))))

(define fingerprint-regexp (make-regexp "^\\s*(([A-Z0-9]{4} ){5}( [A-Z0-9]{4}){5})$" regexp/extended regexp/newline))

(define (command-output reader program . args)
  "Call `reader` on the output port of program and return the result, fail if program returns non-zero."
  (apply log-program program args)
  (let* ((pipe (apply open-pipe* OPEN_READ program args))
         (output (reader pipe)))
    (unless (= 0 (close-pipe pipe))
      (error "Unexpected error executing program" program))
    output))

(define (add-to-authorizations keys)
  "Write to the `.guix-authorizations` file and return `(values fingerprints file-names)` for `add-to-keyring`"
  (define existing
    (if (file-exists? ".guix-authorizations")
        (match (call-with-input-file ".guix-authorizations" read)
          (('authorizations ('version 0) existing)
           existing)
          (_ (error "Unrecognised authorizations file format")))
        '()))
  (define fingerprints
    (let ((output (apply command-output get-string-all "gpg" "--list-keys" "--with-fingerprint" keys)))
      (log "~%The following keys will be authorized:~%~a" output)
      (log "Authorize these keys? (Y/n):")
      (force-output (current-error-port))
      (unless (member (read-char) '(#\newline #\y #\Y))
        (error "Abort"))
      (map (cut match:substring <> 1) (list-matches fingerprint-regexp output))))
  (define key-names
    (map (lambda (key)
           (string-downcase
            (regexp-substitute/global #f " " key 'pre "-" 'post)))
         keys))
  (define file-names
    (map
     (lambda (key-name fingerprint)
       (string-append key-name "-"
                      (substring fingerprint 0 4)
                      (substring fingerprint 5 9)
                      ".key"))
     key-names fingerprints))
  (with-output-to-file ".guix-authorizations"
    (lambda ()
      (pretty-print
       `(authorizations
         (version 0)
         (,@existing
          ,@(map
             (lambda (fingerprint key-name)
               `(,fingerprint (name ,key-name)))
             fingerprints key-names))))))
  (values fingerprints file-names))

(define (current-branch)
  (command-output get-line "git" "rev-parse" "--abbrev-ref" "HEAD"))

(define (add-to-keyring fingerprints file-names)
  "Add `fingerprints` to the keyring branch giving each one the corresponding name from `file-names`."
  (define keyring-reference
    (let ((channel-info (cdr (call-with-input-file ".guix-channel" read))))
      (match (assoc-ref channel-info 'keyring-reference)
        (((? string? s)) s)
        (#f "keyring")
        (_ (error "Error in .guix-channel")))))
  (define old-branch (current-branch))
  (guard (c ((invoke-error? c)
             (invoke* "git" "checkout" keyring-reference)))
    (invoke* "git" "checkout" "--orphan" keyring-reference))
  (invoke* "git" "reset" "--hard")
  (for-each
   (lambda (fingerprint file)
     (invoke* "gpg" "--export" "--armor" "--output" file fingerprint))
   fingerprints file-names)
  (apply invoke* "git" "add" file-names)
  (invoke* "git" "commit" "-S" "-m" "Adds keys")
  (invoke* "git" "checkout" old-branch))

(define-command (guix-channel . args)
  (category extension)
  (synopsis "Explore packages and services through REST API")
  (set-PATH)
  (match (car args)
    ("--help" (general-help))
    ("init"
     (let ((keys '())
           (directory #f)
           (url #f)
           (keyring-reference #f)
           (options (getopt-long args init-options)))
       (when (not (equal? (car options) '(())))
         (error "Unexpected argument, `guix channel init` takes no arguments"))
       (for-each
        (lambda (i)
          (match i
            (('url . value)
             (if url
                 (error "Multiple URL arguments, expected at most one")
                 (set! url value)))
            (('directory . value)
             (if directory
                 (error "Multiple directory arguments, expected at most one")
                 (set! directory value)))
            (('keyring-reference . value)
             (if keyring-reference
                 (error "Multiple keyring-reference arguments, expected at most one")
                 (set! keyring-reference value)))
            (('key . value) (set! keys (cons value keys)))
            (('help . #t)
             (init-help)
             (exit 0))))
        (cdr options))
       (define git-root (git-toplevel))
       (if git-root
           (chdir git-root)
           ;; Force SHA1 as Guix doesn't recognise SHA256 channel repos.
           (invoke* "git" "init" "--object-format=sha1"))
       (with-output-to-file ".guix-channel"
         (lambda ()
           (pretty-print
            `(channel
              (version 0)
              ,@(if url `((url ,url)) '())
              ,@(if directory `((directory ,directory)) '())
              ,@(if keyring-reference `((keyring-reference ,keyring-reference)) '())))))
       (define-values (fingerprints key-file-names)
         (if (null? keys)
             (values '() '())
             (add-to-authorizations keys)))
       (invoke* "git" "reset")
       (invoke* "git" "add" ".guix-channel")
       (when (file-exists? ".guix-authorizations")
         (invoke* "git" "add" ".guix-authorizations"))
       (invoke* "git" "commit" "-S" "-m" "Init Guix channel")
       (unless (null? keys)
         (add-to-keyring fingerprints key-file-names))))
    ("authorize"
     (when (member "--help" args)
       (authorize-help)
       (exit 0))
     (chdir (or (git-toplevel)
                (error "Not in git repo, try calling `guix channel init --key=<key>` to create one and add your keys to it")))
     (let-values (((fingerprints key-file-names) (add-to-authorizations (cdr args))))
       (invoke* "git" "reset")
       (invoke* "git" "add" ".guix-authorizations")
       (invoke* "git" "commit" "-S" "-m"
                (string-join (cons "Authorizes Guix channel keys\n" keys) "\n"))
       (add-to-keyring fingerprints key-file-names)))
    ("export"
     (when (member "--help" args)
       (export-help)
       (exit 0))
     (let ((git-root (git-toplevel)))
       (unless git-root
         (error "Fatal: not in Git repository, , try calling `guix channel init --key=<key>` to create one with a channel in it"))
       (chdir git-root))
     (let ((name (basename (getcwd))))
       (pretty-print
        `(channel
          (name ',(string->symbol name))
          (url ,(regexp-substitute/global
                 #f "^git@([^:]*):(.*)\\.git$"
                 (command-output get-line "git" "config" "--get" "remote.origin.url")
                 'pre "https://" 1 "/" 2 'post))
          ,@(let ((branch (current-branch)))
              (if (equal? branch "master")
                  '()
                  `((branch ,(current-branch)))))
          ,@(if (file-exists? ".guix-authorizations")
                (let* ((commit+fingerprint
                        (command-output get-line "git" "log" "--format=%H %GF" "--diff-filter=A" "--" ".guix-authorizations"))
                       (split (string-split commit+fingerprint (cut char=? <> #\ ))))
                  `((introduction
                     (make-channel-introduction
                      ,(car split)
                      (openpgp-fingerprint
                       ,(regexp-substitute/global
                         #f "(.{4})(.{4})(.{4})(.{4})(.{4})(.{4})(.{4})(.{4})(.{4})(.{4})"
                         (cadr split)
                         1 " " 2 " " 3 " " 4 " " 5 "  " 6 " " 7 " " 8 " " 9 " " 10))))))
                '())))))))
