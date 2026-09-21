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
#   Upsun Flex -- .upsun/config.yaml, 'upsun' CLI, UPSUN_CLI_TOKEN,
#     'ddev pull upsun'.
#
# Both recipes read the environment from PLATFORM_ENVIRONMENT, so nothing else
# here changes between them.
#
# The decision comes from rdg_mode, i.e. from the TRACKED hosting config -- not
# from .upsun/local/project.yaml or .platform/local/project.yaml. Those link files
# are gitignored, so:
#
#   - a fresh clone of a Flex repo has no .upsun/local/project.yaml at all, and
#     keying on it reported a very-much-hosted project as "not on Upsun", sending
#     the reader to 'ddev import-db';
#   - a repo that 'upsun convert' moved from Fixed to Flex KEEPS its old
#     .platform/local/project.yaml, naming the dead pre-conversion project, so a
#     link-file-driven answer can point a Flex pull at the Fixed provider and a
#     project id that no longer exists.
#
# .upsun/config.yaml is committed and is the file being deployed from.
rdg_pull_provider() {
  local self="$1" root="$2"

  # shellcheck source=rdg/mode.sh
  source "$(dirname "${BASH_SOURCE[0]}")/mode.sh"

  local mode
  mode="$(rdg_mode "$root")"

  case "$mode" in
    flex)
      # ddev-rdg ships its own providers/upsun.yaml rather than letting DDEV's
      # stock recipe be used: that one does
      # 'mount:download --all --target=/var/www/html', which puts the public
      # files beside the docroot instead of inside it and drags down every other
      # mount, and it still carries db_push_command and files_push_command. Ours
      # downloads one mount and has no push path. See providers/upsun.yaml.
      RDG_PULL_PROVIDER=upsun
      return 0
      ;;
    fixed)
      RDG_PULL_PROVIDER=platform
      return 0
      ;;
  esac

  # Not on Upsun at all. Without this the command would invoke a pull against a
  # provider recipe with no project to authenticate to, and the failure would name
  # the CLI rather than the actual problem. This is the "some things are not
  # possible in native mode" case, stated where it is hit.
  printf '%s: this project is not on Upsun, so there is nothing to pull from.\n' "$self" >&2
  printf 'Its .ddev/config.yaml is the source of truth and there is no hosted\n' >&2
  printf 'environment behind it.\n\n' >&2
  printf 'Load a database from a dump instead:\n\n' >&2
  printf '  ddev import-db --file=<dump.sql.gz>\n\n' >&2
  return 78
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
