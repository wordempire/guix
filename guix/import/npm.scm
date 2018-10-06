;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2015 David Thompson <davet@gnu.org>
;;; Copyright © 2016 Jelle Licht <jlicht@fsfe.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (guix import npm)
  #:use-module (json)
  #:use-module (guix import github)
  #:use-module ((guix licenses) #:select (expat))
  #:use-module (guix utils)
  #:use-module (guix upstream)
  #:use-module (web uri)
  #:use-module (guix build git)
  #:use-module (guix base32)
  ;; #:use-module (guix hash)
  #:use-module ((guix download) #:prefix download:)
  #:use-module (guix serialization)
  #:use-module (guix import json)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 control)
  #:use-module (ice-9 vlist)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs io ports)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 receive)
  #:use-module (guix import utils)
  #:use-module (guix packages)
  #:use-module (gnu packages)
  #:use-module (guix build-system node)
  ;#:use-module (semver)
  #:export (npm->guix-package
            npm-recursive-import))

(define scheme-pat
  "[a-zA-Z][-a-zA-Z0-9+.-]*")
(define host-pat
  "[a-zA-Z0-9.-]+")
(define authority-pat
  (make-regexp "[^/?#]*"))
(define path-pat
  (make-regexp "[^?#]*"))
(define user-project-pat
  "([a-zA-Z][-a-zA-Z0-9+.]*)/([a-zA-Z][-a-zA-Z0-9+.]*)")

(define gh-shorthand-regexp
  (make-regexp (format #f "^~a$" user-project-pat)))
(define alternative-gh-shorthand-regexp
  (make-regexp (format #f "^github:~a$" user-project-pat)))
(define bitbucket-shorthand-regexp
  (make-regexp (format #f "^bitbucket:~a$" user-project-pat)))
(define gitlab-shorthand-regexp
  (make-regexp (format #f "^gitlab:~a$" user-project-pat)))
(define pseudo-url-regexp
  (make-regexp (format #f "^(~a)@(~a):(~a)\\.git$"
                       scheme-pat
                       host-pat
                       user-project-pat)))

(define (pseudo-to-real-url pseudo-url-match)
  (let* ((m            pseudo-url-match)
         (protocol     (match:substring m 1))
         (hostname     (match:substring m 2))
         (user-project (match:substring m 3)))
    (format #f "~a://~a/~a.git"
            protocol
            hostname
            user-project)))

(define (make-gh-url user project)
  (format #f "https://github.com/~a/~a.git" user project))
(define (make-bb-url user project)
  (format #f "https://bitbucket.org/~a/~a.git" user project))
(define (make-gl-url user project)
  (format #f "https://gitlab.com/~a/~a.git" user project))

(define (normalise-url url)
  (cond ((regexp-exec pseudo-url-regexp url)
         ;; git@host:user/project.git
         =>
         (lambda (match)
           (pseudo-to-real-url match)))
        ((or (regexp-exec gh-shorthand-regexp url)
         (regexp-exec alternative-gh-shorthand-regexp url))
         ;; user/project or github:user/project
         => (lambda (match)
              (let ((user (match:substring match 1))
                    (project (match:substring match 2)))
                (make-gh-url user project))))
        ((regexp-exec bitbucket-shorthand-regexp url)
         ;; bitbucket:user/project
         =>
        (lambda (match)
          (let ((user (match:substring match 1))
                (project (match:substring match 2)))
            (make-bb-url user project))))
        ((regexp-exec gitlab-shorthand-regexp url)
         ;; gitlab:user/project
         =>
         (lambda (match)
           (let ((user (match:substring match 1))
                 (project (match:substring match 2)))
             (make-gl-url user project))))
        ((not (string-suffix? ".git" url))  ;XXX: forgetful npm people
         (normalise-url (string-append url ".git")))
        ((string->uri url)
         =>
         (lambda (uri)
           ;; XXX: Use actual schemes supported by git
           (case (uri-scheme uri)
             ((git+ssh)
              (uri->string (set-fields uri
                                        ((uri-scheme) 'git))))
             ((git+http)
              (uri->string (set-fields uri
                                       ((uri-scheme) 'http))))
             ((git+https)
              (uri->string (set-fields uri
                                       ((uri-scheme) 'https))))
             (else
              url))))
        (else
         url)))

(define (heuristic-tags version)
  (list version
        (string-append "v" version)))

(define (generic-fuzzy-tag-match repo-url version)
  "Return a likely match for the git tag VERSION for the repository at
REPO-URL"
  (let* ((fuzzy-tags (heuristic-tags version))
         (repo-tags  (git-fetch-tags repo-url))
         (proper-release (filter
                          (lambda (tags)
                            (member tags fuzzy-tags))
                          repo-tags)))
    (match proper-release
      (()
       #f)
      ((release . rest)
       ;;XXX: Just pick the first release
       release))))

(define (gh-fuzzy-tag-match github-repo version)
  "Return a likely match for the git tag VERSION for the repository at
GITHUB-REPO"
  (let* ((fuzzy-tags (heuristic-tags version))
         (token      (%github-token))
         (api-url    (string-append
                      "https://api.github.com/repos/"
                      (github-user-slash-repository github-repo)
                      "/tags"))
         (json (json-fetch
                (if token
                    (string-append api-url "?access_token=" token)
                    api-url))))
    (if (eq? json #f)
        (if token
            (error "Error downloading release information through the GitHub
API when using a GitHub token to download:" github-repo "@" version " via "
api-url)
            (error "Error downloading release information through the GitHub
API. This may be fixed by using an access token and setting the environment
variable GUIX_GITHUB_TOKEN, for instance one procured from
https://github.com/settings/tokens. E: " github-repo "@" version " via "
api-url))
        (let ((proper-release
               (filter
                (lambda (x)
                  (let ((name (hash-ref x "name")))
                    (member name fuzzy-tags)))
                json)))
          (match proper-release
            (()                       ;empty release list
             #f)
            ((release . rest)         ;one or more releases
             ;;XXX: Just pick the first release
             (let ((tag (hash-ref release "name")))
               tag)))))))


(define (github-user-slash-repository github-url)
  "Return a string e.g. arq5x/bedtools2 of the owner and the name of the
repository separated by a forward slash, from a string URL of the form
'https://github.com/arq5x/bedtools2.git'"
  (match (string-split (uri-path (string->uri github-url)) #\/)
    ((_ owner project . rest)
     (string-append owner "/" (string-drop-right project 4)))))

(define (github-repository github-url)
  "Return a string e.g. bedtools2 of the name of the repository, from a string
URL of the form 'https://github.com/arq5x/bedtools2.git'"
  (match (string-split (uri-path (string->uri github-url)) #\/)
    ((_ owner project . rest)
     (string-drop-right project 4))))

(define (github-release-url github-url version)
  "Return the url for the tagged release VERSION on the github repo found at
GITHUB-URL."
  (when (not version)
    (error "GitHub tarball not found" github-url version))
  (if (equal? (uri-host (string->uri github-url)) "github.com")
      (let ((ext     ".tar.gz")
            (version version)
            (prefix  (string-append "https://github.com/"
                                    (github-user-slash-repository github-url)))
            (repo    (github-repository github-url)))
        (string-append prefix "/archive/" version "/"
                       repo "-" version ext))))

;; NPM specific code
(define *REGISTRY*  "https://registry.npmjs.org/")

;; First try with released tarball, (github only?)
;; then heuristics for git repo

(define (npm-fetch name)
  "Return metadata from the npm registry for package NAME."
  (json-fetch-alist (string-append *REGISTRY* name)))

(define (latest-source-release npm-meta)
  "Return the latest source release for NPM-META."
  (assoc-ref* npm-meta "dist-tags" "latest"))

(define (npm-package? package)
  "Return true if PACKAGE is an npm package."
  (string-prefix? "node-" (package-name package)))

(define (source-uri npm-meta version)
  "Return the repository url for version VERSION of NPM-META"
  (let* ((v    (assoc-ref* npm-meta "versions" version)))
    (normalise-url (assoc-ref* v "repository" "url"))))

(define (guix-hash-url path)
  "Return the hash of PATH in nix-base32 format. PATH can be either a file or
directory."
  (let-values (((port get-hash) (open-sha256-port)))
    (write-file path port)
    (flush-output-port port)
    (bytevector->nix-base32-string (get-hash))))

(define (node-package-name name)
  "Given the NAME of a package on npmjs, return a Guix-compliant name for the
package."
  (if (string-prefix? "node-" name)
      (snake-case name)
      (string-append "node-" (snake-case name))))

(define (node-git-fetch url commit directory)
  "Fetch the git repo located at URL, clone into DIRECTORY and check out
revision COMMIT. URL can be any url supported by the 'git clone' command.
COMMIT can be identifier of a commit that works with the 'git checkout'
command."
  ;;XXX: Assumes 'commit' is actually a tag
  (let ((url (normalise-url url))
        (v (string-append "v" commit)))
    (git-fetch url v directory)))

(define (package-origin repo-url version)
  "Return a complete package origin for version VERSION of the software
located at REPO-URL. Tries to locate a released tarball before falling back to
a git checkout."
  (let ((uri (string->uri repo-url)))
    (if (equal? (uri-host uri) "github.com")
        (call-with-temporary-output-file
         (lambda (temp port)
           (let* ((gh-version (gh-fuzzy-tag-match repo-url version))
                  (tb (github-release-url repo-url gh-version))
                  (result (url-fetch tb temp))
                  (hash (bytevector->nix-base32-string (port-sha256 port))))
             (close-port port)
             `(origin
                (method url-fetch)
                (uri ,tb)
                (sha256
                 (base32
                  ,hash))))))
        (call-with-temporary-directory
         (lambda (temp-dir)
           (let ((fuzzy-version (generic-fuzzy-tag-match repo-url version)))
             (and (node-git-fetch repo-url fuzzy-version temp-dir)
                  `(origin
                     (method git-fetch)
                     (uri (git-reference
                           (url ,repo-url)
                           (commit ,fuzzy-version)))
                     (sha256
                      (base32
                       ,(guix-hash-url temp-dir)))))))))))

(define (make-npm-sexp name version home-page description
                       dependencies dev-dependencies license source-url)
  "Return the `package' s-expression for a Node package with the given NAME,
VERSION, HOME-PAGE, DESCRIPTION, DEPENDENCIES, DEV-DEPENDENCIES, LICENSES and
SOURCE-URL."
  (let ((origin (package-origin source-url version)))
    `(package
       (name ,(node-package-name name))
       (version ,version)
       (source ,origin)
       (build-system node-build-system)
       ,@(if (not dependencies)
             '()
             `((propagated-inputs
                (,'quasiquote
                 ,(map (lambda (name)
                         `(,name
                           (,'unquote
                            ,(string->symbol name))))
                       dependencies)))))
       ,@(if (not dev-dependencies)
             '()
             `((native-inputs
                (,'quasiquote
                 ,(map (lambda (name)
                         `(,name
                           (,'unquote
                            ,(string->symbol name))))
                       dev-dependencies)))))
       (synopsis ,description) ; no synopsis field in package.json files
       (description ,description)
       (home-page ,home-page)
       (license ,license)
       ,@(if (not (equal? (string-append "node-" name)
                          (node-package-name name)))
             `((properties ,`(,'quasiquote ((,'upstream-name . ,name)))))
             '())
       )))

(define (extract-guix-dependencies dependencies)
  "Returns a list of dependencies according to the guix naming scheme, from
the npm list of dependencies DEPENDENCIES."
  (if (not dependencies)
      '()
      (map (compose node-package-name car) dependencies)))

(define (extract-npm-dependencies dependencies)
  "Returns a list of dependencies according to the npm naming scheme, from the
npm list of dependencies DEPENDENCIES."
  (if (not dependencies)
      '()
      (map car dependencies)))

(define (extract-license package-json)
  (let ((license-entry (assoc-ref package-json "license"))
        (license-legacy (assoc-ref package-json "licenses")))
    (cond
     ((string? license-entry)
      (spdx-string->license license-entry))
     ((list? license-entry)
      (spdx-string->license (assoc-ref license-entry "type")))
     ((string? license-legacy)
      (spdx-string->license license-legacy))
     ((and license-legacy (positive? (length license-legacy)))
      `(list ,@(map
                (lambda (l) (spdx-string->license (assoc-ref l "type")))
                license-legacy)))
     (else
      #f))))

(define* (npm->guix-package package-name #:optional  (repo 'npm))
  "Fetch the metadata for PACKAGE-NAME from registry.npmjs.com and return the
 `package' s-expression corresponding to that package, or  on failure."
  (let ((package (npm-fetch package-name)))
    (if package
        (let* ((name (assoc-ref package "name"))
               (version (latest-source-release package))
               (curr (assoc-ref* package "versions" version))
               (raw-dependencies (assoc-ref curr "dependencies"))
               (raw-dev-dependencies (assoc-ref curr "devDependencies"))
               (dependencies (extract-guix-dependencies raw-dependencies))
               (dev-dependencies (extract-guix-dependencies
                                  raw-dev-dependencies))
               (npm-dependencies
                (append
                 (extract-npm-dependencies raw-dependencies)
                 (extract-npm-dependencies raw-dev-dependencies)))
               (description (assoc-ref package "description"))
               (home-page (assoc-ref package "homepage"))
               (license (extract-license curr))
               (source-url (source-uri package version)))
          (values
           (make-npm-sexp name version home-page description
                          dependencies dev-dependencies license source-url)
           npm-dependencies))
        (error "Could not download metadata:" package-name))))


(define npm-guix-name (cut guix-name "node-" <>))

(define* (npm-recursive-import package-name #:optional (repo 'npm))
  (recursive-import package-name repo
                    #:repo->guix-package npm->guix-package
                    #:guix-name npm-guix-name))

;; (define (package->upstream-name package)
;;   "Return the upstream name of the PACKAGE."
;;   (let* ((properties (package-properties package))
;;          (upstream-name (and=> properties
;;                                (cut assoc-ref <> 'upstream-name))))
;;     (if upstream-name
;;         upstream-name
;;         #f))) ;; TODO: Use proper heuristics with package name and what-not


(define (latest-release package)
  "Return an <upstream-source> for the latest release of PACKAGE."

  (define upstream-name
    (package-name package))

  (define meta
    (npm-fetch upstream-name))

  (and meta
       (let ((version (latest-source-release meta)))
         (upstream-source
          (package (package-name package))
          (version version)
          (urls (source-uri meta version))))))

(define %npm-updater
  (upstream-updater
   (name 'npm)
   (description "Updater for Node Package Manager packages")
   (pred npm-package?)
   (latest latest-release)))