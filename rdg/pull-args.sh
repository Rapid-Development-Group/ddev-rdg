#!/usr/bin/env bash
#ddev-generated
# Shared by commands/host/platform-db-pull and commands/host/platform-files-pull.
# Both take the same single optional argument -- a Platform.sh environment name --
# so the validation lives here rather than being copy-pasted into two files that
# would then drift.

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
