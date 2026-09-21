#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURES="$REPO_ROOT/tests/fixtures"
  EXPECTED="$REPO_ROOT/tests/expected"
}

derive() { bash "$REPO_ROOT/rdg/derive.sh" "$1" 2>/dev/null; }
value_of() { derive "$1" | yq -r "$2"; }

# Diffs the whole generated file against a committed golden. The per-key
# assertions below say what each value should be and why; this says that nothing
# ELSE changed. It is what catches a regression in a line no assertion names --
# the daemon's command string, the exposed ports, the header format -- rather than
# waiting for someone to notice and add the missing assertion afterwards.
#
# To update a golden after a deliberate change:
#   bash rdg/derive.sh tests/fixtures/<f> 2>/dev/null > tests/expected/<f>.config.<shape>.yaml
#
# The golden's name carries the shape because the generated file's name does:
# config.platformsh.yaml on Upsun Fixed, config.upsun.yaml on Upsun Flex.
golden() {
  local fixture="$1" shape="${2:-platformsh}"
  derive "$FIXTURES/$fixture" > "$BATS_TEST_TMPDIR/actual"
  diff -u "$EXPECTED/$fixture.config.$shape.yaml" "$BATS_TEST_TMPDIR/actual"
}

@test "golden: composable subdir generates exactly the committed expected output" {
  golden composable-subdir
}

@test "golden: classic root generates exactly the committed expected output" {
  golden classic-root
}

@test "golden: no theme build generates exactly the committed expected output" {
  golden no-theme
}

@test "golden: vite theme generates exactly the committed expected output" {
  golden vite-theme
}

@test "golden: upsun flex generates exactly the committed expected output" {
  golden flex-subdir upsun
}

@test "golden: a converted repo derives from Flex, ignoring its Fixed leftovers" {
  # The fixture's .platform.app.yaml and .platform/services.yaml declare php 8.1,
  # node 18, mariadb 10.6 and a 'public' docroot -- every one of them different
  # from the Flex values -- so reading the wrong file cannot pass by coincidence.
  golden flex-stale-fixed upsun
}

# --- Upsun Flex ---------------------------------------------------------------

@test "flex: runtimes, database and docroot all come from .upsun/config.yaml" {
  local f="$FIXTURES/flex-subdir"
  [ "$(value_of "$f" '.php_version')" = "8.4" ]
  [ "$(value_of "$f" '.nodejs_version')" = "22" ]
  [ "$(value_of "$f" '.database.type')" = "mariadb" ]
  [ "$(value_of "$f" '.database.version')" = "11.8" ]
}

@test "flex: the app root comes from source.root, not from where the file sits" {
  # .upsun/config.yaml lives at the repo root in every Flex repo, so the app root
  # cannot be inferred from its path the way it is on Fixed. source.root is
  # '/drupal/' here, with both slashes optional in practice.
  local f="$FIXTURES/flex-subdir"
  [ "$(value_of "$f" '.composer_root')" = "drupal" ]
  [ "$(value_of "$f" '.docroot')" = "drupal/web" ]
}

@test "flex: a source.root of '/' or absent means the repo root" {
  local proj="$BATS_TEST_TMPDIR/rootapp"
  mkdir -p "$proj/.upsun"
  printf 'applications:\n  app:\n    type: "composable:26.05"\n    stack:\n      runtimes:\n        - "php@8.4"\n    web:\n      locations:\n        "/":\n          root: "web"\n    source:\n      root: /\n' \
    > "$proj/.upsun/config.yaml"
  [ "$(value_of "$proj" '.docroot')" = "web" ]
  [ "$(derive "$proj" | grep -c '^composer_root:')" -eq 0 ]
}

@test "flex: only .upsun/config.yaml is hashed, never a leftover services file" {
  # A .platform/services.yaml the derivation never reads must not be in the
  # source-files header: hashing it would mean an edit to dead config aborts every
  # 'ddev start' until someone re-syncs, and the re-sync then changes nothing --
  # a block with no way out through the command that is supposed to clear it.
  local header
  header="$(derive "$FIXTURES/flex-stale-fixed" | sed -n 's/^# source-files: //p')"
  [ "$header" = ".upsun/config.yaml drupal/web/package.json" ]
}

@test "flex: the application name is recorded for the host to read back" {
  # commands/host/rdg-sync runs on the host, which has no yq, and has to pass the
  # same app name to nginx-locations.sh and derive-redis.sh.
  [ "$(derive "$FIXTURES/flex-subdir" | sed -n 's/^# source-app: //p')" = "drupal" ]
}

@test "fixed: no source-app line, because there is no application to name" {
  [ -z "$(derive "$FIXTURES/composable-subdir" | sed -n 's/^# source-app: //p')" ]
}

@test "flex: several applications is an error naming RDG_APP, not a silent guess" {
  local proj="$BATS_TEST_TMPDIR/multi"
  mkdir -p "$proj/.upsun"
  printf 'applications:\n  api:\n    type: "composable:26.05"\n  web:\n    type: "composable:26.05"\n' \
    > "$proj/.upsun/config.yaml"
  run bash "$REPO_ROOT/rdg/derive.sh" "$proj"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'RDG_APP'
  printf '%s' "$output" | grep -qF 'api web'
}

@test "flex: RDG_APP picks one of several applications" {
  local proj="$BATS_TEST_TMPDIR/multi2"
  mkdir -p "$proj/.upsun"
  printf 'applications:\n  api:\n    type: "composable:26.05"\n    stack:\n      runtimes:\n        - "php@8.2"\n  web:\n    type: "composable:26.05"\n    stack:\n      runtimes:\n        - "php@8.4"\n' \
    > "$proj/.upsun/config.yaml"
  run env RDG_APP=web bash "$REPO_ROOT/rdg/derive.sh" "$proj"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'php_version: "8.4"'
}

@test "flex: RDG_APP naming an application that does not exist is an error" {
  local proj="$BATS_TEST_TMPDIR/multi3"
  mkdir -p "$proj/.upsun"
  printf 'applications:\n  api:\n    type: "composable:26.05"\n' > "$proj/.upsun/config.yaml"
  run env RDG_APP=nope bash "$REPO_ROOT/rdg/derive.sh" "$proj"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'declares no such application'
}

@test "flex: crons, mounts and hooks are reported as not translated" {
  run bash "$REPO_ROOT/rdg/derive.sh" "$FIXTURES/flex-subdir"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'crons declared in .upsun/config.yaml'
  printf '%s' "$output" | grep -qF 'mounts declared in .upsun/config.yaml'
  printf '%s' "$output" | grep -qF 'build/deploy hooks declared in .upsun/config.yaml'
}

@test "composable subdir: php version comes from stack.runtimes" {
  [ "$(value_of "$FIXTURES/composable-subdir" '.php_version')" = "8.3" ]
}

@test "composable subdir: nodejs version comes from stack.runtimes" {
  [ "$(value_of "$FIXTURES/composable-subdir" '.nodejs_version')" = "20" ]
}

@test "a long runtimes list still derives the first entry: no SIGPIPE abort" {
  # Regression. runtime_version piped yq into 'awk {print; exit}'. awk exiting on
  # its first match closed the pipe under yq, yq died of SIGPIPE, pipefail made
  # that the pipeline's status, and set -e aborted derive.sh -- so php_version
  # simply vanished from the output. php was what tripped it, being FIRST in the
  # list; nodejs, last, let yq finish writing. On CI that presented as a single
  # intermittently failing test rather than a bug.
  #
  # The stock fixture's two runtimes are too few to lose the race reliably.
  # Padding the list keeps yq writing past awk's match, which reproduced the
  # abort 20/20 against the old code.
  local proj="$BATS_TEST_TMPDIR/padded"
  cp -R "$FIXTURES/composable-subdir" "$proj"
  local cfg="$proj/drupal/.platform.app.yaml" i
  {
    printf 'type: "composable:25.11"\nstack:\n  runtimes:\n'
    printf '    - "php@8.3"\n    - "nodejs@20"\n'
    for i in $(seq 1 4000); do printf '    - "pad%s@1.0"\n' "$i"; done
    # Keep the rest of the app config so the whole derivation still runs.
    sed -n '/^web:/,$p' "$cfg"
  } > "$cfg.padded"
  mv "$cfg.padded" "$cfg"

  run bash "$REPO_ROOT/rdg/derive.sh" "$proj"
  [ "$status" -eq 0 ] || { echo "derive.sh exited $status"; echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'php_version: "8.3"'
  printf '%s\n' "$output" | grep -qx 'nodejs_version: "20"'
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

@test "a service name containing a double quote resolves instead of aborting with a yq error" {
  # The service name is interpolated into a yq expression. Concatenating it into
  # the expression string lets a quote close the yq string early, so the whole
  # derivation dies on a raw yq parse error rather than reaching any of the
  # warnings this script is written to give. strenv() keeps it out of the syntax.
  local p="$BATS_TEST_TMPDIR/quoted-service"
  mkdir -p "$p/.platform"
  printf 'type: "php:8.3"\nrelationships:\n  database: %s\nweb:\n  locations:\n    "/":\n      root: "web"\n' \
    "'db\"x:mysql'" > "$p/.platform.app.yaml"
  printf "'db\"x':\n  type: mariadb:10.11\n" > "$p/.platform/services.yaml"

  run bash "$REPO_ROOT/rdg/derive.sh" "$p"
  [ "$status" -eq 0 ]
  if printf '%s' "$output" | grep -qiF 'invalid input text'; then false; fi
  [ "$(value_of "$p" '.database.type')" = "mariadb" ]
  [ "$(value_of "$p" '.database.version')" = "10.11" ]
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

@test "the daemon command names the script install.yaml actually installs" {
  # The only coupling point between derive.sh and where the add-on puts
  # theme-watch.sh. /mnt/ddev_config is the project's .ddev directory, and
  # install.yaml ships rdg/ into it, so resolve the emitted path back to this repo
  # and require the file to be there. A path that does not resolve gives a daemon
  # that crash-loops with "No such file or directory" 15 times and then gives up.
  local cmd rel
  cmd="$(value_of "$FIXTURES/composable-subdir" '.web_extra_daemons[0].command')"
  [ "$cmd" = "bash /mnt/ddev_config/rdg/theme-watch.sh" ]
  rel="${cmd#bash /mnt/ddev_config/}"
  [ -f "$REPO_ROOT/$rel" ]
}

@test "webpack-family theme gets the livereload port" {
  [ "$(value_of "$FIXTURES/composable-subdir" '.web_extra_exposed_ports[0].container_port')" = "35729" ]
  [ "$(value_of "$FIXTURES/composable-subdir" '.web_extra_exposed_ports[0].name')" = "theme-devserver" ]
}

@test "vite theme gets vite's port instead" {
  [ "$(value_of "$FIXTURES/vite-theme" '.web_extra_exposed_ports[0].container_port')" = "5173" ]
}

@test "the exposed http and https ports differ, and neither is left unset" {
  # DDEV rejects the project outright with a dedicated error when they match:
  # "the <name> project has the same 'http_port: N' and 'https_port: N' for
  # 'name: X' in web_extra_exposed_ports". Deriving all three from one number
  # makes that an easy mistake to make.
  local out http https container
  out="$(derive "$FIXTURES/composable-subdir")"
  container="$(printf '%s\n' "$out" | yq -r '.web_extra_exposed_ports[0].container_port')"
  http="$(printf '%s\n' "$out" | yq -r '.web_extra_exposed_ports[0].http_port')"
  https="$(printf '%s\n' "$out" | yq -r '.web_extra_exposed_ports[0].https_port')"
  [ "$container" = "35729" ]
  [ "$http" = "35728" ]
  [ "$https" = "35729" ]
  [ "$http" != "$https" ]
}

@test "the vite port pair differs too, not just the default one" {
  local http https
  http="$(value_of "$FIXTURES/vite-theme" '.web_extra_exposed_ports[0].http_port')"
  https="$(value_of "$FIXTURES/vite-theme" '.web_extra_exposed_ports[0].https_port')"
  [ "$http" = "5172" ]
  [ "$https" = "5173" ]
  [ "$http" != "$https" ]
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

@test "no theme-toolchain marker is emitted: the toolchain is shipped, not derived" {
  # Until v1.5.0 this header told rdg-sync whether to generate
  # web-build/Dockerfile.rdg-theme. The toolchain now ships with the add-on
  # unconditionally, so nothing should consume or emit the header -- a stray one would
  # mean the two mechanisms had both come back.
  local f
  for f in composable-subdir no-theme classic-root vite-theme; do
    ! derive "$FIXTURES/$f" | grep -q 'needs-theme-toolchain'
  done
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
