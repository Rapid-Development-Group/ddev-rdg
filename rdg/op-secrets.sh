#!/usr/bin/env bash
#ddev-generated
# Resolves a project's 1Password references into .ddev/.env.web.op.local, which DDEV
# loads into the web container. Runs on the HOST: `op` and its desktop-app sign-in
# live there, not in ddev-webserver.
#
# Usage: op-secrets.sh <project-root> [--hook]
#
# Where the references come from, first match wins:
#   .ddev/secrets.env   committed; one NAME="op://vault/item/field" per line
#   .env                a dkr-era repo's, whose secrets are already op:// references;
#                       only those lines are taken, so dkr's DB_HOST, *_TAG and the
#                       rest never reach the container
# Neither has one: nothing to do, exit 0 silently -- most repos have no secrets.
#
# --hook is the pre-start mode, and it ALWAYS exits 0. config.rdg.yaml sets
# fail_on_hook_fail, and a signed-out `op`, a laptop offline, or a CI runner with no
# 1Password must not stop the site starting: the site then fails only where it uses a
# key, not everywhere. Without --hook (`ddev op-secrets`) failures exit non-zero.
#
# A file rather than `op run -- ddev start`: a hook is a child of ddev and cannot put
# variables into the process that later runs `docker compose up`, and every other way
# of recreating the containers (restart, start -a, an add-on install) would silently
# drop them. See the README.

set -uo pipefail

root="${1:?usage: op-secrets.sh <project-root> [--hook]}"
root="${root%/}"
hook=false
[ "${2:-}" = "--hook" ] && hook=true

out="$root/.ddev/.env.web.op.local"
op_bin="${RDG_OP_BIN:-op}"   # tests substitute a fake

# fail <message>: in hook mode a warning and success, otherwise an error. Says
# whether the site is starting with the previous secrets or with none.
fail() {
  if $hook; then
    if [ -f "$out" ]; then
      echo "op-secrets: WARNING: $1 -- starting with the secrets from the last successful refresh, which may be stale." >&2
    else
      echo "op-secrets: WARNING: $1 -- starting with NO secrets; anything that needs an API key will fail. Fix it, then 'ddev op-secrets && ddev restart'." >&2
    fi
    exit 0
  fi
  echo "op-secrets: $1" >&2
  exit 1
}

if [ -f "$root/.ddev/secrets.env" ]; then
  src="$root/.ddev/secrets.env"
elif [ -f "$root/.env" ]; then
  src="$root/.env"
else
  $hook && exit 0
  fail "no .ddev/secrets.env or .env -- nothing to resolve."
fi

# The optional quote matters: repos write NAME="op://..." and a pattern without it
# silently matches nothing, which reads as "no secrets here" rather than a bug.
refs="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=["'"'"']?op://' "$src" || true)"
if [ -z "$refs" ]; then
  $hook && exit 0
  fail "no op:// references in ${src#"$root"/} -- nothing to resolve."
fi
names="$(printf '%s\n' "$refs" | cut -d= -f1)"

command -v "$op_bin" >/dev/null 2>&1 \
  || fail "the 1Password CLI is not installed ('brew install 1password-cli', then turn on the CLI integration in the 1Password app)"

umask 077
tmp_refs="$(mktemp)"
tmp_err="$(mktemp)"
# Beside the target so the mv is atomic: a failure never leaves a half-written file
# for DDEV to load with some keys silently empty.
tmp_out="$(mktemp "$root/.ddev/.op-secrets.XXXXXX")"
trap 'rm -f "$tmp_refs" "$tmp_err" "$tmp_out"' EXIT
printf '%s\n' "$refs" > "$tmp_refs"

# `op run` resolves the references into the child's environment; the child writes
# each one out in godotenv's double-quoted form. Not `op inject`, which passes the
# template's text through verbatim: a value holding a $, a quote or a newline (a PEM
# key) would then be re-read by godotenv as something else, silently. The escaping
# below round-trips all of those through DDEV -- verified on 1.25.4.
encoder="$(cat <<'EOF'
for n in "$@"; do
  v="${!n}"
  v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//\$/\\\$}"
  v="${v//$'\n'/\\n}"; v="${v//$'\r'/\\r}"
  printf '%s="%s"\n' "$n" "$v"
done
EOF
)"
# shellcheck disable=SC2086  # names are [A-Za-z0-9_] by the grep above
if ! "$op_bin" run --env-file="$tmp_refs" --no-masking -- bash -c "$encoder" _ $names \
     > "$tmp_out" 2>"$tmp_err"; then
  reason="$(head -n1 "$tmp_err")"
  fail "1Password could not resolve the references (${reason:-is the CLI signed in?})"
fi

# Belt and braces: anything still reading op:// was passed through, not resolved.
if grep -q '="op://' "$tmp_out"; then
  fail "not resolved, check the vault item names: $(grep '="op://' "$tmp_out" | cut -d= -f1 | tr '\n' ' ')"
fi

mv "$tmp_out" "$out"
chmod 600 "$out"
echo "op-secrets: $(grep -c . "$out") secrets from ${src#"$root"/} into .ddev/.env.web.op.local"
