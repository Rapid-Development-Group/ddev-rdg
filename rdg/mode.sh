#!/usr/bin/env bash
#ddev-generated
# Which shape is this project?
#
#   fixed   -- Upsun Fixed, the rebranded Platform.sh. '.platform.app.yaml' plus
#              '.platform/services.yaml' are the source of truth, 'ddev rdg-sync'
#              generates config.platformsh.yaml from them, and the pre-start
#              guard keeps the two in step. Pulls use the 'platform' provider.
#   flex    -- Upsun Flex. One '.upsun/config.yaml' with top-level
#              'applications:' / 'services:' / 'routes:' is the source of truth,
#              'ddev rdg-sync' generates config.upsun.yaml from it. Pulls use the
#              'upsun' provider.
#   native  -- not on Upsun at all. '.ddev/config.yaml' is the source of truth,
#              hand-written; nothing is derived and nothing can be pulled.
#
# Sourced by check-sync.sh, commands/host/rdg-sync and rdg/pull-args.sh -- all of
# which run on the HOST, so this uses only 'find' and '[ -f ]'. No yq: end users
# are guaranteed to need no tooling on the host, and the guard has to work while
# the project is stopped.

# rdg_mode <project-root>
# Prints 'fixed', 'flex' or 'native'. Always exits 0 -- callers branch on the
# value, not the status, because a function that returns non-zero from inside a
# command substitution under 'set -e' aborts the caller.
#
# The search for a Fixed app config mirrors rdg/derive.sh deliberately, rather
# than sharing code with it: derive.sh runs in the web container and needs the
# resolved path plus its own two error messages, while this needs a one-word
# answer on the host. tests/mode.bats asserts the two never disagree, because a
# disagreement is the one genuinely bad outcome -- an inert guard on a live Upsun
# project, which is exactly the silent drift the guard exists to catch.
rdg_mode() {
  local root="${1%/}"

  # An explicit, committed statement that this repo is NOT on Upsun. It beats
  # every signal below, RDG_APP_ROOT included: that is a per-shell override, this
  # is a property of the repo, checked in.
  #
  # It exists because file presence cannot tell "config we deploy from" apart
  # from "config somebody left behind". Several repos in the fleet carry a
  # .platform.app.yaml from an abandoned Platform.sh evaluation and actually
  # deploy to AWS -- devops/buildspec.yml, and no .platform/local/project.yaml, so
  # the repo was never even linked to a project. Without this marker they land in
  # a derived mode, where the pre-start guard aborts every start until someone
  # runs 'ddev rdg-sync', which then derives PHP and database versions from a file
  # nobody deploys from. A wrong answer delivered confidently, which is worse than
  # no answer.
  #
  # Deliberately a file rather than a config key: the guard runs on the host while
  # the project is stopped, so it cannot read web_environment, and '[ -f ]' needs
  # no yq.
  if [ -f "$root/.ddev/rdg-native" ]; then
    printf 'native\n'
    return 0
  fi

  # Flex is checked before EVERY Fixed signal, and the order is load-bearing.
  # 'upsun convert' rewrites the tracked config and deletes .platform.app.yaml
  # and .platform/services.yaml -- but nothing cleans up what was never tracked,
  # so a converted repo keeps .platform/local/project.yaml naming the
  # pre-conversion project, and a repo converted on a branch has the old files
  # back the moment anyone checks out master. Whenever both shapes are present
  # the Flex config is the one being deployed from; preferring the Fixed
  # leftovers would derive runtime and database versions from dead config and
  # point pulls at a dead project id.
  #
  # The TRACKED config file, not .upsun/local/project.yaml: that link file is
  # gitignored, so it does not exist on a fresh clone, and keying on it would
  # report a Flex repo as native for everyone who had not yet linked the project.
  if [ -f "$root/.upsun/config.yaml" ]; then
    printf 'flex\n'
    return 0
  fi

  if [ -n "${RDG_APP_ROOT:-}" ]; then
    # Honoured even when it points at nothing: RDG_APP_ROOT is an explicit claim
    # that this repo is Upsun Fixed, so the answer is yes and derive.sh gets to
    # say "RDG_APP_ROOT=... but ... does not exist". Answering "native" here would
    # turn a typo in that variable into a quietly inert guard.
    printf 'fixed\n'
    return 0
  fi

  if [ -f "$root/.platform.app.yaml" ]; then
    printf 'fixed\n'
    return 0
  fi

  # Two or more candidates counts as fixed. A repo with several app configs is
  # unambiguously Upsun; derive.sh then raises its own "set RDG_APP_ROOT" error,
  # which is the right message for that case and not this function's job.
  #
  # No pipe to 'grep -q': grep exits on its first match, which SIGPIPEs find, and
  # under 'set -o pipefail' that 141 becomes the pipeline's status -- so a repo
  # that HAS an app config would report as not having one. Command substitution
  # has no such race. (Same defect class as runtime_version in rdg/derive.sh.)
  local found
  found="$(find "$root" -mindepth 2 -maxdepth 2 -name .platform.app.yaml 2>/dev/null)"
  if [ -n "$found" ]; then
    printf 'fixed\n'
    return 0
  fi

  printf 'native\n'
}

# rdg_derived_config <mode>
# The basename of the file 'ddev rdg-sync' generates in that mode, relative to
# .ddev/. Prints nothing for native.
#
# Two filenames rather than one because they are derived from different files and
# a repo can hold both: a Fixed-to-Flex conversion leaves the committed
# config.platformsh.yaml behind, and DDEV merges every .ddev/config.*.yaml it
# finds. rdg-sync deletes the other one and the guard refuses while both survive;
# this function is the single place that says which is which.
rdg_derived_config() {
  case "$1" in
    fixed) printf 'config.platformsh.yaml\n' ;;
    flex)  printf 'config.upsun.yaml\n' ;;
  esac
}

# rdg_is_upsun_fixed <project-root>
# True when the repo is Upsun Fixed specifically.
rdg_is_upsun_fixed() {
  [ "$(rdg_mode "$1")" = fixed ]
}

# rdg_is_upsun <project-root>
# True when the repo is on Upsun in either shape, i.e. something is derivable.
rdg_is_upsun() {
  [ "$(rdg_mode "$1")" != native ]
}
