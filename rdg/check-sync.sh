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

generated="$root/.ddev/config.platformsh.yaml"

# --- native mode: nothing to guard ------------------------------------------
# A repo that is not on Upsun has no upstream to drift from -- .ddev/config.yaml is
# its source of truth -- so this guard has no job. Without this check it has a very
# bad one: it fails, fail_on_hook_fail makes that fatal, and every 'ddev start'
# aborts pointing at 'ddev rdg-sync', which then dies with "no .platform.app.yaml".
# The project cannot be started at all.
#
# BOTH conditions, not just the first. If config.platformsh.yaml exists then this
# repo was derived at some point, so a missing app config means it is broken --
# moved, deleted, or nested deeper than derive.sh looks -- and must keep failing.
# Testing only for the app config would let that repo slip quietly into native mode
# and lose exactly the drift protection this guard exists to provide.
if ! rdg_is_upsun_fixed "$root" && [ ! -f "$generated" ]; then
  exit 0
fi

# rdg-sync is a host command that shells into the container, so it needs the project
# up -- and this guard is what stopped it coming up. Always print the --skip-hooks
# recovery too. The deadlock is rare in practice, because the generated file is committed
# alongside the hosting config it derives from, so a colleague's change arrives already
# in sync; it bites only when you edit .platform.app.yaml locally and the project is down.
fail() {
  printf '\n%s\n\n  ddev rdg-sync && ddev start\n\n' "$1" >&2
  printf 'If the project is not running, rdg-sync cannot reach the container:\n\n' >&2
  printf '  ddev start --skip-hooks && ddev rdg-sync && ddev restart\n\n' >&2
  exit 1
}

[ -f "$generated" ] || fail "ddev-rdg: .ddev/config.platformsh.yaml is missing. Generate it with:"

recorded_hash="$(sed -n 's/^# source-sha256: \(.*\)$/\1/p' "$generated")"
read -r -a hashed_paths <<< "$(sed -n 's/^# source-files: \(.*\)$/\1/p' "$generated")"

if [ -z "$recorded_hash" ] || [ ${#hashed_paths[@]} -eq 0 ]; then
  fail "ddev-rdg: .ddev/config.platformsh.yaml has no checksum header. Regenerate it with:"
fi

current_hash="$(rdg_source_hash "$root" "${hashed_paths[@]}")"

if [ "$current_hash" != "$recorded_hash" ]; then
  fail "ddev-rdg: the Platform.sh config has changed since the last sync. Update DDEV config with:"
fi

exit 0
