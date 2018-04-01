# GNU Guix --- Functional package management for GNU
# Copyright © 2018 Chris Marusich <cmmarusich@gmail.com>
#
# This file is part of GNU Guix.
#
# GNU Guix is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or (at
# your option) any later version.
#
# GNU Guix is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

#
# Test the `guix pack' command-line utility.
#

# A network connection is required to build %bootstrap-coreutils&co,
# which is required to run these tests with the --bootstrap option.
if ! guile -c '(getaddrinfo "www.gnu.org" "80" AI_NUMERICSERV)' 2> /dev/null; then
    exit 77
fi

guix pack --version

# Use --no-substitutes because we need to verify we can do this ourselves.
GUIX_BUILD_OPTIONS="--no-substitutes"
export GUIX_BUILD_OPTIONS

# Build a tarball with no compression.
guix pack --compression=none --bootstrap guile-bootstrap

# Build a tarball (with compression).
guix pack --bootstrap guile-bootstrap

# Build a tarball with a symlink.
the_pack="`guix pack --bootstrap -S /opt/gnu/bin=bin guile-bootstrap`"

# Try to extract it.
test_directory="`mktemp -d`"
trap 'rm -rf "$test_directory"' EXIT
cd "$test_directory"
tar -xf "$the_pack"
test -x opt/gnu/bin/guile

is_available () {
    # Use the "type" shell builtin to see if the program is on PATH.
    type "$1" > /dev/null
}

if is_available chroot && is_available unshare; then
    # Verify we can use what we built.
    unshare -r chroot . /opt/gnu/bin/guile --version
    cd -
else
    echo "warning: skipped some verification because chroot or unshare is unavailable" >&2
fi

# For the tests that build Docker images below, we currently have to use
# --dry-run because if we don't, there are only two possible cases:
#
#     Case 1: We do not use --bootstrap, and the build takes hours to finish
#             because it needs to build tar etc.
#
#     Case 2: We use --bootstrap, and the build fails because the bootstrap
#             Guile cannot dlopen shared libraries.  Not to mention the fact
#             that we would still have to build many non-bootstrap inputs
#             (e.g., guile-json) in order to create the Docker image.

# Build a Docker image.
guix pack --dry-run --bootstrap -f docker guile-bootstrap

# Build a Docker image with a symlink.
guix pack --dry-run --bootstrap -f docker -S /opt/gnu=/ guile-bootstrap

# Build a tarball pack of cross-compiled software.  Use coreutils because
# guile-bootstrap is not intended to be cross-compiled.
guix pack --dry-run --bootstrap --target=arm-unknown-linux-gnueabihf coreutils