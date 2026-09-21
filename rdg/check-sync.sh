#!/usr/bin/env bash
#ddev-generated
# Runs on the HOST as a pre-start hook. Deliberately uses only file reads and
# shasum: the host has no yq, and the docroot is only knowable by parsing the app
# config, which is why the generated file records the paths it hashed.
set -euo pipefail

root="${1:-$PWD}"
root="${root%/}"

# shellcheck source=rdg/source-hash.sh
source "$(dirname "${BASH_SOURCE[0]}")/source-hash.sh"
# shellcheck source=rdg/mode.sh
source "$(dirname "${BASH_SOURCE[0]}")/mode.sh"

mode="$(rdg_mode "$root")"

fixed_config="$root/.ddev/config.platformsh.yaml"
flex_config="$root/.ddev/config.upsun.yaml"

case "$mode" in
  flex)  generated="$flex_config";  stale="$fixed_config" ;;
  fixed) generated="$fixed_config"; stale="$flex_config" ;;
  *)     generated=""; stale="" ;;
esac

# rdg-sync is a host command that shells into the container, so it needs the project
# up -- and this guard is what stopped it coming up. Always print the --skip-hooks
# recovery too. The deadlock is rare in practice, because the generated file is committed
# alongside the hosting config it derives from, so a colleague's change arrives already
# in sync; it bites only when you edit the hosting config locally and the project is down.
fail() {
  printf '\n%s\n\n  ddev rdg-sync && ddev start\n\n' "$1" >&2
  printf 'If the project is not running, rdg-sync cannot reach the container:\n\n' >&2
  printf '  ddev start --skip-hooks && ddev rdg-sync && ddev restart\n\n' >&2
  exit 1
}

# --- native mode: nothing to guard ------------------------------------------
# A repo that is not on Upsun has no upstream to drift from -- .ddev/config.yaml is
# its source of truth -- so this guard has no job. Without this check it has a very
# bad one: it fails, fail_on_hook_fail makes that fatal, and every 'ddev start'
# aborts pointing at 'ddev rdg-sync', which then dies with "nothing to derive".
# The project cannot be started at all.
#
# BOTH conditions, not just the first. If a generated file exists then this repo was
# derived at some point, so losing the hosting config means it is broken -- moved,
# deleted, or nested deeper than derive.sh looks -- and must keep failing. Testing
# only for the hosting config would let that repo slip quietly into native mode and
# lose exactly the drift protection this guard exists to provide.
if [ "$mode" = native ] && [ ! -f "$fixed_config" ] && [ ! -f "$flex_config" ]; then
  exit 0
fi

if [ "$mode" = native ]; then
  fail "ddev-rdg: this repo has a generated DDEV config but no Upsun config to derive it from. Remove the generated file, or restore the hosting config and run:"
fi

# --- both generated files present -------------------------------------------
# A repo converted from Fixed to Flex arrives with the committed
# config.platformsh.yaml still in place, and DDEV merges EVERY .ddev/config.*.yaml
# it finds. Two of them means a stale php_version and two web_extra_exposed_ports
# entries claiming the same container_port, which DDEV rejects outright -- and it
# rejects it at parse time, so every later ddev command fails too. Refuse here,
# where the message can still be read, rather than letting DDEV refuse the project.
# 'ddev rdg-sync' deletes the stale one, which is why that is the recovery printed.
if [ -f "$fixed_config" ] && [ -f "$flex_config" ]; then
  fail "ddev-rdg: both .ddev/config.platformsh.yaml and .ddev/config.upsun.yaml exist. This repo is Upsun ${mode}, so $(basename "$stale") is a leftover. Delete it, or regenerate both with:"
fi

[ -f "$generated" ] || fail "ddev-rdg: .ddev/$(basename "$generated") is missing. Generate it with:"

recorded_hash="$(sed -n 's/^# source-sha256: \(.*\)$/\1/p' "$generated")"
read -r -a hashed_paths <<< "$(sed -n 's/^# source-files: \(.*\)$/\1/p' "$generated")"

if [ -z "$recorded_hash" ] || [ ${#hashed_paths[@]} -eq 0 ]; then
  fail "ddev-rdg: .ddev/$(basename "$generated") has no checksum header. Regenerate it with:"
fi

current_hash="$(rdg_source_hash "$root" "${hashed_paths[@]}")"

if [ "$current_hash" != "$recorded_hash" ]; then
  fail "ddev-rdg: the Upsun config has changed since the last sync. Update DDEV config with:"
fi

exit 0
