#!/usr/bin/env bats

# Coverage for rdg/mode.sh, which decides which of three shapes a repo is:
#
#   fixed   Upsun Fixed -- .platform.app.yaml + .platform/services.yaml
#   flex    Upsun Flex  -- .upsun/config.yaml
#   native  not on Upsun -- .ddev/config.yaml, hand-written
#
# Four commands branch on it, and the guard going inert is the consequence, so a
# wrong answer here is not a cosmetic bug.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MODE="$REPO_ROOT/rdg/mode.sh"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
}

# Runs the function in a subshell under the same options its callers use, so a
# 'set -e' abort inside it shows up here as a failure rather than as a false
# negative. check-sync.sh and rdg-sync both run with -euo pipefail.
mode_of() {
  run env -u RDG_APP_ROOT bash -c \
    "set -euo pipefail; source '$MODE'; rdg_mode '${1:-$PROJ}'"
}

# The fixtures below are written inline rather than added to tests/fixtures/,
# because everything in that directory is also swept by the golden-output and
# drift loops, where an intentionally broken repo would be noise.
make_fixed() {
  printf 'type: "php:8.3"\n' > "$PROJ/.platform.app.yaml"
}

make_flex() {
  mkdir -p "$PROJ/.upsun"
  printf 'applications:\n  app:\n    type: "composable:26.05"\n' > "$PROJ/.upsun/config.yaml"
}

# --- Upsun Fixed --------------------------------------------------------------

@test "an app config at the repo root: fixed" {
  make_fixed
  mode_of
  [ "$output" = fixed ]
}

@test "an app config one level down: fixed" {
  # rdg2020's shape -- the app lives in a subdirectory, so Upsun resolves the app
  # root from wherever the file is rather than from the repo root.
  mkdir -p "$PROJ/drupal"
  printf 'type: "php:8.3"\n' > "$PROJ/drupal/.platform.app.yaml"
  mode_of
  [ "$output" = fixed ]
}

@test "two app configs: fixed, not ambiguous-and-therefore-native" {
  # A repo with several apps is unambiguously on Upsun. Answering native here
  # would silence the guard on a multi-app Upsun project; derive.sh raises its own
  # "set RDG_APP_ROOT to choose one" error, which is the right message for this.
  mkdir -p "$PROJ/api" "$PROJ/web"
  printf 'type: "php:8.3"\n' > "$PROJ/api/.platform.app.yaml"
  printf 'type: "php:8.3"\n' > "$PROJ/web/.platform.app.yaml"
  mode_of
  [ "$output" = fixed ]
}

@test "an app config three levels down does not count" {
  # Mirrors derive.sh's -maxdepth 2 exactly. If this ever changes, it must change
  # in both places -- which is what the drift test at the bottom enforces.
  mkdir -p "$PROJ/a/b"
  printf 'type: "php:8.3"\n' > "$PROJ/a/b/.platform.app.yaml"
  mode_of
  [ "$output" = native ]
}

# --- Upsun Flex ---------------------------------------------------------------

@test "a .upsun/config.yaml: flex" {
  make_flex
  mode_of
  [ "$output" = flex ]
}

@test "flex is decided by the tracked config, not by the gitignored link file" {
  # .upsun/local/ is gitignored, so a fresh clone has no project.yaml. Keying on
  # it -- which rdg/pull-args.sh used to do -- reports a very-much-hosted project
  # as native and sends the reader to 'ddev import-db'.
  make_flex
  [ ! -e "$PROJ/.upsun/local/project.yaml" ]
  mode_of
  [ "$output" = flex ]
}

# --- Fixed leftovers on a converted repo --------------------------------------

@test "flex beats a leftover .platform.app.yaml" {
  # 'upsun convert' deletes the tracked Fixed files, but a repo converted on a
  # branch has them back the moment anyone checks out master, and a half-finished
  # conversion has both. The Flex config is the one being deployed from.
  make_fixed
  make_flex
  mode_of
  [ "$output" = flex ]
}

@test "flex beats a leftover .platform/ directory, link file and all" {
  # This is the real shape of stockmarketmedia after 'upsun convert':
  # .platform/local/project.yaml is untracked, so nothing removed it, and it still
  # names the pre-conversion Platform.sh project. A tool that reads it pulls from
  # a dead project id.
  make_flex
  mkdir -p "$PROJ/.platform/local"
  printf 'id: deadproject\nhost: api.platform.sh\n' > "$PROJ/.platform/local/project.yaml"
  printf 'olddb:\n  type: mariadb:10.6\n' > "$PROJ/.platform/services.yaml"
  mode_of
  [ "$output" = flex ]
}

@test "flex beats RDG_APP_ROOT, which only ever meant Upsun Fixed" {
  make_flex
  run env RDG_APP_ROOT=drupal bash -c \
    "set -euo pipefail; source '$MODE'; rdg_mode '$PROJ'"
  [ "$output" = flex ]
}

# --- native -------------------------------------------------------------------

@test "no hosting config anywhere: native" {
  printf 'name: proj\n' > "$PROJ/composer.json"
  mode_of
  [ "$output" = native ]
}

@test ".ddev/rdg-native forces native even with an app config present" {
  # Vestigial Upsun config is real in this fleet: several repos carry a
  # .platform.app.yaml from an abandoned Platform.sh evaluation and deploy to AWS
  # instead. Without the marker they land in a derived mode, where the guard aborts
  # every start until someone runs 'ddev rdg-sync', which then derives runtime
  # versions from a file nobody deploys from.
  make_fixed
  mkdir -p "$PROJ/.ddev"
  : > "$PROJ/.ddev/rdg-native"
  mode_of
  [ "$output" = native ]
}

@test ".ddev/rdg-native forces native on a Flex repo too" {
  make_flex
  mkdir -p "$PROJ/.ddev"
  : > "$PROJ/.ddev/rdg-native"
  mode_of
  [ "$output" = native ]
}

@test ".ddev/rdg-native beats RDG_APP_ROOT, which is only a per-shell override" {
  # The marker is committed and describes the repo; the variable is an environment
  # override for one command. If they disagree, the repo wins -- otherwise a stray
  # export in someone's shell silently re-enables derivation on a native repo.
  make_fixed
  mkdir -p "$PROJ/.ddev"
  : > "$PROJ/.ddev/rdg-native"
  run env RDG_APP_ROOT=. bash -c \
    "set -euo pipefail; source '$MODE'; rdg_mode '$PROJ'"
  [ "$output" = native ]
}

@test "RDG_APP_ROOT forces fixed even when it points at nothing" {
  # The variable is an explicit claim that this repo is Upsun Fixed. Answering
  # native on a typo would turn that typo into a quietly inert guard; derive.sh
  # instead gets to say "RDG_APP_ROOT=... but ... does not exist".
  run env RDG_APP_ROOT=nope bash -c \
    "set -euo pipefail; source '$MODE'; rdg_mode '$PROJ'"
  [ "$output" = fixed ]
}

@test "a trailing slash on the project root is handled" {
  make_fixed
  run env -u RDG_APP_ROOT bash -c \
    "set -euo pipefail; source '$MODE'; rdg_mode '$PROJ/'"
  [ "$output" = fixed ]
}

# --- the derived-config filename ----------------------------------------------

@test "each shape names its own generated file, and native names none" {
  run bash -c "source '$MODE'; rdg_derived_config fixed"
  [ "$output" = config.platformsh.yaml ]
  run bash -c "source '$MODE'; rdg_derived_config flex"
  [ "$output" = config.upsun.yaml ]
  run bash -c "source '$MODE'; rdg_derived_config native"
  [ -z "$output" ]
}

@test "the two names differ, which is the whole point of having two" {
  # If they ever collapsed to one name, a Fixed-to-Flex conversion would silently
  # overwrite rather than leave a leftover -- and check-sync.sh's both-present
  # guard, plus rdg-sync's cleanup, would be dead code nobody noticed.
  local a b
  a="$(bash -c "source '$MODE'; rdg_derived_config fixed")"
  b="$(bash -c "source '$MODE'; rdg_derived_config flex")"
  [ "$a" != "$b" ]
}

# --- the predicates -----------------------------------------------------------

@test "rdg_is_upsun_fixed is true for fixed only" {
  make_fixed
  env -u RDG_APP_ROOT bash -c "set -euo pipefail; source '$MODE'; rdg_is_upsun_fixed '$PROJ'"
  rm "$PROJ/.platform.app.yaml"
  make_flex
  ! env -u RDG_APP_ROOT bash -c "set -euo pipefail; source '$MODE'; rdg_is_upsun_fixed '$PROJ'"
}

@test "rdg_is_upsun is true for both Upsun shapes and false for native" {
  make_fixed
  env -u RDG_APP_ROOT bash -c "set -euo pipefail; source '$MODE'; rdg_is_upsun '$PROJ'"
  rm "$PROJ/.platform.app.yaml"
  make_flex
  env -u RDG_APP_ROOT bash -c "set -euo pipefail; source '$MODE'; rdg_is_upsun '$PROJ'"
  rm "$PROJ/.upsun/config.yaml"
  ! env -u RDG_APP_ROOT bash -c "set -euo pipefail; source '$MODE'; rdg_is_upsun '$PROJ'"
}

# --- the drift guard ----------------------------------------------------------

@test "the mode and derive.sh never disagree about a fixture" {
  # mode.sh deliberately reimplements derive.sh's config search rather than
  # sharing code with it: derive.sh runs in the container and needs the resolved
  # path, this runs on the host and needs a one-word answer. That duplication is
  # only safe while the two agree, and a disagreement in the direction that matters
  # -- mode says native, derive says found -- is an inert guard on a live Upsun
  # project, the exact silent drift the guard exists to catch. So it is asserted,
  # per fixture, rather than trusted.
  local fixture name mode_says derive_says failed=""
  for fixture in "$REPO_ROOT"/tests/fixtures/*/; do
    [ -d "$fixture" ] || continue
    name="$(basename "$fixture")"

    if env -u RDG_APP_ROOT bash -c \
        "set -euo pipefail; source '$MODE'; rdg_is_upsun '${fixture%/}'"; then
      mode_says=derivable
    else
      mode_says=native
    fi

    # derive.sh exits non-zero only when it cannot locate a config to derive from;
    # every other path warns on stderr and still emits config. So its exit status
    # is exactly "did I find one". (No fixture here is multi-app, which is the one
    # other way it exits non-zero -- tests/derive.bats covers that inline.)
    if env -u RDG_APP_ROOT bash "$REPO_ROOT/rdg/derive.sh" "${fixture%/}" \
        >/dev/null 2>&1; then
      derive_says=derivable
    else
      derive_says=native
    fi

    if [ "$mode_says" != "$derive_says" ]; then
      failed="$failed
  $name: mode.sh says $mode_says, derive.sh says $derive_says"
    fi
  done

  [ -z "$failed" ] || { echo "$failed"; return 1; }
}

@test "the fixtures cover both Upsun shapes, so the drift test is not vacuous" {
  # If the fixtures ever became all-native the drift test would pass by agreeing on
  # 'native' everywhere and stop checking the interesting direction. Counting each
  # shape separately also means deleting every Flex fixture cannot go unnoticed.
  local fixture fixed=0 flex=0 mode
  for fixture in "$REPO_ROOT"/tests/fixtures/*/; do
    [ -d "$fixture" ] || continue
    mode="$(env -u RDG_APP_ROOT bash -c \
      "set -euo pipefail; source '$MODE'; rdg_mode '${fixture%/}'")"
    case "$mode" in
      fixed) fixed=$((fixed + 1)) ;;
      flex)  flex=$((flex + 1)) ;;
    esac
  done
  [ "$fixed" -ge 4 ] || { echo "only $fixed fixed fixtures"; return 1; }
  [ "$flex" -ge 2 ]  || { echo "only $flex flex fixtures"; return 1; }
}
