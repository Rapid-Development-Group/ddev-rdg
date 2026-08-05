#!/usr/bin/env bats

# Coverage for commands/host/rdg-sync, the one component that normally needs a
# running DDEV project. It does not need a real one: the only thing it uses ddev
# for is 'ddev exec <cmd>', so a stub on PATH that maps the container paths back
# onto a synthetic project directory drives the whole script -- the conflict
# pre-flight, the gather-before-write ordering, and the files it emits.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SYNC="$REPO_ROOT/commands/host/rdg-sync"
  PROJ="$BATS_TEST_TMPDIR/proj"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"

  mkdir -p "$PROJ/.ddev/rdg" "$STUB_BIN"
  # rdg2020's shape: composable type, app config one level down, theme build,
  # one web.location outside the docroot.
  cp -R "$REPO_ROOT/tests/fixtures/composable-subdir/." "$PROJ/"
  cp "$REPO_ROOT"/rdg/*.sh "$PROJ/.ddev/rdg/"
  printf 'name: proj\ntype: drupal11\n' > "$PROJ/.ddev/config.yaml"

  cat > "$STUB_BIN/ddev" <<'STUB'
#!/usr/bin/env bash
# Test double for the ddev CLI. rdg-sync only ever runs 'ddev exec <cmd...>'.
set -uo pipefail
if [ "${1:-}" != "exec" ]; then
  echo "stub ddev: expected 'exec', got: $*" >&2
  exit 64
fi
shift
mnt_prefix="/mnt/ddev_config"
app_prefix="/var/www/html"
args=()
for a in "$@"; do
  a="${a//$mnt_prefix/$RDG_TEST_PROJ/.ddev}"
  a="${a//$app_prefix/$RDG_TEST_PROJ}"
  args+=("$a")
done
# RDG_TEST_FAIL_ON names the argv[0] of the container call that should fail, so a
# test can pick which step of the gather phase breaks.
if [ -n "${RDG_TEST_FAIL_ON:-}" ] && [ "${args[0]}" = "$RDG_TEST_FAIL_ON" ]; then
  echo "stub ddev: forced failure for '${args[0]}'" >&2
  exit 1
fi
case "${args[0]}" in
  # No PHP on the test host, and the extension check only compares two lists.
  php) printf 'redis\napcu\n' ;;
  *)   "${args[@]}" ;;
esac
STUB
  chmod +x "$STUB_BIN/ddev"
}

sync_run() {
  run env PATH="$STUB_BIN:$PATH" DDEV_APPROOT="$PROJ" RDG_TEST_PROJ="$PROJ" "$@" bash "$SYNC"
}

generated_files_absent() {
  [ ! -f "$PROJ/.ddev/config.platformsh.yaml" ]
  [ ! -f "$PROJ/.ddev/nginx/platform-locations.conf" ]
  [ ! -f "$PROJ/.ddev/web-build/Dockerfile.rdg-theme" ]
}

# --- happy path --------------------------------------------------------------

@test "writes all three generated files and matches the committed expected output" {
  sync_run
  [ "$status" -eq 0 ]
  diff -u "$REPO_ROOT/tests/expected/composable-subdir.config.platformsh.yaml" \
          "$PROJ/.ddev/config.platformsh.yaml"
  diff -u "$REPO_ROOT/tests/expected/composable-subdir.platform-locations.conf" \
          "$PROJ/.ddev/nginx/platform-locations.conf"
  [ -f "$PROJ/.ddev/web-build/Dockerfile.rdg-theme" ]
}

@test "syncing twice in a row succeeds: its own output is not read as a conflict" {
  sync_run
  [ "$status" -eq 0 ]
  sync_run
  [ "$status" -eq 0 ]
}

# --- native mode -------------------------------------------------------------

@test "native mode: explains which file is the source of truth and succeeds" {
  # Previously this fell through to derive.sh and died with "no .platform.app.yaml",
  # which reads as a broken install rather than as a project with nothing to derive.
  # Exit 0 because running it here is a no-op, not an error.
  find "$PROJ" -name .platform.app.yaml -delete
  rm -rf "$PROJ/.platform"
  sync_run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s' "$output" | grep -qF 'not on Upsun'
  printf '%s' "$output" | grep -qF '.ddev/config.yaml'
  generated_files_absent
}

@test "native mode: a hand-written web_extra_daemons block is not a conflict" {
  # The conflict pre-flight exists because DDEV appends list keys, so a hand-written
  # daemon would coexist with the derived one and collide on container_port. In
  # native mode nothing is derived, so the hand-written block is the only one -- and
  # is exactly what the docs tell a native repo to write. Refusing would make the
  # documented setup un-syncable.
  find "$PROJ" -name .platform.app.yaml -delete
  rm -rf "$PROJ/.platform"
  printf 'name: proj\nweb_extra_daemons:\n    - name: theme\n      command: "true"\n' \
    > "$PROJ/.ddev/config.yaml"
  sync_run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s' "$output" | grep -qF 'not on Upsun'
}

# --- the conflict pre-flight -------------------------------------------------

@test "refuses, and writes nothing, when config.yaml declares web_extra_daemons" {
  printf 'name: proj\nweb_extra_daemons:\n    - name: theme\n      command: "true"\n' \
    > "$PROJ/.ddev/config.yaml"
  sync_run
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'web_extra_daemons in .ddev/config.yaml'
  generated_files_absent
}

@test "refuses when a second config file declares web_extra_exposed_ports" {
  printf 'web_extra_exposed_ports:\n    - name: theme-devserver\n      container_port: 35729\n' \
    > "$PROJ/.ddev/config.ports.yaml"
  sync_run
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'web_extra_exposed_ports in .ddev/config.ports.yaml'
  generated_files_absent
}

@test "the conflict check reads .yml, which DDEV merges just like .yaml" {
  # DDEV globs .ddev/config.*.y*ml. A check that only looked at config*.yaml
  # would let this file through, write the derived block beside it, and leave DDEV
  # refusing to load the project at all for a duplicate container_port.
  printf 'web_extra_daemons:\n    - name: theme\n      command: "true"\n' \
    > "$PROJ/.ddev/config.dev.yml"
  sync_run
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'web_extra_daemons in .ddev/config.dev.yml'
  generated_files_absent
}

@test "a UTF-8 BOM before the key does not hide it from the conflict check" {
  # DDEV's YAML parser skips the BOM, so this is a top-level key it merges.
  printf '\357\273\277web_extra_daemons:\n    - name: theme\n      command: "true"\n' \
    > "$PROJ/.ddev/config.bom.yaml"
  sync_run
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'web_extra_daemons in .ddev/config.bom.yaml'
  generated_files_absent
}

@test "a quoted top-level key does not hide it from the conflict check" {
  printf '"web_extra_exposed_ports":\n    - name: theme-devserver\n      container_port: 35729\n' \
    > "$PROJ/.ddev/config.quoted.yaml"
  sync_run
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'web_extra_exposed_ports in .ddev/config.quoted.yaml'
  generated_files_absent
}

@test "a single-quoted top-level key does not hide it from the conflict check" {
  printf "'web_extra_daemons':\n    - name: theme\n      command: \"true\"\n" \
    > "$PROJ/.ddev/config.squoted.yaml"
  sync_run
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'web_extra_daemons in .ddev/config.squoted.yaml'
}

@test "an indented occurrence of the key is not a conflict" {
  # Indentation means it is not a top-level key, so DDEV does not merge it and
  # there is nothing to collide with. Refusing here would send someone hunting for
  # a conflicting block that does not exist.
  cat > "$PROJ/.ddev/config.nested.yaml" <<'YAML'
name: proj
hooks:
    post-start:
        - exec: "echo web_extra_daemons: none"
some_other_map:
    web_extra_daemons: not-a-top-level-key
YAML
  sync_run
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.ddev/config.platformsh.yaml" ]
}

@test "a commented-out block is not a conflict" {
  printf '# web_extra_daemons:\n#     - name: theme\n' > "$PROJ/.ddev/config.old.yaml"
  sync_run
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.ddev/config.platformsh.yaml" ]
}

# --- gather before write -----------------------------------------------------

@test "a failed container call late in the gather phase writes nothing at all" {
  # 'php -m' is the last container call. Writing config.platformsh.yaml before the
  # gather phase finished would leave a repo with a derived daemon block, possibly
  # colliding with its own config, and every later 'ddev exec' -- including the one
  # that would fix it -- failing. Either all files are written or none are.
  sync_run RDG_TEST_FAIL_ON=php
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'nothing was written'
  generated_files_absent
}

@test "a failed yq call in the gather phase writes nothing at all" {
  sync_run RDG_TEST_FAIL_ON=yq
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'nothing was written'
  generated_files_absent
}

@test "a stale generated file is left in place when the gather phase fails" {
  # The point of gathering first is that the project stays exactly as loadable as
  # it was. A half-written file would be worse than an out-of-date one.
  sync_run
  [ "$status" -eq 0 ]
  cp "$PROJ/.ddev/config.platformsh.yaml" "$BATS_TEST_TMPDIR/before"
  sync_run RDG_TEST_FAIL_ON=php
  [ "$status" -ne 0 ]
  diff -u "$BATS_TEST_TMPDIR/before" "$PROJ/.ddev/config.platformsh.yaml"
}

# --- housekeeping the writes do -------------------------------------------

@test "the nginx snippet and Dockerfile are removed when the repo stops needing them" {
  sync_run
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.ddev/nginx/platform-locations.conf" ]
  [ -f "$PROJ/.ddev/web-build/Dockerfile.rdg-theme" ]

  # Drop the theme build and the extra web.location.
  rm "$PROJ/drupal/web/package.json"
  cat > "$PROJ/drupal/.platform.app.yaml" <<'YAML'
name: "drupal"
type: "composable:25.11"
stack:
  runtimes:
    - "php@8.3"
relationships:
  database: "mysqldb:mysql"
web:
  locations:
    "/":
      root: "web"
      passthru: "/index.php"
YAML
  sync_run
  [ "$status" -eq 0 ]
  [ ! -f "$PROJ/.ddev/nginx/platform-locations.conf" ]
  [ ! -f "$PROJ/.ddev/web-build/Dockerfile.rdg-theme" ]
}

@test "extensions that are all loaded produce no warning" {
  # The fixture declares redis and apcu; the stub's 'php -m' reports both.
  sync_run
  [ "$status" -eq 0 ]
  if printf '%s' "$output" | grep -qF 'WARNING: declared in'; then false; fi
}

@test "an extension declared in the app config but not loaded produces a warning" {
  cat > "$PROJ/drupal/.platform.app.yaml" <<'YAML'
name: "drupal"
type: "composable:25.11"
stack:
  runtimes:
    - "php@8.3":
        extensions:
          - redis
          - imagick
    - "nodejs@20"
relationships:
  database: "mysqldb:mysql"
web:
  locations:
    "/":
      root: "web"
      passthru: "/index.php"
YAML
  sync_run
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'imagick'
}
