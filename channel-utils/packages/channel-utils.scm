(define-module (channel-utils packages channel-utils)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages gnupg)
  #:use-module (gnu packages package-management)
  #:use-module (gnu packages version-control)
  #:use-module (guix build-system guile)
  #:use-module (guix channels utils)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module ((guix search-paths) #:select ($GUIX_EXTENSIONS_PATH))
  #:export (channel-utils))

(define channel-utils
  (package
    (name "channel-utils")
    (version "0.0.0")
    (source (relative-file
             "../.." name #:recursive? #t
             #:select? (lambda (file stat)
                         (and (git-source-file? file stat)
                              (not (string-suffix? "/channel-utils" file))))))
    (build-system guile-build-system)
    (arguments
     (list
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'unpack 'set-load-paths-in-entry-point
            (lambda _
              (define load-path
                (cons (string-append #$output
                                     "/share/guile/site/"
                                     (target-guile-effective-version))
                      (parse-path (getenv "GUILE_LOAD_PATH"))))
              (define load-compiled-path
                (cons (string-append #$output
                                     "/lib/guile/"
                                     (target-guile-effective-version)
                                     "/site-ccache")
                      (parse-path (getenv "GUILE_LOAD_COMPILED_PATH"))))
              (define search-paths-header
                `(begin
                   (set! %load-path
                         (append (list ,@load-path) %load-path))
                   (set! %load-compiled-path
                         (append (list ,@load-compiled-path)
                                 %load-compiled-path))))
              (substitute* "guix/extensions/channel.scm"
                ((";;@load-paths@")
                 (with-output-to-string (lambda () (write search-paths-header))))
                ((";;@set-PATH-body@")
                 (format #f "(setenv \"PATH\" \"~a:~a\")"
                         #$(file-append git "/bin")
                         #$(file-append gnupg "/bin"))))))
          (add-after 'set-load-paths-in-entry-point 'register-guix-extension
            (lambda* (#:key outputs #:allow-other-keys)
              (let ((ext-path (string-append #$output "/share/guix/extensions")))
                (mkdir-p ext-path)
                (copy-recursively "guix/extensions" ext-path)))))))
    (native-inputs (list guile-3.0-latest))
    (inputs (list guix git gnupg))
    (native-search-paths (list $GUIX_EXTENSIONS_PATH))
    (home-page "https://github.com/jack-faller/guix-channel-utils")
    (synopsis "Utilities to make authoring channels easier")
    (description synopsis)
    (license license:gpl3+)))
