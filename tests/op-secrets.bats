#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/rdg/op-secrets.sh"
  PROJ="$BATS_TEST_TMPDIR/proj"
  OUT="$PROJ/.ddev/.env.web.op.local"
  mkdir -p "$PROJ/.ddev"

  # A fake `op run --env-file=F --no-masking -- cmd...`: each op://vault/item/field
  # resolves to the contents of $VAULT/vault/item/field, and a missing one fails
  # the way the real CLI does. FAKE_OP_FAIL simulates being signed out.
  VAULT="$BATS_TEST_TMPDIR/vault"
  mkdir -p "$VAULT"
  export RDG_OP_BIN="$BATS_TEST_TMPDIR/op"
  cat > "$RDG_OP_BIN" <<EOF
#!/usr/bin/env bash
[ -n "\${FAKE_OP_FAIL:-}" ] && { echo "[ERROR] not signed in" >&2; exit 1; }
env_file="\${2#--env-file=}"; shift 4
while IFS= read -r line; do
  name="\${line%%=*}"; ref="\${line#*=}"; ref="\${ref//\"/}"; ref="\${ref#op://}"
  [ -f "$VAULT/\$ref" ] || { echo "[ERROR] could not find item \$ref" >&2; exit 1; }
  export "\$name=\$(cat "$VAULT/\$ref")"
done < "\$env_file"
exec "\$@"
EOF
  chmod +x "$RDG_OP_BIN"
}

secret() { mkdir -p "$VAULT/$(dirname "$1")"; printf '%s' "$2" > "$VAULT/$1"; }

@test "a repo with no references is a silent no-op in the hook" {
  printf 'DB_HOST=mariadb\n' > "$PROJ/.env"
  run bash "$SCRIPT" "$PROJ" --hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$OUT" ]
}

@test "a dkr .env contributes only its op:// lines" {
  secret app/site/key 'k1'
  printf 'DB_HOST=mariadb\nPHP_TAG=8.1\nAPI_KEY="op://app/site/key"\n' > "$PROJ/.env"
  run bash "$SCRIPT" "$PROJ" --hook
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT")" = 'API_KEY="k1"' ]
}

@test ".ddev/secrets.env wins over .env" {
  secret app/site/new 'from-template'
  printf 'OLD="op://app/site/old"\n' > "$PROJ/.env"
  printf '# committed references\nNEW=op://app/site/new\n' > "$PROJ/.ddev/secrets.env"
  run bash "$SCRIPT" "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT")" = 'NEW="from-template"' ]
}

@test "dollar signs, quotes, backslashes and newlines are escaped for godotenv" {
  # The escaping is what DDEV 1.25.4 was verified to read back exactly.
  secret app/site/pem 'a$b${HOME}"c\d
line2'
  printf 'PEM="op://app/site/pem"\n' > "$PROJ/.ddev/secrets.env"
  run bash "$SCRIPT" "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT")" = 'PEM="a\$b\${HOME}\"c\\d\nline2"' ]
}

@test "the output is readable by the owner only" {
  secret app/site/key 'k1'
  printf 'API_KEY="op://app/site/key"\n' > "$PROJ/.ddev/secrets.env"
  bash "$SCRIPT" "$PROJ"
  # find, not stat: GNU `stat -f` means filesystem status and succeeds, so a
  # BSD-first `stat -f || stat -c` fallback never falls back on Linux.
  [ -n "$(find "$OUT" -perm 600)" ]
}

@test "signed out, in the hook, with no previous file: warns and starts anyway" {
  printf 'API_KEY="op://app/site/key"\n' > "$PROJ/.ddev/secrets.env"
  FAKE_OP_FAIL=1 run bash "$SCRIPT" "$PROJ" --hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO secrets"* ]]
  [ ! -e "$OUT" ]
}

@test "signed out, in the hook, with a previous file: keeps it and says it may be stale" {
  printf 'API_KEY="op://app/site/key"\n' > "$PROJ/.ddev/secrets.env"
  printf 'API_KEY="previous"\n' > "$OUT"
  FAKE_OP_FAIL=1 run bash "$SCRIPT" "$PROJ" --hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale"* ]]
  [ "$(cat "$OUT")" = 'API_KEY="previous"' ]
}

@test "a missing vault item fails the strict command and leaves the old file alone" {
  secret app/site/key 'k1'
  printf 'API_KEY="op://app/site/key"\nGONE="op://app/site/gone"\n' > "$PROJ/.ddev/secrets.env"
  printf 'API_KEY="previous"\n' > "$OUT"
  run bash "$SCRIPT" "$PROJ"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not find item"* ]]
  [ "$(cat "$OUT")" = 'API_KEY="previous"' ]
  # No temp file left behind for DDEV to trip over.
  [ -z "$(find "$PROJ/.ddev" -name '.op-secrets.*')" ]
}

@test "no op CLI: the hook warns and succeeds, the command fails" {
  printf 'API_KEY="op://app/site/key"\n' > "$PROJ/.ddev/secrets.env"
  RDG_OP_BIN=/nonexistent/op run bash "$SCRIPT" "$PROJ" --hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed"* ]]
  RDG_OP_BIN=/nonexistent/op run bash "$SCRIPT" "$PROJ"
  [ "$status" -eq 1 ]
}

@test "a reference passed through unresolved is refused" {
  # The real CLI can exit 0 having left a value as the literal reference.
  secret app/site/key 'op://still/a/reference'
  printf 'API_KEY="op://app/site/key"\n' > "$PROJ/.ddev/secrets.env"
  run bash "$SCRIPT" "$PROJ"
  [ "$status" -eq 1 ]
  [[ "$output" == *"API_KEY"* ]]
  [ ! -e "$OUT" ]
}

@test "the add-on runs it on pre-start in hook mode" {
  yq -r '.hooks."pre-start"[]."exec-host"' "$REPO_ROOT/config.rdg.yaml" \
    | grep -qxF 'bash .ddev/rdg/op-secrets.sh . --hook'
}
