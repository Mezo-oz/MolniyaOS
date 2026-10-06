#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — replace a file atomically with what arrives on stdin
# ============================================================================
#   atomic-write.sh <dest> [mode] < content
#
# Afterwards <dest> holds either its old contents or all of the new ones, never
# a torn mix — engineering standard 9 in ROADMAP.md. Exit 0 only if the new
# contents are in place and on disk.
#
# Executable helper, not a sourced library — see the extraction rule in
# ROADMAP.md. It came out of tle-updater.sh, whose two install paths were the
# standard's first known violations: `install` from tmpfs is a copy, and
# `> file` truncates the live file before writing a byte. A torn predict.tle
# does not fail; predict reads it by fixed-width columns and answers with the
# wrong pass times.
#
# HOW, and why each step is there:
#   stage   in <dest>'s own directory, so the rename below is rename(2) on one
#           filesystem and not a copy. /tmp is tmpfs on the Pi.
#   sync    the staged file BEFORE the rename. Without it ext4 data=ordered can
#           commit the rename first, and a power cut leaves a correctly named
#           file full of zeros.
#   rename  mv -T, so a directory at <dest> is an error rather than a target.
#   sync    the directory, so the rename itself survives a power cut.
#
# EMPTY INPUT IS REFUSED. An upstream stage that died before writing a byte
# must not be able to replace a good file with nothing. That is the only
# upstream failure it can see: a pipe stage that dies halfway hands it a
# well-formed prefix, so validate content before piping it in, not after.
#
# NOT FOR CAPTURES, as written. On failure it deletes its partial, which is
# right for a download — it can be fetched again — and wrong for a capture,
# whose partial standard 9 says to KEEP. A partial left by a power cut stays
# as <dest>.XXXXXX.part: identifiable, and skipped by any *.tle glob.
# ============================================================================

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: $0 <dest> [mode] < content" >&2
    exit 2
fi

dest="$1"
mode="${2:-0644}"
dir="$(dirname "$dest")"

if [ ! -d "$dir" ]; then
    echo "atomic-write: no such directory: $dir" >&2
    exit 1
fi

staged="$(mktemp --suffix=.part "$dest.XXXXXX")"
trap 'rm -f "$staged"' EXIT

cat > "$staged"

if [ ! -s "$staged" ]; then
    echo "atomic-write: refusing to replace $dest with empty input" >&2
    exit 1
fi

chmod "$mode" "$staged"
sync "$staged"
mv -fT "$staged" "$dest"
trap - EXIT
sync "$dir"
