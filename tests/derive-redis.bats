#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURES="$REPO_ROOT/tests/fixtures"
}

derive_redis() { bash "$REPO_ROOT/rdg/derive-redis.sh" "$1" "$2" 2>/dev/null; }

# Stderr has to be redirected INSIDE a helper, not after `run`: bats folds a
# command's stderr into $output itself, so an outer 2> never sees it and a test
# asserting on empty stdout would fail on the warning instead.
derive_redis_err() { bash "$REPO_ROOT/rdg/derive-redis.sh" "$1" "$2" 2>"$BATS_TEST_TMPDIR/err"; }

# Builds a throwaway pair of config files, so the cases the committed fixtures do
# not cover (valkey, the map relationship form, two key-value services) do not
# each need a fixture directory of their own.
scratch() {
  local app="$BATS_TEST_TMPDIR/.platform.app.yaml"
  local services="$BATS_TEST_TMPDIR/services.yaml"
  printf '%s\n' "$1" > "$app"
  printf '%s\n' "$2" > "$services"
  bash "$REPO_ROOT/rdg/derive-redis.sh" "$app" "$services" 2>"$BATS_TEST_TMPDIR/err"
}

@test "composable subdir: the redis image comes from the related service's type" {
  run derive_redis "$FIXTURES/composable-subdir/drupal/.platform.app.yaml" \
                   "$FIXTURES/composable-subdir/.platform/services.yaml"
  [ "$output" = "redis:5.0" ]
}

@test "a project with no redis service produces nothing" {
  run derive_redis "$FIXTURES/classic-root/.platform.app.yaml" \
                   "$FIXTURES/classic-root/.platform/services.yaml"
  [ "$output" = "" ]
}

@test "the extended map relationship form resolves too" {
  run scratch 'relationships:
  cache:
    service: kv
    endpoint: redis' 'kv:
  type: redis:8.0'
  [ "$output" = "redis:8.0" ]
}

@test "the relationship key name does not have to be 'redis'" {
  run scratch 'relationships:
  anything_at_all: "kv:redis"' 'kv:
  type: redis:7.2'
  [ "$output" = "redis:7.2" ]
}

@test "valkey maps to its own image namespace" {
  run scratch 'relationships:
  redis: "kv:valkey"' 'kv:
  type: valkey:8'
  [ "$output" = "valkey/valkey:8" ]
}

@test "a redis service the app does not relate to is ignored" {
  # Reproducing the version of a service the app cannot reach would be pinning
  # the local container to something the site never talks to.
  run scratch 'relationships:
  database: "maindb:mysql"' 'maindb:
  type: mariadb:10.11
orphan:
  type: redis:8.0'
  [ "$output" = "" ]
}

@test "two related redis services: the first wins, and it says so" {
  run scratch 'relationships:
  one: "first:redis"
  two: "second:redis"' 'first:
  type: redis:8.0
second:
  type: redis:7.2'
  [ "$output" = "redis:8.0" ]
  grep -q "more than one Redis-like service" "$BATS_TEST_TMPDIR/err"
}

@test "a missing services file warns and produces nothing, rather than failing the sync" {
  run derive_redis_err "$FIXTURES/composable-subdir/drupal/.platform.app.yaml" \
                       "$BATS_TEST_TMPDIR/absent.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  grep -q "not found" "$BATS_TEST_TMPDIR/err"
}

@test "a service name containing a quote does not abort with a raw yq error" {
  run scratch 'relationships:
  redis: "we\"ird:redis"' '"we\"ird":
  type: redis:8.0'
  [ "$status" -eq 0 ]
}

# --- Upsun Flex ---------------------------------------------------------------

# On Flex the app and the services live in one document, so both arguments are
# the same file and the application name is the third argument.
derive_redis_flex() {
  bash "$REPO_ROOT/rdg/derive-redis.sh" "$1" "$1" "$2" 2>/dev/null
}

@test "flex: the image comes from the related service in .upsun/config.yaml" {
  [ "$(derive_redis_flex "$FIXTURES/flex-subdir/.upsun/config.yaml" drupal)" = "redis:8.0" ]
}

@test "flex: a leftover .platform/services.yaml cannot supply the version" {
  # The stale fixture's leftover declares redis 6.2 against Flex's 8.0. Passing
  # the Flex document as the services file is the whole defence -- rdg-sync must
  # never hand this script /var/www/html/.platform/services.yaml on a Flex repo,
  # and tests/rdg-sync.bats asserts the call it actually builds.
  [ "$(derive_redis_flex "$FIXTURES/flex-stale-fixed/.upsun/config.yaml" drupal)" = "redis:8.0" ]
  grep -qF 'redis:6.2' "$FIXTURES/flex-stale-fixed/.platform/services.yaml"
}

@test "flex: an app with no Redis relationship prints nothing" {
  local cfg="$BATS_TEST_TMPDIR/noredis.yaml"
  printf 'applications:\n  app:\n    relationships:\n      database: "mysqldb:mysql"\nservices:\n  mysqldb:\n    type: mariadb:11.8\n' > "$cfg"
  [ -z "$(derive_redis_flex "$cfg" app)" ]
}

@test "flex: a valkey service derives the valkey image, as on fixed" {
  local cfg="$BATS_TEST_TMPDIR/valkey.yaml"
  printf 'applications:\n  app:\n    relationships:\n      redis: "kv:valkey"\nservices:\n  kv:\n    type: valkey:8.1\n' > "$cfg"
  [ "$(derive_redis_flex "$cfg" app)" = "valkey/valkey:8.1" ]
}
