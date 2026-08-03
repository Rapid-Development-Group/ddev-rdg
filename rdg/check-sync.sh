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

generated="$root/.ddev/config.platformsh.yaml"

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
