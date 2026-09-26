#!/bin/zsh
# The application version, in one place.
#
# Sourced by `build-app.sh` (which writes it into the bundle's Info.plist),
# `make-dmg.sh` (which names the disk image after it) and the release workflow
# (which checks it against the git tag). Keeping it in a single file means a
# release is one edit rather than three that can drift apart.
#
# Version scheme: MAJOR.MINOR.PATCH, matching the git tag without its `v`.
# `CFBundleVersion` is the build number, which has to increase for every build of
# the same marketing version; the workflow uses the run number.

export VERSION="${VERSION:-1.0.0}"
export BUILD_NUMBER="${BUILD_NUMBER:-1}"
