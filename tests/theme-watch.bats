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
  # Every assertion here is scoped to ACTIVE (non-comment) lines. The file
  # deliberately quotes the stock command it replaced, so a whole-file grep would
  # be satisfied by our own explanatory prose -- and, before the push commands were
  # removed, was also satisfied by files_push_command's identical --mount= flag, so
  # deleting the flag from the live files_import_command passed.
  local active
  active="$(grep -v '^[[:space:]]*#' "$REPO_ROOT/providers/platform.yaml")"
  printf '%s\n' "$active" | grep -q 'mount:download .*--mount=web/sites/default/files'
  printf '%s\n' "$active" | grep -q 'mount:download .*--target="\${DDEV_FILES_DIR}"'
  if printf '%s\n' "$active" | grep -q 'mount:download --all'; then false; fi
}

@test "the pull provider ships no push commands" {
  # PLATFORM_ENVIRONMENT is pinned across the fleet so that 'ddev pull' reaches the
  # right environment. That pin turns DDEV's stock push (which derives the
  # environment from the git branch, and so fails safe) into one that targets
  # production, so 'ddev push' typed in place of 'ddev pull' would overwrite the
  # production database and upload local files over production's.
  local file="$REPO_ROOT/providers/platform.yaml"
  [ "$(yq -r 'has("db_push_command")' "$file")" = "false" ]
  [ "$(yq -r 'has("files_push_command")' "$file")" = "false" ]
  # And no active line uploads anything, however it might be spelled.
  if grep -v '^[[:space:]]*#' "$file" | grep -q 'mount:upload'; then false; fi
  if grep -v '^[[:space:]]*#' "$file" | grep -q 'db:sql'; then false; fi
}

@test "the pull provider still ships the pull half" {
  local file="$REPO_ROOT/providers/platform.yaml"
  [ "$(yq -r 'has("info_command")' "$file")" = "true" ]
  [ "$(yq -r 'has("auth_command")' "$file")" = "true" ]
  [ "$(yq -r 'has("db_pull_command")' "$file")" = "true" ]
  [ "$(yq -r 'has("files_import_command")' "$file")" = "true" ]
}
