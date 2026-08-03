#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURES="$REPO_ROOT/tests/fixtures"
  SCRIPT="$REPO_ROOT/rdg/nginx-locations.sh"
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
