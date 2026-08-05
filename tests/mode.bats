#!/usr/bin/env bats

# Coverage for rdg/mode.sh, the predicate that decides whether a repo is derived
# (Upsun Fixed, .platform.app.yaml is the source of truth) or native (not on
# Upsun, .ddev/config.yaml is). Three commands branch on it, and the guard going
# inert is the consequence, so a wrong answer here is not a cosmetic bug.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MODE="$REPO_ROOT/rdg/mode.sh"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
}

# Runs the predicate in a subshell under the same options its callers use, so a
# 'set -e' abort inside it shows up here as a failure rather than as a false
# negative. check-sync.sh and rdg-sync both run with -euo pipefail.
is_upsun() {
  run env -u RDG_APP_ROOT bash -c \
    "set -euo pipefail; source '$MODE'; rdg_is_upsun_fixed '$PROJ'"
}

@test "an app config at the repo root: derived" {
  printf 'type: "php:8.3"\n' > "$PROJ/.platform.app.yaml"
  is_upsun
  [ "$status" -eq 0 ]
}

@test "an app config one level down: derived" {
  # rdg2020's shape -- the app lives in a subdirectory, so Upsun resolves the app
  # root from wherever the file is rather than from the repo root.
  mkdir -p "$PROJ/drupal"
  printf 'type: "php:8.3"\n' > "$PROJ/drupal/.platform.app.yaml"
  is_upsun
  [ "$status" -eq 0 ]
}

@test "two app configs: derived, not ambiguous-and-therefore-native" {
  # A repo with several apps is unambiguously on Upsun. Answering native here
  # would silence the guard on a multi-app Upsun project; derive.sh raises its own
  # "set RDG_APP_ROOT to choose one" error, which is the right message for this.
  mkdir -p "$PROJ/api" "$PROJ/web"
  printf 'type: "php:8.3"\n' > "$PROJ/api/.platform.app.yaml"
  printf 'type: "php:8.3"\n' > "$PROJ/web/.platform.app.yaml"
  is_upsun
  [ "$status" -eq 0 ]
}

@test "no app config anywhere: native" {
  printf 'name: proj\n' > "$PROJ/composer.json"
  is_upsun
  [ "$status" -ne 0 ]
}

@test "an app config three levels down does not count" {
  # Mirrors derive.sh's -maxdepth 2 exactly. If this ever changes, it must change
  # in both places -- which is what the drift test at the bottom enforces.
  mkdir -p "$PROJ/a/b"
  printf 'type: "php:8.3"\n' > "$PROJ/a/b/.platform.app.yaml"
  is_upsun
  [ "$status" -ne 0 ]
}

@test "an Upsun Flex repo is native as far as this predicate is concerned" {
  # Flex config lives in .upsun/config.yaml, so there is no .platform.app.yaml to
  # find. The predicate says native; rdg/pull-args.sh checks Flex FIRST precisely
  # because of this, so a Flex user gets the Flex message and not "not on Upsun".
  mkdir -p "$PROJ/.upsun/local"
  printf 'id: abc123\n' > "$PROJ/.upsun/local/project.yaml"
  printf 'applications:\n  app:\n    type: "php:8.3"\n' > "$PROJ/.upsun/config.yaml"
  is_upsun
  [ "$status" -ne 0 ]
}

@test ".ddev/rdg-native forces native even with an app config present" {
  # Vestigial Upsun config is real in this fleet: several repos carry a
  # .platform.app.yaml from an abandoned Platform.sh evaluation and deploy to AWS
  # instead. Without the marker they land in derived mode, where the guard aborts every
  # start until someone runs 'ddev rdg-sync', which then derives runtime versions from a
  # file nobody deploys from.
  printf 'type: "php:8.3"\n' > "$PROJ/.platform.app.yaml"
  mkdir -p "$PROJ/.ddev"
  : > "$PROJ/.ddev/rdg-native"
  is_upsun
  [ "$status" -ne 0 ]
}

@test ".ddev/rdg-native beats RDG_APP_ROOT, which is only a per-shell override" {
  # The marker is committed and describes the repo; the variable is an environment
  # override for one command. If they disagree, the repo wins -- otherwise a stray
  # export in someone's shell silently re-enables derivation on a native repo.
  printf 'type: "php:8.3"\n' > "$PROJ/.platform.app.yaml"
  mkdir -p "$PROJ/.ddev"
  : > "$PROJ/.ddev/rdg-native"
  run env RDG_APP_ROOT=. bash -c \
    "set -euo pipefail; source '$MODE'; rdg_is_upsun_fixed '$PROJ'"
  [ "$status" -ne 0 ]
}

@test "RDG_APP_ROOT forces derived even when it points at nothing" {
  # The variable is an explicit claim that this repo is on Upsun. Answering native
  # on a typo would turn that typo into a quietly inert guard; derive.sh instead
  # gets to say "RDG_APP_ROOT=... but ... does not exist".
  run env RDG_APP_ROOT=nope bash -c \
    "set -euo pipefail; source '$MODE'; rdg_is_upsun_fixed '$PROJ'"
  [ "$status" -eq 0 ]
}

@test "a trailing slash on the project root is handled" {
  printf 'type: "php:8.3"\n' > "$PROJ/.platform.app.yaml"
  run env -u RDG_APP_ROOT bash -c \
    "set -euo pipefail; source '$MODE'; rdg_is_upsun_fixed '$PROJ/'"
  [ "$status" -eq 0 ]
}

# --- the drift guard ----------------------------------------------------------

@test "the predicate and derive.sh never disagree about a fixture" {
  # mode.sh deliberately reimplements derive.sh's app-config search rather than
  # sharing code with it: derive.sh runs in the container and needs the resolved
  # path, this runs on the host and needs a yes/no. That duplication is only safe
  # while the two agree, and a disagreement in the direction that matters -- mode
  # says native, derive says found -- is an inert guard on a live Upsun project,
  # the exact silent drift the guard exists to catch. So it is asserted, per
  # fixture, rather than trusted.
  local fixture name mode_says derive_says failed=""
  for fixture in "$REPO_ROOT"/tests/fixtures/*/; do
    [ -d "$fixture" ] || continue
    name="$(basename "$fixture")"

    if env -u RDG_APP_ROOT bash -c \
        "set -euo pipefail; source '$MODE'; rdg_is_upsun_fixed '${fixture%/}'"; then
      mode_says=derived
    else
      mode_says=native
    fi

    # derive.sh exits non-zero only when it cannot locate an app config; every
    # other path warns on stderr and still emits config. So its exit status is
    # exactly "did I find one".
    if env -u RDG_APP_ROOT bash "$REPO_ROOT/rdg/derive.sh" "${fixture%/}" \
        >/dev/null 2>&1; then
      derive_says=derived
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

@test "every fixture is an Upsun one, so the drift test above is not vacuous" {
  # If the fixtures ever became all-native, the drift test would pass by agreeing
  # on 'native' everywhere and would stop checking the interesting direction.
  local fixture count=0
  for fixture in "$REPO_ROOT"/tests/fixtures/*/; do
    [ -d "$fixture" ] || continue
    if env -u RDG_APP_ROOT bash -c \
        "set -euo pipefail; source '$MODE'; rdg_is_upsun_fixed '${fixture%/}'"; then
      count=$((count + 1))
    fi
  done
  [ "$count" -ge 4 ] || { echo "only $count derived fixtures"; return 1; }
}
