#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURES="$REPO_ROOT/tests/fixtures"
}

derive() { bash "$REPO_ROOT/rdg/derive.sh" "$1" 2>/dev/null; }
value_of() { derive "$1" | yq -r "$2"; }

@test "composable subdir: php version comes from stack.runtimes" {
  [ "$(value_of "$FIXTURES/composable-subdir" '.php_version')" = "8.3" ]
}

@test "composable subdir: nodejs version comes from stack.runtimes" {
  [ "$(value_of "$FIXTURES/composable-subdir" '.nodejs_version')" = "20" ]
}

@test "composable subdir: docroot is prefixed with the app root" {
  [ "$(value_of "$FIXTURES/composable-subdir" '.docroot')" = "drupal/web" ]
}

@test "composable subdir: composer_root is the app root" {
  [ "$(value_of "$FIXTURES/composable-subdir" '.composer_root')" = "drupal" ]
}

@test "composable subdir: database resolves through the relationship" {
  [ "$(value_of "$FIXTURES/composable-subdir" '.database.type')" = "mariadb" ]
  [ "$(value_of "$FIXTURES/composable-subdir" '.database.version')" = "10.11" ]
}

@test "classic root: php version comes from type" {
  [ "$(value_of "$FIXTURES/classic-root" '.php_version')" = "8.2" ]
}

@test "classic root: docroot is not prefixed" {
  [ "$(value_of "$FIXTURES/classic-root" '.docroot')" = "public" ]
}

@test "classic root: composer_root is omitted entirely" {
  [ "$(value_of "$FIXTURES/classic-root" '.composer_root')" = "null" ]
}

@test "classic root: postgresql maps to the postgres ddev type" {
  [ "$(value_of "$FIXTURES/classic-root" '.database.type')" = "postgres" ]
  [ "$(value_of "$FIXTURES/classic-root" '.database.version')" = "16" ]
}

@test "output carries a source-sha256 line" {
  derive "$FIXTURES/composable-subdir" | grep -q '^# source-sha256: [0-9a-f]\{64\}$'
}

@test "output carries a source-files line naming the app config" {
  derive "$FIXTURES/composable-subdir" | grep -q '^# source-files: .*drupal/\.platform\.app\.yaml'
}

@test "no app config anywhere is a hard error" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  run bash "$REPO_ROOT/rdg/derive.sh" "$BATS_TEST_TMPDIR/empty"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no .platform.app.yaml"* ]]
}

@test "two candidate app configs is a hard error naming both" {
  local p="$BATS_TEST_TMPDIR/two"
  mkdir -p "$p/a" "$p/b"
  printf 'type: "php:8.3"\n' > "$p/a/.platform.app.yaml"
  printf 'type: "php:8.3"\n' > "$p/b/.platform.app.yaml"
  run bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -ne 0 ]
  [[ "$output" == *"RDG_APP_ROOT"* ]]
}

@test "RDG_APP_ROOT selects among candidates" {
  local p="$BATS_TEST_TMPDIR/two"
  mkdir -p "$p/a" "$p/b"
  printf 'type: "php:8.1"\nweb:\n  locations:\n    "/":\n      root: "a-web"\n' > "$p/a/.platform.app.yaml"
  printf 'type: "php:8.4"\nweb:\n  locations:\n    "/":\n      root: "b-web"\n' > "$p/b/.platform.app.yaml"
  run env RDG_APP_ROOT=b bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -eq 0 ]
  [[ "$output" == *'php_version: "8.4"'* ]]
}

@test "crons and mounts are reported as untranslated" {
  run bash "$REPO_ROOT/rdg/derive.sh" "$FIXTURES/composable-subdir"
  [[ "$output" == *"not reproduced locally"* ]]
}
