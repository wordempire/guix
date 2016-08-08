;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2014 Cyrill Schenkel <cyrill.schenkel@gmail.com>
;;; Copyright © 2015 Andreas Enge <andreas@enge.fr>
;;; Copyright © 2015, 2016 David Thompson <davet@gnu.org>
;;; Copyright © 2016 Ludovic Courtès <ludo@gnu.org>
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

(define-module (gnu packages node)
  ;;#:use-module ((guix licenses) #:select (expat))
  #:use-module (guix licenses)
  #:use-module (guix packages)
  #:use-module (guix derivations)
  #:use-module (guix download)
  #:use-module (guix git-download)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system node)
  #:use-module (gnu packages adns)
  #:use-module (gnu packages base)
  #:use-module ((gnu packages compression) #:prefix compression:)
  #:use-module (gnu packages gcc)
  #:use-module (gnu packages libevent)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages perl)
  #:use-module (gnu packages python)
  #:use-module ((gnu packages tls) #:prefix tls:))

(define-public node
  (package
    (name "node")
    (version "6.3.1")
    (source (origin
              (method url-fetch)
              (uri (string-append "http://nodejs.org/dist/v" version
                                  "/node-v" version ".tar.gz"))
              (sha256
               (base32
                "1xh883fbhyhgna1vi8xmd6klg4r186lb1h1xr08hn89wy7f48q9z"))))
    (build-system gnu-build-system)
    (arguments
     ;; TODO: Package http_parser and add --shared-http-parser.
     '(#:configure-flags '("--shared-openssl"
                           "--shared-zlib"
                           "--shared-libuv"
                           "--without-snapshot")
       #:phases
       (modify-phases %standard-phases
         (add-before 'configure 'patch-files
           (lambda* (#:key inputs #:allow-other-keys)
             ;; Fix hardcoded /bin/sh references.
             (substitute* '("lib/child_process.js"
                            "lib/internal/v8_prof_polyfill.js"
                            "test/parallel/test-stdio-closed.js")
               (("'/bin/sh'")
                (string-append "'" (which "bash") "'")))

             ;; Fix hardcoded /usr/bin/env references.
             (substitute* '("test/parallel/test-child-process-default-options.js"
                            "test/parallel/test-child-process-env.js"
                            "test/parallel/test-child-process-exec-env.js")
               (("'/usr/bin/env'")
                (string-append "'" (which "env") "'")))

             ;; Having the build fail because of linter errors is insane!
             (substitute* '("Makefile")
               (("	\\$\\(MAKE\\) jslint") "")
               (("	\\$\\(MAKE\\) cpplint\n") ""))

             ;; FIXME: These tests fail in the build container, but they don't
             ;; seem to be indicative of real problems in practice.
             (for-each delete-file
                       '("test/parallel/test-https-connect-address-family.js"
                         "test/parallel/test-tls-connect-address-family.js"
                         "test/parallel/test-dgram-membership.js"
                         "test/parallel/test-cluster-master-error.js"
                         "test/parallel/test-cluster-master-kill.js"
                         "test/parallel/test-npm-install.js"
                         "test/parallel/test-stdout-close-unref.js"
                         "test/sequential/test-child-process-emfile.js"))
             #t))
         (replace 'configure
           ;; Node's configure script is actually a python script, so we can't
           ;; run it with bash.
           (lambda* (#:key outputs (configure-flags '()) inputs
                     #:allow-other-keys)
             (let* ((prefix (assoc-ref outputs "out"))
                    (flags (cons (string-append "--prefix=" prefix)
                                 configure-flags)))
               (format #t "build directory: ~s~%" (getcwd))
               (format #t "configure flags: ~s~%" flags)
               ;; Node's configure script expects the CC environment variable to
               ;; be set.
               (setenv "CC" (string-append (assoc-ref inputs "gcc") "/bin/gcc"))
               (zero? (apply system*
                             (string-append (assoc-ref inputs "python")
                                            "/bin/python")
                             "configure" flags)))))
         (add-after 'patch-shebangs 'patch-npm-shebang
           (lambda* (#:key outputs #:allow-other-keys)
             (let* ((bindir (string-append (assoc-ref outputs "out")
                                           "/bin"))
                    (npm    (string-append bindir "/npm"))
                    (target (readlink npm)))
               (with-directory-excursion bindir
                 (patch-shebang target (list bindir))
                 #t)))))))
    (native-inputs
     `(("python" ,python-2)
       ("perl" ,perl)
       ("procps" ,procps)
       ("util-linux" ,util-linux)
       ("which" ,which)))
    (native-search-paths
     (list (search-path-specification
            (variable "NODE_PATH")
            (files '("lib/node_modules")))))
    (inputs
     `(("libuv" ,libuv)
       ("openssl" ,tls:openssl)
       ("zlib" ,compression:zlib)))
    (synopsis "Evented I/O for V8 JavaScript")
    (description "Node.js is a platform built on Chrome's JavaScript runtime
for easily building fast, scalable network applications.  Node.js uses an
event-driven, non-blocking I/O model that makes it lightweight and efficient,
perfect for data-intensive real-time applications that run across distributed
devices.")
    (home-page "http://nodejs.org/")
    (license expat)))

(define-public node
  (package
    (name "node")
    (version "0.1.33")
    (source (origin
              (method url-fetch)
              (uri (string-append "http://nodejs.org/dist/v" version
                                  "/node-v" version ".tar.gz"))
              (sha256
               (base32
                "19y5211rhj0waisfi0yc7j86psykkc49qym78cxayaxjmkdv2paa"))))
    (build-system gnu-build-system)
    (arguments
     '(#:make-flags (list (string-append "CXXFLAGS=-I"
                                         (assoc-ref %build-inputs "linux-headers")
                                         "/include")
                          (string-append "CFLAGS=-I"
                                         (assoc-ref %build-inputs "linux-headers")
                                         "/include"))
       #:test-target "test"
       #:phases
       (modify-phases %standard-phases
         (add-before 'configure 'patch-files
           (lambda* (#:key inputs #:allow-other-keys)
             ;; XXX: The configure script does not support the
             ;; --without-snapshot flaq, but this can be patched in manually
             (substitute* '("wscript")
               (("snapshot=on")
                ""))
             ;; XXX: Symbols were used before they were included
             (substitute* '("deps/v8/src/globals.h")
               (("namespace v8 \\{")
                "#include <cstring>\nnamespace v8 {"))
             ;; XXX: Old sources made use of a more permissive compiler, but
             ;; for more recent versions of gcc, we need to properly designate
             ;; the namespace of functions we call.
             (substitute* '("deps/v8/src/objects.h" "deps/v8/src/objects.cc")
               (("\\(get\\(")
                "(this->get(")
               (("return get\\(E")
                "return this->get(E")
               (("return get\\(H")
                "return this->get(H")
               (("!get\\(")
                "!this->get(")
               (("int entry = FindEntry\\(key\\);")
                "int entry = this->FindEntry(key);"))
             ;; FIXME: These tests fail in the build container, but they don't
             ;; seem to be indicative of real problems in practice.
             (for-each delete-file
                       '("test/simple/test-remote-module-loading.js"
                         "test/simple/test-exec.js"
                         "test/simple/test-tcp-binary.js" 
                         "test/simple/test-fs-realpath.js"
                         "test/simple/test-child-process-env.js"))))
         (replace 'configure
           ;; Node's configure script is actually a python script, so we can't
           ;; run it with the standard configure flags.
           (lambda* (#:key outputs (configure-flags '()) inputs
                     #:allow-other-keys)
             (let* ((prefix (assoc-ref outputs "out"))
                    (flags
                     (cons (string-append "--prefix=" prefix)
                           configure-flags)))
               (format #t "build directory: ~s~%" (getcwd))
               (format #t "configure flags: ~s~%" flags)
               (setenv "CC" (string-append (assoc-ref inputs "gcc") "/bin/gcc"))
               (zero? (apply system*
                             "./configure" flags))))))))
    (native-inputs
     `(
       ("python" ,python-2)
       ("linux-headers" ,linux-libre-headers)
       ;;("pkg-config" ,pkg-config)
       ))
    (native-search-paths
     (list (search-path-specification
            (variable "NODE_PATH")
            (files '("lib/node_modules")))))
    (inputs
     `(
       ;;("openssl" ,openssl)
       ;;("c-ares" ,c-ares)
       ("gnutls" ,tls:gnutls)
       ))
    (synopsis "Evented I/O for V8 JavaScript")
    (description "Node.js is a platform built on Chrome's JavaScript runtime
for easily building fast, scalable network applications.  Node.js uses an
event-driven, non-blocking I/O model that makes it lightweight and efficient,
perfect for data-intensive real-time applications that run across distributed
devices.")
    (home-page "http://nodejs.org/")
    (license expat)))
