#!/usr/bin/env bash
#ddev-generated
# Which mode is this project in?
#
#   derived  -- the repo is an Upsun Fixed project. '.platform.app.yaml' is the
#               source of truth, 'ddev rdg-sync' generates config.platformsh.yaml
#               from it, and the pre-start guard keeps the two in step.
#   native   -- the repo is not on Upsun. '.ddev/config.yaml' is the source of
#               truth, hand-written; nothing is derived and nothing can be pulled.
#
# Sourced by check-sync.sh, commands/host/rdg-sync and rdg/pull-args.sh -- all of
# which run on the HOST, so this uses only 'find' and '[ -f ]'. No yq: end users
# are guaranteed to need no tooling on the host, and the guard has to work while
# the project is stopped.

# rdg_is_upsun_fixed <project-root>
# True when the repo has an Upsun Fixed app config.
#
# Mirrors the search in rdg/derive.sh deliberately, rather than sharing code with
# it: derive.sh runs in the web container and needs the resolved path plus its own
# two error messages, while this needs a yes/no on the host. tests/mode.bats
# asserts the two never disagree, because a disagreement is the one genuinely bad
# outcome -- an inert guard on a live Upsun project, which is exactly the silent
# drift the guard exists to catch.
#
# Two or more candidates counts as TRUE. A repo with several app configs is
# unambiguously Upsun; derive.sh then raises its own "set RDG_APP_ROOT" error,
# which is the right message for that case and not this function's job.
rdg_is_upsun_fixed() {
  local root="${1%/}"

  # An explicit, committed statement that this repo is NOT on Upsun. It beats every
  # signal below, RDG_APP_ROOT included: that is a per-shell override, this is a
  # property of the repo, checked in.
  #
  # It exists because file presence cannot tell "config we deploy from" apart from
  # "config somebody left behind". Several repos in the fleet carry a
  # .platform.app.yaml from an abandoned Platform.sh evaluation and actually deploy to
  # AWS -- devops/buildspec.yml, and no .platform/local/project.yaml, so the repo was
  # never even linked to a project. Without this marker they land in derived mode,
  # where the pre-start guard aborts every start until someone runs 'ddev rdg-sync',
  # which then derives PHP and database versions from a file nobody deploys from. A
  # wrong answer delivered confidently, which is worse than no answer.
  #
  # Deliberately a file rather than a config key: the guard runs on the host while the
  # project is stopped, so it cannot read web_environment, and '[ -f ]' needs no yq.
  [ -f "$root/.ddev/rdg-native" ] && return 1

  if [ -n "${RDG_APP_ROOT:-}" ]; then
    # Honoured even when it points at nothing: RDG_APP_ROOT is an explicit claim
    # that this repo is on Upsun, so the answer is yes and derive.sh gets to say
    # "RDG_APP_ROOT=... but ... does not exist". Answering "native" here would
    # turn a typo in that variable into a quietly inert guard.
    return 0
  fi

  [ -f "$root/.platform.app.yaml" ] && return 0

  # No pipe to 'grep -q': grep exits on its first match, which SIGPIPEs find, and
  # under 'set -o pipefail' that 141 becomes the pipeline's status -- so a repo
  # that HAS an app config would report as not having one. Command substitution
  # has no such race. (Same defect class as runtime_version in rdg/derive.sh.)
  local found
  found="$(find "$root" -mindepth 2 -maxdepth 2 -name .platform.app.yaml 2>/dev/null)"
  [ -n "$found" ]
}
