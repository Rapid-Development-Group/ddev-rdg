#!/usr/bin/env bash
# Shared by rdg-sync (in the container) and check-sync.sh (on the host).
# Uses only shasum, so the host needs no yq.

# rdg_source_hash <project-root> <rel-path>...
# Hashes a manifest of "path <sha-or-MISSING>" lines rather than concatenated
# contents, so a file appearing or disappearing changes the digest.
rdg_source_hash() {
  local root="${1%/}"; shift
  local path
  for path in "$@"; do
    if [ -f "$root/$path" ]; then
      printf '%s %s\n' "$path" "$(shasum -a 256 "$root/$path" | cut -d' ' -f1)"
    else
      printf '%s MISSING\n' "$path"
    fi
  done | shasum -a 256 | cut -d' ' -f1
}
