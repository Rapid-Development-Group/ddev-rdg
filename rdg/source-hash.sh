#!/usr/bin/env bash
#ddev-generated
# Shared by rdg-sync (in the container) and check-sync.sh (on the host).
# Uses only shasum, so the host needs no yq.

# rdg_source_hash <project-root> <rel-path>...
# Hashes a manifest of NUL-separated path/sha-or-MISSING pairs rather than
# concatenated contents, so a file appearing or disappearing changes the digest.
# NUL rather than a space or newline is what makes the manifest unforgeable: a
# path may contain either of those, but not a NUL, so no crafted path can imitate
# the boundary between two entries.
rdg_source_hash() {
  local root="${1%/}"; shift
  local rel
  for rel in "$@"; do
    if [ -f "$root/$rel" ]; then
      printf '%s\0%s\0' "$rel" "$(shasum -a 256 "$root/$rel" | cut -d' ' -f1)"
    else
      printf '%s\0MISSING\0' "$rel"
    fi
  done | shasum -a 256 | cut -d' ' -f1
}
