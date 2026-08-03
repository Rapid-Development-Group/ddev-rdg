#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/rdg/theme-watch.sh"
}

@test "the watcher never names a specific bundler" {
  ! grep -qiE 'webpack|vite' "$SCRIPT"
}

@test "the watcher runs the repo's own start script" {
  # Scoped to active lines: the file's own explanatory comment also says
  # 'yarn start', so a whole-file grep passes even if the real invocation
  # is mutated to something else entirely.
  grep -v '^[[:space:]]*#' "$SCRIPT" | grep -qF 'yarn start'
}

@test "the watcher execs its start command instead of a bare invocation" {
  # A bare (non-exec'd) start would let a shell wrapper swallow stop signals.
  # Not a live risk today -- DDEV's stopasgroup=true masks it -- but nothing
  # else here would catch the regression if the script grows a pipeline first.
  grep -v '^[[:space:]]*#' "$SCRIPT" | grep -qE '^[[:space:]]*exec[[:space:]]+.*yarn start'
}

@test "the watcher's cd into the docroot has a failure guard" {
  grep -v '^[[:space:]]*#' "$SCRIPT" | grep -qE '^[[:space:]]*cd[[:space:]].*\|\|[[:space:]]*exit'
}

@test "the watcher stops if the dependency install fails" {
  # Without this gate a failed install falls straight through to the start
  # command, and DDEV's crash-loop retries (up to 15) re-attempt a doomed
  # start on top of it, burying the real cause in the same log stream.
  grep -v '^[[:space:]]*#' "$SCRIPT" | grep -qF 'yarn --network-concurrency 1 ||'
}

@test "the watcher exports the polling and arm64 build variables" {
  grep -q 'CHOKIDAR_USEPOLLING' "$SCRIPT"
  grep -q 'PNG_ARM_NEON_OPT=0' "$SCRIPT"
}

@test "the watcher locates the docroot from DDEV_DOCROOT" {
  grep -q 'DDEV_DOCROOT' "$SCRIPT"
}

@test "the pull provider does not carry ddev's generated marker" {
  ! grep -q '#ddev-generated' "$REPO_ROOT/providers/platform.yaml"
}

@test "the pull provider downloads one mount into DDEV's files dir" {
  grep -q 'mount=web/sites/default/files' "$REPO_ROOT/providers/platform.yaml"
  grep -q 'target="\${DDEV_FILES_DIR}"' "$REPO_ROOT/providers/platform.yaml"
  # Ignore comment lines: the file deliberately quotes the stock command it replaced,
  # so a whole-file grep would trip on our own explanatory prose. What matters is that
  # no ACTIVE command uses --all.
  ! grep -v '^[[:space:]]*#' "$REPO_ROOT/providers/platform.yaml" | grep -q 'mount:download --all'
}
