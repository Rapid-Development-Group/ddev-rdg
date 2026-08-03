#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO_ROOT/rdg/source-hash.sh"
  TMP="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$TMP"
  printf 'a\n' > "$TMP/one.yaml"
}

@test "digest is stable for identical input" {
  a="$(rdg_source_hash "$TMP" one.yaml)"
  b="$(rdg_source_hash "$TMP" one.yaml)"
  [ "$a" = "$b" ]
}

@test "digest changes when a hashed file changes" {
  a="$(rdg_source_hash "$TMP" one.yaml)"
  printf 'b\n' > "$TMP/one.yaml"
  b="$(rdg_source_hash "$TMP" one.yaml)"
  [ "$a" != "$b" ]
}

@test "a missing file is hashed as MISSING, not skipped" {
  a="$(rdg_source_hash "$TMP" one.yaml two.json)"
  printf 'x\n' > "$TMP/two.json"
  b="$(rdg_source_hash "$TMP" one.yaml two.json)"
  [ "$a" != "$b" ]
}

@test "path order does not depend on the filesystem" {
  a="$(rdg_source_hash "$TMP" one.yaml two.json)"
  b="$(rdg_source_hash "$TMP" two.json one.yaml)"
  [ "$a" != "$b" ]
}

@test "function works under zsh" {
  if ! command -v zsh >/dev/null 2>&1; then
    skip "zsh not available"
  fi
  bash_result="$(rdg_source_hash "$TMP" one.yaml)"
  zsh_result="$(zsh -c "source '$REPO_ROOT/rdg/source-hash.sh'; rdg_source_hash '$TMP' one.yaml")"
  [ "$bash_result" = "$zsh_result" ]
  # Verify it's a 64-character hex digest
  [[ "$zsh_result" =~ ^[0-9a-f]{64}$ ]]
}

@test "manifest format prevents collisions via newlines and spaces" {
  # Hash two paths where the second is missing
  a="$(rdg_source_hash "$TMP" one.yaml two.json)"

  # Try to forge the same manifest by creating a path that embeds the first path's manifest
  # The crafted path contains: "one.yaml <sha-of-one.yaml>\ntwo.json"
  first_sha="$(shasum -a 256 "$TMP/one.yaml" | cut -d' ' -f1)"
  crafted_arg=$'one.yaml '"$first_sha"$'\ntwo.json'
  b="$(rdg_source_hash "$TMP" "$crafted_arg")"

  # These digests must be different to avoid collision
  [ "$a" != "$b" ]
}
