#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/rdg/theme-watch.sh"
}

@test "the watcher never names a specific bundler" {
  ! grep -qiE 'webpack|vite' "$SCRIPT"
}

@test "the watcher runs the repo's own start script" {
  grep -q 'yarn start' "$SCRIPT"
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
