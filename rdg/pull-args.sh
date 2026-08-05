#!/usr/bin/env bash
#ddev-generated
# Shared by commands/host/upsun-db-pull and commands/host/upsun-files-pull.
# Both take the same single optional argument -- an Upsun environment name -- so
# the validation lives here rather than being copy-pasted into two files that
# would then drift.

# rdg_pull_provider <command-name> <project-root>
# Sets RDG_PULL_PROVIDER to the DDEV pull provider this repo should use.
#
# The commands are named 'upsun-*' because that is what the service is called now,
# but Upsun comes in two shapes and DDEV has a separate provider recipe for each:
#
#   Upsun Fixed (formerly Platform.sh) -- .platform/ directory, 'platform' CLI,
#     PLATFORMSH_CLI_TOKEN, 'ddev pull platform'.
#   Upsun Flex -- .upsun/ directory, 'upsun' CLI, UPSUN_CLI_TOKEN,
#     'ddev pull upsun'.
#
# The tracked project link file is what distinguishes them. Both recipes use
# PLATFORM_ENVIRONMENT for the environment, so nothing else here changes.
rdg_pull_provider() {
  local self="$1" root="$2"

  # shellcheck source=rdg/mode.sh
  source "$(dirname "${BASH_SOURCE[0]}")/mode.sh"

  # Flex is checked BEFORE the not-on-Upsun case, and the order is load-bearing: a
  # Flex repo has no .platform.app.yaml either -- its config lives in
  # .upsun/config.yaml -- so it fails the Upsun Fixed test too. Checking native
  # first would answer "not on Upsun" for a project that is very much on Upsun, and
  # send the reader to 'ddev import-db' when what they want is 'ddev pull upsun'.
  if [ -f "$root/.upsun/local/project.yaml" ]; then
    # Refuses rather than falling through to 'ddev pull upsun'. DDEV's stock
    # upsun.yaml is not the recipe this add-on vets: it does
    # 'mount:download --all --target=/var/www/html', which puts the public files
    # beside the docroot instead of inside it and drags down every other mount,
    # and it still carries db_push_command and files_push_command. Silently using
    # it would hand back a production push path that was deliberately removed.
    printf '%s: this project is linked to Upsun Flex (.upsun/local/project.yaml).\n' "$self" >&2
    printf 'ddev-rdg only ships a vetted pull recipe for Upsun Fixed, so this refuses\n' >&2
    printf "rather than fall back to DDEV's stock upsun recipe, which restores the push\n" >&2
    printf 'commands and downloads mounts to the wrong place.\n' >&2
    printf 'Use "ddev pull upsun" directly if that is what you want.\n' >&2
    return 78
  fi

  # Not on Upsun at all. Without this the command would invoke 'ddev pull platform'
  # against a provider recipe with no project to authenticate to, and the failure
  # would name the platform CLI rather than the actual problem. This is the "some
  # things are not possible in native mode" case, stated where it is hit.
  if ! rdg_is_upsun_fixed "$root"; then
    printf '%s: this project is not on Upsun, so there is nothing to pull from.\n' "$self" >&2
    printf 'Its .ddev/config.yaml is the source of truth and there is no hosted\n' >&2
    printf 'environment behind it.\n\n' >&2
    printf 'Load a database from a dump instead:\n\n' >&2
    printf '  ddev import-db --file=<dump.sql.gz>\n\n' >&2
    return 78
  fi

  RDG_PULL_PROVIDER=platform
}

# rdg_pull_parse_env <command-name> [environment]
# Sets RDG_PULL_ENV to the environment name, or to the empty string when no
# argument was given. Returns non-zero, having explained why, on bad input.
#
# Sets a global rather than echoing the flag: an echoed "--environment=..." would
# have to be word-split back apart by the caller, and an environment name is
# attacker-adjacent input (it comes from the command line, but so do typos).
# A global assigned here and appended to an array there cannot word-split at all.
rdg_pull_parse_env() {
  local self="$1"; shift
  RDG_PULL_ENV=""

  if [ "$#" -eq 0 ]; then
    return 0
  fi

  if [ "$#" -gt 1 ]; then
    printf '%s: expected at most one environment, got %d: %s\n' \
      "$self" "$#" "$*" >&2
    printf 'Usage: ddev %s [environment]\n' "$self" >&2
    return 64
  fi

  case "$1" in
    -*)
      # Deliberately no flags: the whole point of these two commands is that the
      # environment is positional. Anything else belongs on 'ddev pull platform'.
      printf '%s: unknown flag %s -- this command takes only an environment name.\n' \
        "$self" "$1" >&2
      printf 'For DDEV pull flags (--skip-import and friends) use: ddev pull platform --help\n' >&2
      return 64
      ;;
    *[,=]*)
      # ddev pull --environment takes comma-separated KEY=VALUE pairs, so a name
      # containing either character would be silently reinterpreted as more pairs.
      # DDEV's own help: "Commas and equals are not allowed in the names or values."
      printf "%s: environment name may not contain ',' or '=': %s\n" "$self" "$1" >&2
      return 64
      ;;
    "")
      printf '%s: environment name is empty.\n' "$self" >&2
      return 64
      ;;
  esac

  RDG_PULL_ENV="$1"
}
