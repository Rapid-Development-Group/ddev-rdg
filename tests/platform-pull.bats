#!/usr/bin/env bats

# Coverage for commands/host/platform-db-pull and commands/host/platform-files-pull.
# Neither needs a running project: each one's entire job is to build an argv and
# hand it to 'ddev pull platform', so a stub ddev on PATH that records what it was
# called with turns the real contract -- the exact command line -- into an assertion.
#
# Every behavioural test runs against BOTH commands. They are near-identical files
# differing by one flag, which is precisely the shape that drifts.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROJ="$BATS_TEST_TMPDIR/proj"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  ARGV="$BATS_TEST_TMPDIR/argv"

  mkdir -p "$PROJ/.ddev/rdg" "$STUB_BIN"
  cp "$REPO_ROOT/rdg/pull-args.sh" "$PROJ/.ddev/rdg/"

  # Records argv one element per line, so an assertion can match a whole argument
  # exactly (grep -x) rather than as a substring of the joined string.
  cat > "$STUB_BIN/ddev" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$RDG_TEST_ARGV"
STUB
  chmod +x "$STUB_BIN/ddev"
}

# pull_run <command-name> [args...]
pull_run() {
  local cmd="$1"; shift
  rm -f "$ARGV"
  run env PATH="$STUB_BIN:$PATH" DDEV_APPROOT="$PROJ" RDG_TEST_ARGV="$ARGV" \
    bash "$REPO_ROOT/commands/host/$cmd" "$@"
}

# '--' is load-bearing: every argument being asserted starts with '-', and without
# it grep parses '--skip-files' and '-y' as its own options. '-y' is even a valid
# BSD grep flag, so the -y assertion silently passed for the wrong reason.
argv_has() { grep -qxF -e "$1" "$ARGV"; }
argv_lacks() { ! grep -qxF -e "$1" "$ARGV"; }

# The commands under test, with the flag each must pass and the flag each must
# never pass. Kept as one list so a new sibling command cannot skip the matrix.
BOTH="platform-db-pull:--skip-files:--skip-db platform-files-pull:--skip-db:--skip-files"

# --- the argv each command builds --------------------------------------------

@test "no argument: pulls with the right skip flag and no --environment at all" {
  # No --environment means the environment pinned in the project's own config.yaml
  # applies. A hardcoded 'master' here would be wrong for every repo in the fleet
  # that pins something else.
  local spec cmd mine
  for spec in $BOTH; do
    IFS=: read -r cmd mine _ <<< "$spec"
    pull_run "$cmd"
    [ "$status" -eq 0 ] || { echo "$cmd: $output"; return 1; }
    argv_has pull
    argv_has platform
    argv_has "$mine"
    # '!' rather than 'grep && fail': bats runs tests under set -e, so a failing
    # grep in a non-final && list would abort the test as an error.
    ! grep -q -- '--environment' "$ARGV"
  done
}

@test "an environment argument becomes exactly one --environment=PLATFORM_ENVIRONMENT pair" {
  local spec cmd
  for spec in $BOTH; do
    IFS=: read -r cmd _ _ <<< "$spec"
    pull_run "$cmd" staging
    [ "$status" -eq 0 ] || { echo "$cmd: $output"; return 1; }
    argv_has '--environment=PLATFORM_ENVIRONMENT=staging'
    [ "$(grep -c -e "--environment" "$ARGV")" -eq 1 ]
  done
}

@test "neither command passes -y: the confirmation prompt is deliberate" {
  # The prompt is what shows which environment is about to overwrite local data,
  # and choosing the environment is the whole point of these commands. Losing this
  # would be invisible in normal use, so it is asserted rather than commented.
  local spec cmd
  for spec in $BOTH; do
    IFS=: read -r cmd _ _ <<< "$spec"
    pull_run "$cmd" staging
    [ "$status" -eq 0 ]
    argv_lacks '-y'
    argv_lacks '--skip-confirmation'
  done
}

@test "each command passes only its own skip flag, never the other one" {
  # The copy-paste failure these two files invite: platform-db-pull skipping the db.
  local spec cmd mine theirs
  for spec in $BOTH; do
    IFS=: read -r cmd mine theirs <<< "$spec"
    pull_run "$cmd" staging
    [ "$status" -eq 0 ]
    argv_has "$mine"
    argv_lacks "$theirs"
  done
}

@test "an environment name containing a slash survives unmangled" {
  # Platform.sh environment names mirror branch names, so 'feature/x' is ordinary.
  local spec cmd
  for spec in $BOTH; do
    IFS=: read -r cmd _ _ <<< "$spec"
    pull_run "$cmd" feature/x
    [ "$status" -eq 0 ]
    argv_has '--environment=PLATFORM_ENVIRONMENT=feature/x'
  done
}

@test "never builds a push: the provider ships no push commands on purpose" {
  # These wrappers must not be what reintroduces a production-overwriting path.
  local spec cmd
  for spec in $BOTH; do
    IFS=: read -r cmd _ _ <<< "$spec"
    pull_run "$cmd" staging
    argv_lacks 'push'
  done
}

# --- rejected input ----------------------------------------------------------
#
# Each of these must fail AND make no ddev call: a rejection that still pulled
# would be worse than no validation at all.

assert_rejected() {
  local cmd="$1"; shift
  pull_run "$cmd" "$@"
  [ "$status" -ne 0 ] || { echo "$cmd $*: expected failure, got 0"; return 1; }
  [ ! -f "$ARGV" ] || { echo "$cmd $*: called ddev anyway: $(cat "$ARGV")"; return 1; }
}

@test "rejects an environment name containing '=' or ','" {
  # ddev pull --environment takes comma-separated KEY=VALUE pairs, so either
  # character would be reinterpreted as further pairs rather than failing.
  local spec cmd
  for spec in $BOTH; do
    IFS=: read -r cmd _ _ <<< "$spec"
    assert_rejected "$cmd" 'PLATFORM_ENVIRONMENT=staging'
    printf '%s' "$output" | grep -qF "may not contain"
    assert_rejected "$cmd" 'staging,master'
  done
}

@test "rejects a second positional argument" {
  local spec cmd
  for spec in $BOTH; do
    IFS=: read -r cmd _ _ <<< "$spec"
    assert_rejected "$cmd" staging master
    printf '%s' "$output" | grep -qF 'at most one environment'
  done
}

@test "rejects any flag, naming it" {
  local spec cmd
  for spec in $BOTH; do
    IFS=: read -r cmd _ _ <<< "$spec"
    assert_rejected "$cmd" --skip-import
    printf '%s' "$output" | grep -qF 'unknown flag --skip-import'
    assert_rejected "$cmd" -y
  done
}

@test "rejects an empty environment argument" {
  # 'ddev platform-db-pull ""' would otherwise pass --environment=PLATFORM_ENVIRONMENT=
  # and pull from whatever the provider then derives.
  local spec cmd
  for spec in $BOTH; do
    IFS=: read -r cmd _ _ <<< "$spec"
    assert_rejected "$cmd" ''
  done
}

@test "fails loudly when DDEV_APPROOT is unset instead of sourcing nothing" {
  local spec cmd
  for spec in $BOTH; do
    IFS=: read -r cmd _ _ <<< "$spec"
    rm -f "$ARGV"
    run env -u DDEV_APPROOT PATH="$STUB_BIN:$PATH" RDG_TEST_ARGV="$ARGV" \
      bash "$REPO_ROOT/commands/host/$cmd" staging
    [ "$status" -ne 0 ]
    printf '%s' "$output" | grep -qF 'must be run through ddev'
    [ ! -f "$ARGV" ]
  done
}

# --- the annotation header DDEV parses ---------------------------------------

@test "both commands carry the marker and the annotations ddev needs" {
  # Without ## Description DDEV still registers the command but shows it unlabelled
  # in 'ddev -h'; without #ddev-generated it silently overwrites the file on start.
  local spec cmd f
  for spec in $BOTH; do
    IFS=: read -r cmd _ _ <<< "$spec"
    f="$REPO_ROOT/commands/host/$cmd"
    grep -qF '#ddev-generated' "$f"
    grep -q "^## Description: " "$f"
    grep -qF "## Usage: $cmd [environment]" "$f"
    grep -q "^## Example: " "$f"
    # No ## Flags: -- neither command takes any, and declaring an empty set would
    # imply otherwise.
    ! grep -q '^## Flags:' "$f"
  done
}
