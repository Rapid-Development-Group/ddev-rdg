#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURES="$REPO_ROOT/tests/fixtures"
  EXPECTED="$REPO_ROOT/tests/expected"
  SCRIPT="$REPO_ROOT/rdg/nginx-locations.sh"
}

# See the note on golden() in derive.bats. Regenerate with:
#   bash rdg/nginx-locations.sh tests/fixtures/composable-subdir/drupal/.platform.app.yaml \
#     drupal/web > tests/expected/composable-subdir.platform-locations.conf
@test "golden: the generated snippet is exactly the committed expected output" {
  bash "$SCRIPT" "$FIXTURES/composable-subdir/drupal/.platform.app.yaml" drupal/web \
    > "$BATS_TEST_TMPDIR/actual"
  diff -u "$EXPECTED/composable-subdir.platform-locations.conf" "$BATS_TEST_TMPDIR/actual"
}

@test "each emitted block has a try_files fallback" {
  # Without it nginx serves the directory listing / 403s instead of index.html,
  # and every miss under the prefix falls through to Drupal rather than 404ing.
  local blocks tries
  blocks="$(bash "$SCRIPT" "$FIXTURES/composable-subdir/drupal/.platform.app.yaml" drupal/web \
            | grep -c '^location \^~ ')"
  tries="$(bash "$SCRIPT" "$FIXTURES/composable-subdir/drupal/.platform.app.yaml" drupal/web \
           | grep -cF 'try_files $uri $uri/index.html =404;')"
  [ "$blocks" -ge 1 ]
  [ "$blocks" = "$tries" ]
}

@test "emits a block for a location outside the docroot" {
  run bash "$SCRIPT" "$FIXTURES/composable-subdir/drupal/.platform.app.yaml" drupal/web
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'location ^~ /drupal-integrations'
}

@test "uses prefix matching, never a regex location" {
  run bash "$SCRIPT" "$FIXTURES/composable-subdir/drupal/.platform.app.yaml" drupal/web
  ! printf '%s' "$output" | grep -qF 'location ~'
}

@test "resolves the root against the app root, not the repo root" {
  run bash "$SCRIPT" "$FIXTURES/composable-subdir/drupal/.platform.app.yaml" drupal/web
  printf '%s' "$output" | grep -qF '/var/www/html/drupal/landing-pages'
}

@test "skips the root location" {
  run bash "$SCRIPT" "$FIXTURES/composable-subdir/drupal/.platform.app.yaml" drupal/web
  ! printf '%s' "$output" | grep -qF 'location ^~ / '
}

@test "skips locations whose root is inside the docroot" {
  run bash "$SCRIPT" "$FIXTURES/composable-subdir/drupal/.platform.app.yaml" drupal/web
  ! printf '%s' "$output" | grep -qF 'sites/default/files'
}

@test "emits nothing when there are no extra locations" {
  run bash "$SCRIPT" "$FIXTURES/no-theme/.platform.app.yaml" web
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "uses root when the location name matches the last path segment" {
  run bash "$SCRIPT" "$FIXTURES/composable-subdir/drupal/.platform.app.yaml" drupal/web
  printf '%s' "$output" | grep -qF 'root /var/www/html/drupal/landing-pages;'
}

@test "uses alias when the location name does not match the last path segment" {
  local p="$BATS_TEST_TMPDIR/mismatch.yaml"
  cat > "$p" <<'YAML'
web:
  locations:
    "/":
      root: "web"
    "/marketing":
      root: "static/campaign-pages"
YAML
  run bash "$SCRIPT" "$p" web
  printf '%s' "$output" | grep -qF 'alias /var/www/html/static/campaign-pages;'
}

# --- Upsun Flex ---------------------------------------------------------------

# Regenerate with:
#   bash rdg/nginx-locations.sh tests/fixtures/flex-subdir/.upsun/config.yaml \
#     drupal/web drupal 2>/dev/null > tests/expected/flex-subdir.platform-locations.conf
@test "golden: flex generates exactly the committed expected output" {
  bash "$SCRIPT" "$FIXTURES/flex-subdir/.upsun/config.yaml" drupal/web drupal \
    2>/dev/null > "$BATS_TEST_TMPDIR/actual"
  diff -u "$EXPECTED/flex-subdir.platform-locations.conf" "$BATS_TEST_TMPDIR/actual"
}

@test "flex: locations are read from the named application, not the document root" {
  # Without the third argument the app_expr stays '.', .web.locations resolves
  # against the document root of .upsun/config.yaml, and nothing is found -- which
  # looks exactly like a repo that legitimately has no extra locations.
  local with without
  with="$(bash "$SCRIPT" "$FIXTURES/flex-subdir/.upsun/config.yaml" drupal/web drupal 2>/dev/null)"
  without="$(bash "$SCRIPT" "$FIXTURES/flex-subdir/.upsun/config.yaml" drupal/web 2>/dev/null)"
  printf '%s' "$with" | grep -q '^location \^~ /drupal-integrations'
  [ -z "$without" ]
}

@test "a location that runs scripts is skipped, and said out loud" {
  # 'scripts: true' means a PHP entry point: it needs fastcgi_pass and a
  # SCRIPT_FILENAME, not the static try_files block this script emits. Emitting
  # the static one would answer every request with a confident 404 -- worse than
  # emitting nothing -- so it is skipped and named, pointing at .ddev/nginx/.
  local out err
  out="$(bash "$SCRIPT" "$FIXTURES/flex-subdir/.upsun/config.yaml" drupal/web drupal \
         2>"$BATS_TEST_TMPDIR/err")"
  ! printf '%s' "$out" | grep -q 'sendgrid-webhook'
  grep -qF '/sendgrid-webhook' "$BATS_TEST_TMPDIR/err"
  grep -qF '.ddev/nginx' "$BATS_TEST_TMPDIR/err"
}

@test "a location that explicitly sets scripts: false is still emitted" {
  # Only 'true' skips. A location declaring scripts: false is static by
  # definition, and the common case -- no scripts key at all -- must not be read
  # as anything but static either.
  local cfg="$BATS_TEST_TMPDIR/scripts-false.yaml"
  printf 'applications:\n  app:\n    web:\n      locations:\n        "/":\n          root: "web"\n        "/assets":\n          root: "static/assets"\n          scripts: false\n' > "$cfg"
  bash "$SCRIPT" "$cfg" drupal/web app 2>/dev/null | grep -q '^location \^~ /assets'
}
