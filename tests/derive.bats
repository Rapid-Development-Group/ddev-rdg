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

@test "extended map relationship form resolves the database and does not blame a service named 'service'" {
  local p="$BATS_TEST_TMPDIR/mapform"
  mkdir -p "$p/.platform"
  printf 'type: "php:8.2"\nrelationships:\n  database: {service: maindb, endpoint: mysql}\nweb:\n  locations:\n    "/":\n      root: "public"\n' > "$p/.platform.app.yaml"
  printf 'maindb:\n  type: mariadb:10.11\n' > "$p/.platform/services.yaml"

  run bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -eq 0 ]
  if grep -qF "'service'" <<< "$output"; then false; fi
  if grep -qF "{service" <<< "$output"; then false; fi

  [ "$(value_of "$p" '.database.type')" = "mariadb" ]
  [ "$(value_of "$p" '.database.version')" = "10.11" ]
}

@test "map relationship form without a service key warns honestly and omits the database key" {
  local p="$BATS_TEST_TMPDIR/mapform-noservice"
  mkdir -p "$p/.platform"
  printf 'type: "php:8.2"\nrelationships:\n  database: {endpoint: mysql}\nweb:\n  locations:\n    "/":\n      root: "public"\n' > "$p/.platform.app.yaml"
  printf 'maindb:\n  type: mariadb:10.11\n' > "$p/.platform/services.yaml"

  run bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -eq 0 ]
  grep -qF "malformed" <<< "$output"
  [ "$(value_of "$p" '.database')" = "null" ]
}

@test "an unsupported database version warns but still emits the database key" {
  local p="$BATS_TEST_TMPDIR/unsupported-version"
  mkdir -p "$p/.platform"
  printf 'type: "php:8.2"\nrelationships:\n  database: "somedb:mysql"\nweb:\n  locations:\n    "/":\n      root: "public"\n' > "$p/.platform.app.yaml"
  printf 'somedb:\n  type: mariadb:99.9\n' > "$p/.platform/services.yaml"

  run bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -eq 0 ]
  grep -qF "mariadb 99.9" <<< "$output"
  grep -qF "not a version DDEV" <<< "$output"

  [ "$(value_of "$p" '.database.type')" = "mariadb" ]
  [ "$(value_of "$p" '.database.version')" = "99.9" ]
}

@test "a supported database version emits no unsupported-version warning" {
  run bash "$REPO_ROOT/rdg/derive.sh" "$FIXTURES/composable-subdir"
  if grep -qF "not a version DDEV" <<< "$output"; then false; fi
}

@test "theme daemon is emitted when the docroot has a start script" {
  [ "$(value_of "$FIXTURES/composable-subdir" '.web_extra_daemons[0].name')" = "theme" ]
  [ "$(value_of "$FIXTURES/composable-subdir" '.web_extra_daemons[0].directory')" = "/var/www/html/drupal/web" ]
}

@test "webpack-family theme gets the livereload port" {
  [ "$(value_of "$FIXTURES/composable-subdir" '.web_extra_exposed_ports[0].container_port')" = "35729" ]
  [ "$(value_of "$FIXTURES/composable-subdir" '.web_extra_exposed_ports[0].name')" = "theme-devserver" ]
}

@test "vite theme gets vite's port instead" {
  [ "$(value_of "$FIXTURES/vite-theme" '.web_extra_exposed_ports[0].container_port')" = "5173" ]
}

@test "no package.json means no daemon and no ports" {
  [ "$(value_of "$FIXTURES/no-theme" '.web_extra_daemons')" = "null" ]
  [ "$(value_of "$FIXTURES/no-theme" '.web_extra_exposed_ports')" = "null" ]
}

@test "a package.json with no start script warns and emits no daemon" {
  local p="$BATS_TEST_TMPDIR/nostart"
  mkdir -p "$p/.platform" "$p/web"
  printf 'type: "php:8.3"\nweb:\n  locations:\n    "/":\n      root: "web"\n' > "$p/.platform.app.yaml"
  printf 'maindb:\n  type: mariadb:10.11\n' > "$p/.platform/services.yaml"
  printf '{"name":"x","scripts":{"build":"vite build"}}\n' > "$p/web/package.json"
  run bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -eq 0 ]
  # grep, not [[ ]] — see the Global Constraint on bats assertions.
  printf '%s' "$output" | grep -qF "no 'start' script"
  [ "$(bash "$REPO_ROOT/rdg/derive.sh" "$p" 2>/dev/null | yq -r '.web_extra_daemons')" = "null" ]
}

@test "the theme toolchain marker is present only with a theme build" {
  derive "$FIXTURES/composable-subdir" | grep -q '^# needs-theme-toolchain: yes$'
  derive "$FIXTURES/no-theme" | grep -q '^# needs-theme-toolchain: no$'
}

@test "package.json is included in the hashed source files" {
  derive "$FIXTURES/composable-subdir" | grep -q '^# source-files: .*drupal/web/package\.json'
}

@test "nothing in the generated output mentions webpack" {
  ! derive "$FIXTURES/composable-subdir" | grep -qi webpack
}

@test "a docroot containing a space is refused, not silently mis-hashed" {
  local p="$BATS_TEST_TMPDIR/space-docroot"
  mkdir -p "$p/.platform"
  printf 'type: "php:8.2"\nweb:\n  locations:\n    "/":\n      root: "my app/web"\n' > "$p/.platform.app.yaml"
  printf 'maindb:\n  type: mariadb:10.11\n' > "$p/.platform/services.yaml"

  run bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -ne 0 ]
  # grep, not [[ ]] — see the Global Constraint on bats assertions.
  printf '%s' "$output" | grep -qF "my app/web/package.json"
  ! printf '%s' "$output" | grep -q '^# source-files:'
}

@test "a malformed package.json warns honestly and does not block other keys" {
  local p="$BATS_TEST_TMPDIR/malformed"
  mkdir -p "$p/.platform" "$p/web"
  printf 'type: "php:8.3"\nweb:\n  locations:\n    "/":\n      root: "web"\n' > "$p/.platform.app.yaml"
  printf 'maindb:\n  type: mariadb:10.11\n' > "$p/.platform/services.yaml"
  printf '{ this is not valid json ' > "$p/web/package.json"
  run bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "web/package.json"
  printf '%s' "$output" | grep -qF "not valid JSON"
  # It must be the honest diagnosis, not the "no start script" false positive.
  if printf '%s' "$output" | grep -qF "no 'start' script"; then false; fi
  [ "$(value_of "$p" '.php_version')" = "8.3" ]
  [ "$(value_of "$p" '.web_extra_daemons')" = "null" ]
  [ "$(value_of "$p" '.web_extra_exposed_ports')" = "null" ]
}

@test "malformed package.json does not leak jq's raw parse error onto stderr" {
  local p="$BATS_TEST_TMPDIR/malformed-stderr"
  mkdir -p "$p/.platform" "$p/web"
  printf 'type: "php:8.3"\nweb:\n  locations:\n    "/":\n      root: "web"\n' > "$p/.platform.app.yaml"
  printf 'maindb:\n  type: mariadb:10.11\n' > "$p/.platform/services.yaml"
  printf '{ this is not valid json ' > "$p/web/package.json"
  run bash -c "bash '$REPO_ROOT/rdg/derive.sh' '$p' 2>&1 1>/dev/null"
  [ "$status" -eq 0 ]
  if printf '%s' "$output" | grep -qF "parse error"; then false; fi
}

@test "stdout stays valid YAML when package.json is malformed" {
  local p="$BATS_TEST_TMPDIR/malformed-yaml"
  mkdir -p "$p/.platform" "$p/web"
  printf 'type: "php:8.3"\nweb:\n  locations:\n    "/":\n      root: "web"\n' > "$p/.platform.app.yaml"
  printf 'maindb:\n  type: mariadb:10.11\n' > "$p/.platform/services.yaml"
  printf '{ this is not valid json ' > "$p/web/package.json"
  derive "$p" | yq -e '.' > /dev/null
}

@test "a whitespace-only start script counts as absent" {
  local p="$BATS_TEST_TMPDIR/blank-start"
  mkdir -p "$p/.platform" "$p/web"
  printf 'type: "php:8.3"\nweb:\n  locations:\n    "/":\n      root: "web"\n' > "$p/.platform.app.yaml"
  printf 'maindb:\n  type: mariadb:10.11\n' > "$p/.platform/services.yaml"
  printf '{"name":"x","scripts":{"start":"   "}}\n' > "$p/web/package.json"
  run bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "no 'start' script"
  [ "$(value_of "$p" '.web_extra_daemons')" = "null" ]
  [ "$(value_of "$p" '.web_extra_exposed_ports')" = "null" ]
}

@test "a package.json whose root is a JSON array warns and does not crash the whole derivation" {
  local p="$BATS_TEST_TMPDIR/root-array"
  mkdir -p "$p/.platform" "$p/web"
  printf 'type: "php:8.3"\nweb:\n  locations:\n    "/":\n      root: "web"\n' > "$p/.platform.app.yaml"
  printf 'maindb:\n  type: mariadb:10.11\n' > "$p/.platform/services.yaml"
  printf '["a","b"]' > "$p/web/package.json"
  run bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "not valid JSON"
  [ -n "$output" ]
  [ "$(value_of "$p" '.php_version')" = "8.3" ]
  [ "$(value_of "$p" '.web_extra_daemons')" = "null" ]
  [ "$(value_of "$p" '.web_extra_exposed_ports')" = "null" ]
  derive "$p" | yq -e '.' > /dev/null
}

@test "a package.json whose root is a JSON string warns and does not crash the whole derivation" {
  local p="$BATS_TEST_TMPDIR/root-string"
  mkdir -p "$p/.platform" "$p/web"
  printf 'type: "php:8.3"\nweb:\n  locations:\n    "/":\n      root: "web"\n' > "$p/.platform.app.yaml"
  printf 'maindb:\n  type: mariadb:10.11\n' > "$p/.platform/services.yaml"
  printf '"hello"' > "$p/web/package.json"
  run bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "not valid JSON"
  [ -n "$output" ]
  [ "$(value_of "$p" '.php_version')" = "8.3" ]
  [ "$(value_of "$p" '.web_extra_daemons')" = "null" ]
  [ "$(value_of "$p" '.web_extra_exposed_ports')" = "null" ]
  derive "$p" | yq -e '.' > /dev/null
}

@test "a package.json whose root is a JSON number warns and does not crash the whole derivation" {
  local p="$BATS_TEST_TMPDIR/root-number"
  mkdir -p "$p/.platform" "$p/web"
  printf 'type: "php:8.3"\nweb:\n  locations:\n    "/":\n      root: "web"\n' > "$p/.platform.app.yaml"
  printf 'maindb:\n  type: mariadb:10.11\n' > "$p/.platform/services.yaml"
  printf '42' > "$p/web/package.json"
  run bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "not valid JSON"
  [ -n "$output" ]
  [ "$(value_of "$p" '.php_version')" = "8.3" ]
  [ "$(value_of "$p" '.web_extra_daemons')" = "null" ]
  [ "$(value_of "$p" '.web_extra_exposed_ports')" = "null" ]
  derive "$p" | yq -e '.' > /dev/null
}

@test "a package.json whose root is JSON null warns and does not crash the whole derivation" {
  local p="$BATS_TEST_TMPDIR/root-null"
  mkdir -p "$p/.platform" "$p/web"
  printf 'type: "php:8.3"\nweb:\n  locations:\n    "/":\n      root: "web"\n' > "$p/.platform.app.yaml"
  printf 'maindb:\n  type: mariadb:10.11\n' > "$p/.platform/services.yaml"
  printf 'null' > "$p/web/package.json"
  run bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF "not valid JSON"
  [ -n "$output" ]
  [ "$(value_of "$p" '.php_version')" = "8.3" ]
  [ "$(value_of "$p" '.web_extra_daemons')" = "null" ]
  [ "$(value_of "$p" '.web_extra_exposed_ports')" = "null" ]
  derive "$p" | yq -e '.' > /dev/null
}
