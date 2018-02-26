;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2015 Sou Bunnbu <iyzsong@gmail.com>
;;; Copyright © 2015 Mark H Weaver <mhw@netris.org>
;;; Copyright © 2016 Efraim Flashner <efraim@flashner.co.il>
;;; Copyright © 2018 Tobias Geerinckx-Rice <me@tobias.gr>
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

(define-module (gnu packages ninja)
  #:use-module ((guix licenses) #:select (asl2.0))
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix build-system gnu)
  #:use-module (gnu packages)
  #:use-module (gnu packages python))

(define-public ninja
  (package
    (name "ninja")
    (version "1.8.2")
    (source (origin
              (method url-fetch)
              (uri (string-append "https://github.com/martine/ninja/"
                                  "archive/v" version ".tar.gz"))
              (file-name (string-append name "-" version ".tar.gz"))
              (sha256
               (base32
                "1x66q6494ml1p1f74mxzik1giakl4zj7rxig9jsc50087l671f46"))))
    (build-system gnu-build-system)
    (native-inputs `(("python" ,python-2)))
    (arguments
     '(#:phases
       (modify-phases %standard-phases
         (replace 'configure
           (lambda _
             (substitute* "src/subprocess-posix.cc"
               (("/bin/sh") (which "sh")))
             (substitute* "src/subprocess_test.cc"
               (("/bin/echo") (which "echo")))
             #t))
         (replace 'build
           (lambda _
             (invoke "./configure.py" "--bootstrap")))
         (replace 'check
           (lambda _
             (invoke "./configure.py")
             (invoke "./ninja" "ninja_test")
             (invoke "./ninja_test")))
         (replace 'install
           (lambda* (#:key outputs #:allow-other-keys)
             (let* ((out (assoc-ref outputs "out"))
                    (bin (string-append out "/bin"))
                    (doc (string-append out "/share/doc/ninja")))
               (install-file "ninja" bin)
               (install-file "doc/manual.asciidoc" doc)
               #t))))))
    (home-page "https://ninja-build.org/")
    (synopsis "Small build system")
    (description
     "Ninja is a small build system with a focus on speed.  It differs from
other build systems in two major respects: it is designed to have its input
files generated by a higher-level build system, and it is designed to run
builds as fast as possible.")
    (license asl2.0)))
