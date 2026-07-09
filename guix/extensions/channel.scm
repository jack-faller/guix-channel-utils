;;@load-paths@
(define-module (guix extensions channel)
  #:use-module (guix build utils)
  #:use-module (guix channels utils)
  #:use-module (guix scripts)
  #:use-module (ice-9 format)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 getopt-long)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 pretty-print)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:export (guix-channel))

(define (set-PATH)
  ;;@set-PATH-body@
  (values))

;; TODO: Add something for dependencies.

;; TODO: Development environment for channel packages.

;; TODO: Prompt user to move files when changing keyring branch or channel directory.
;; Will also need to prompt for removal of channel directory to move files to the root.

;; TODO: `guix channel test` to build all packages from channel.
;; Also would make sense to add a way of recording the environment in use when a commit was tested.
;; I.e. which Guix version and other channels' versions.
;; This would provide a way to reproduce old packages exactly even if they are out of date

;; TODO: Add `--package` to `init`.
;; `--package=xyz/jackfaller/miny/miny` should create:
;; <channel-directory>/xyz/jackfaller/miny.scm
#;((define-module (xyz jackfaller miny)
    #:use-module (guix channels utils)
    #:use-module (guix gexp)
    #:use-module ((guix licenses) #:prefix license:)
    #:use-module (guix packages)
    #:export (miny))
  (define-public miny
    (package
      (source (relative-file "../../.." #:recursive? #t #:select? git-source-file?))
      ...)) )
;; And creates guix.scm:
#;((add-to-load-path (dirname (current-filename)))
   (use-modules (xyz jackfaller miny))
   (list miny))

;; TODO: Allow `export` to take a URL/path argument(s) and use the packages there as a list for psub.
;; TODO: Add `--dependency` option to add dependencies from `export`.

(define-syntax if-let
  (syntax-rules ()
    ((_ (name value) then else) (let ((name value)) (if name then else)))))

(define-record-type <channel>
  (make-metadata url directory news-file keyring-reference dependencies keys)
  metadata?
  (url metadata-url set-metadata-url!)
  (directory metadata-directory set-metadata-directory!)
  (news-file metadata-news-file set-metadata-news-file!)
  (keyring-reference metadata-keyring-reference set-metadata-keyring-reference!)
  (dependencies metadata-dependencies set-metadata-dependencies!)
  (keys metadata-keys set-metadata-keys!))

;; TODO: Proper handling of key values.
;; Key should be a record and the keys metadata field should be a hash map.
(define (make-key fingerprint name)
  `(,fingerprint
    (name
     ,(string-downcase (regexp-substitute/global #f " " name 'pre "-" 'post)))))
(define (key-name key) (cadadr key))
(define (key-fingerprint key) (car key))
(define (key-file-name key)
  (string-append
   (key-name key) "-"
   (substring (key-fingerprint key) 0 4)
   (substring (key-fingerprint key) 5 9)
   ".key"))

(define (empty-metadata) (make-metadata #f #f #f #f #f #f))
(define (field-iterator->metadata iterator)
  "Call the procedure `iterator` which should yield `(values field-name value)` with field name null to indicate termination."
  (define result (empty-metadata))
  (define (try-set getter setter! value)
    (if (getter result)
        (error "Duplicate form in metadata/authorization definition")
        (setter! result value)))
  (let loop ()
    (define-values (field value) (iterator))
    (when field
      (case field
        ((url) (try-set metadata-url set-metadata-url! value))
        ((directory) (try-set metadata-directory set-metadata-directory! value))
        ((news-file) (try-set metadata-news-file set-metadata-news-file! value))
        ((keyring-reference) (try-set metadata-keyring-reference set-metadata-keyring-reference! value))
        ((dependencies) (try-set metadata-dependencies set-metadata-dependencies! value))
        ((dependency)
         (set-metadata-dependencies!
          result
          (cons value (or (metadata-dependencies result) '()))))
        ((keys) (try-set metadata-keys set-metadata-keys! value))
        ((key)
         (set-metadata-keys!
          result
          (cons value (or (metadata-keys result) '()))))
        ((version)
         (unless (= value 0)
           (error "Incompatible channel version, expected 0" value)))
        ((authorization-version)
         (unless (= value 0)
           (error "Incompatible authorization version, expected 0" value)))
        (else (error "Unrecognised metadata field" field)))
      (loop)))
  result)
(define (load-metadata)
  (define forms
    (append
     (match (call-with-input-file ".guix-channel" read)
       (('channel . rest) rest)
       (_ (error "Unrecognised .guix-channel format")))
     (if (file-exists? ".guix-authorizations")
         (match (call-with-input-file ".guix-authorizations" read)
           (('authorizations ('version version) keys)
            (list (list 'authorization-version version) (list 'keys keys)))
           (_ (error "Unrecognised .guix-authorizations format")))
         '())))
  (field-iterator->metadata
   (lambda ()
     (if (null? forms)
         (values #f #f)
         (let ((field (car forms)))
           (set! forms (cdr forms))
           (match field
             (('dependencies . dependencies) (values 'dependencies dependencies))
             ((k v) (values k v))
             (x (error "Malformed metadata field" x))))))))
(define fingerprint-regexp (make-regexp "^\\s*(([A-Z0-9]{4} ){5}( [A-Z0-9]{4}){5})$" regexp/extended regexp/newline))
(define (list-keys keys)
  (apply command-output get-string-all "gpg" "--list-keys" "--with-fingerprint" keys))
(define (program-arguments->metadata arguments)
  (define grammar
    '((url (single-char #\u) (value #t))
      (directory (single-char #\d) (value #t))
      (news-file (single-char #\n) (value #t))
      (keyring-reference (value #t))
      (key (single-char #\k) (value #t))))
  (define options (getopt-long arguments grammar))
  (define (iterator)
    (if (null? options)
        (values #f #f)
        (match-let (((option . value) (car options)))
          (set! options (cdr options))
          (case option
            ((()) (if (null? value) (iterator) (error "Unexpected extra arguments")))
            ;; TODO: Use `--key=name=identifier` syntax.
            ((key)
             (if (string? value)
                 (let ((match->key
                        (lambda (m) `(key . ,(make-key (match:substring m 1) value))))
                       (matches (list-matches fingerprint-regexp (list-keys (list value)))))
                   (set! options (append! (map match->key matches) options))
                   (iterator))
                 (values option value)))
            (else (values option value))))))
  (field-iterator->metadata iterator))
(define* (write-channel metadata #:optional (port (current-output-port)))
  (define (simple-field name getter)
    (if-let (value (getter metadata)) (list (list name value)) '()))
  (pretty-print
   `(channel
     (version 0)
     ,@(simple-field 'url metadata-url)
     ,@(simple-field 'directory metadata-directory)
     ,@(simple-field 'keyring-reference metadata-keyring-reference)
     ,@(simple-field 'news-file metadata-news-file)
     ,@(let ((dependencies (metadata-dependencies metadata)))
         (if (null? dependencies) '()
             `((dependencies ,@dependencies)))))
   port))
(define* (write-authorizations metadata #:optional (port (current-output-port)))
  (pretty-print
   `(authorizations (version 0) ,(metadata-keys metadata))
   port))

(define (add-metadata-values old new-fields)
  (make-metadata
   (let ((old-value (metadata-url old)) (new-value (metadata-url new-fields)))
     (if (and old-value new-value) (error "Duplicate url in metadata") (or new-value old-value)))
   (let ((old-value (metadata-directory old)) (new-value (metadata-directory new-fields)))
     (if (and old-value new-value) (error "Duplicate url in metadata") (or new-value old-value)))
   (let ((old-value (metadata-news-file old)) (new-value (metadata-news-file new-fields)))
     (if (and old-value new-value) (error "Duplicate news-file in metadata") (or new-value old-value)))
   (let ((old-value (metadata-keyring-reference old)) (new-value (metadata-keyring-reference new-fields)))
     (if (and old-value new-value) (error "Duplicate keyring-reference in metadata") (or new-value old-value)))
   (lset-union equal? (or (metadata-dependencies old) '()) (or (metadata-dependencies new-fields) '()))
   (lset-union equal? (or (metadata-keys old) '()) (or (metadata-keys new-fields) '()))))
(define (set-metadata-values old new-fields)
  (make-metadata
   (let ((old-value (metadata-url old)) (new-value (metadata-url new-fields)))
     (or new-value old-value))
   (let ((old-value (metadata-directory old)) (new-value (metadata-directory new-fields)))
     (or new-value old-value))
   (let ((old-value (metadata-news-file old)) (new-value (metadata-news-file new-fields)))
     (or new-value old-value))
   (let ((old-value (metadata-keyring-reference old)) (new-value (metadata-keyring-reference new-fields)))
     (or new-value old-value))
   (or (metadata-dependencies new-fields) (metadata-dependencies old))
   (or (metadata-keys new-fields) (metadata-keys old))))

(define (log message . objects)
  (apply format (current-error-port) message objects))

(define (general-help)
  (display "Usage: guix channel init|authorize|export"))

(define (init-help)
  (display "Usage: guix channel init [--key=name=identifier] [--directory=] [--keyring-reference=] [--url=]")
  (newline)
  (display "Initialise a new channel with the given configuration, possibly creating a git repository and adding keys to the keyring.")
  (newline)
  (define (arg name description) (format #t "  ~a\t~a~%" name description))
  (arg "-k|--key" "Add key to authoriztions as in `guix channel authorize`.")
  (arg "-d|--directory" "Set the channel directory, default is either the current directory or the root of the present Git repository if one exists.")
  (arg "--keyring-reference" "Set the keyring branch name.")
  (arg "-u|--url" "Set the upstream URL."))

(define (add-help)
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

(define (command-output* reader program . args)
  "As `command-output` but return the error code on program error"
   (apply log-program program args)
  (let* ((pipe (apply open-pipe* OPEN_READ program args))
         (output (reader pipe))
         (return-code (close-pipe pipe)))
    (if (eq? 0 return-code)
        output
        return-code)))
(define (command-output reader program . args)
  "Call `reader` on the output port of program and return the result, fail if program returns non-zero."
  (define result (apply command-output* reader program args))
  (if (string? result)
      result
      (error "Unexpected error executing program" program)))

(define (current-branch)
  (command-output get-line "git" "rev-parse" "--abbrev-ref" "HEAD"))

(define (update-keyring metadata)
  (define keyring-reference (or (metadata-keyring-reference metadata) "keyring"))
  (define old-branch (current-branch))
  (guard (c ((invoke-error? c)
             (invoke* "git" "checkout" keyring-reference)))
    (invoke* "git" "checkout" "--orphan" keyring-reference))
  (invoke* "git" "reset" "--hard")
  (call-with-port (open-pipe* OPEN_READ "git" "ls-files")
    (lambda (port)
      (let loop ()
        (define file (get-line port))
        (unless (eof-object? file)
          (invoke* "git" "rm" file)
          (loop)))))
  (for-each
   (lambda (key)
     (define file (key-file-name key))
     (with-output-to-file file
       (lambda () (invoke* "gpg" "--export" "--armor" (key-fingerprint key))))
     (invoke* "git" "add" file))
   (metadata-keys metadata))
  (unless (= 0 (system* "git" "diff" "--staged" "--quiet"))
    (invoke* "git" "commit" "-S" "-m" "Adds keys"))
  (invoke* "git" "checkout" old-branch))

(define try-infer-url
  (let ((regexp (make-regexp "^git@([^:]*):(.*)(\\.git)?$")))
    (lambda ()
      (define origin
        (command-output* get-line "git" "config" "--get" "remote.origin.url"))
      (if (string? origin)
          (regexp-substitute/global
           #f regexp origin 'pre "https://" 1 "/" 2 'post)
          #f))))

(define (warn-keys metadata)
  (when (metadata-keys metadata)
    (let ((output (list-keys (map key-fingerprint (metadata-keys metadata)))))
      (log "~%The following keys will be authorized:~%~a" output)
      (log "Authorize these keys? (Y/n):")
      (force-output (current-error-port))
      (unless (member (read-char) '(#\newline #\y #\Y))
        (error "Abort")))))

(define (instance-metadata metadata)
  (invoke* "git" "reset")
  (call-with-output-file ".guix-channel" (cut write-channel metadata <>))
  (if (null? (metadata-keys metadata))
      (when (file-exists? ".guix-authorizations")
        (system* "git" "rm" ".guix-authorizations"))
      (call-with-output-file ".guix-authorizations"
        (cut write-authorizations metadata <>)))
  (invoke* "git" "add" ".guix-channel")
  (when (file-exists? ".guix-authorizations")
    (invoke* "git" "add" ".guix-authorizations"))
  (invoke* "git" "commit" "-S" "-m" "Init Guix channel")
  ;; TODO: Don't bother updating if values haven't changed.
  (update-keyring metadata))

(define (add-or-set args combine)
  (chdir (or (git-toplevel)
             (error "Not in git repo, try calling `guix channel init --key=<key>` to create one in the current working directory")))
  (define metadata-old (load-metadata))
  (define metadata (program-arguments->metadata args))
  (warn-keys metadata)
  (instance-metadata (combine metadata-old metadata)))

(define-command (guix-channel . args)
  (category extension)
  (synopsis "Explore packages and services through REST API")
  (set-PATH)
  (when (member "--help" args)
    (match (car args)
      ("init" (init-help))
      ("add" (add-help))
      ("set" (set-help))
      ("get" (get-help))
      ("remove" (remove-help))
      ("export" (export-help))
      (_ (general-help)))
    (exit 0))
  (match (car args)
    ("init"
     (let ((git-root (git-toplevel)))
       (if git-root
           (chdir git-root)
           ;; Force SHA1 as Guix doesn't recognise SHA256 channel repos.
           (invoke* "git" "init" "--object-format=sha1"))
       (when (file-exists? ".guix-channel")
         (error "`.guix-channel` already exists in this directory"))
       (when (file-exists? ".guix-authorizations")
         (error "`.guix-authorizations` already exists in this directory"))
       (define metadata (program-arguments->metadata args))
       (set-metadata-url! metadata (or (metadata-url metadata) (try-infer-url)))
       (warn-keys metadata)
       (instance-metadata metadata)))
    ("add" (add-or-set args add-metadata-values))
    ("set" (add-or-set args set-metadata-values))
    ("get" (error "TODO"))
    ("remove" (error "TODO"))
    ("export"
     (let ((git-root (git-toplevel)))
       (unless git-root
         (error "Fatal: not in Git repository, , try calling `guix channel init --key=<key>` to create one with a channel in it"))
       (chdir git-root))
     (let ((name (basename (getcwd))))
       (define metadata (load-metadata))
       (pretty-print
        `(channel
          (name ',(string->symbol name))
          (url ,(or (metadata-url metadata) (try-infer-url) 'UNKNOWN))
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
