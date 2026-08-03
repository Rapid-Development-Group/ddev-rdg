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
