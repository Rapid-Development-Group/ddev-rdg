#!/usr/bin/env bash
# Derives DDEV config from Platform.sh config. Pure: reads a project root,
# writes YAML to stdout. Warnings and notes go to stderr.
set -euo pipefail

# shellcheck source=rdg/source-hash.sh
source "$(dirname "${BASH_SOURCE[0]}")/source-hash.sh"

root="${1:?usage: derive.sh <project-root>}"
root="${root%/}"

die()  { printf 'rdg-sync: %s\n' "$*" >&2; exit 1; }
warn() { printf 'rdg-sync: warning: %s\n' "$*" >&2; }
note() { printf 'rdg-sync: %s\n' "$*" >&2; }

# --- locate the app config --------------------------------------------------
# Platform.sh resolves an app's root from wherever its config file lives, so it
# is not necessarily at the repo root.
if [ -n "${RDG_APP_ROOT:-}" ]; then
  app_config="$root/${RDG_APP_ROOT%/}/.platform.app.yaml"
  [ -f "$app_config" ] || die "RDG_APP_ROOT=$RDG_APP_ROOT but $app_config does not exist"
elif [ -f "$root/.platform.app.yaml" ]; then
  app_config="$root/.platform.app.yaml"
else
  candidates=()
  while IFS= read -r found; do
    candidates+=("$found")
  done < <(find "$root" -mindepth 2 -maxdepth 2 -name .platform.app.yaml | sort)
  case ${#candidates[@]} in
    0) die "no .platform.app.yaml at $root or one level below it" ;;
    1) app_config="${candidates[0]}" ;;
    *) die "multiple app configs found, set RDG_APP_ROOT to choose one: ${candidates[*]}" ;;
  esac
fi

app_dir="$(dirname "$app_config")"
app_root="${app_dir#"$root"}"
app_root="${app_root#/}"          # '' when the app is at the repo root

app_config_rel="${app_config#"$root"/}"
services_rel=".platform/services.yaml"
services="$root/$services_rel"

# --- composable runtimes ----------------------------------------------------
# Entries are either a scalar ("nodejs@20") or a single-key map
# ({"php@8.3": {extensions: [...]}}). The inner parentheses matter: without them
# the comma binds looser than the pipe and the second select runs against the
# document root, silently dropping every scalar entry.
runtimes() {
  yq -r '.stack.runtimes[]? | ( (select(tag == "!!map") | keys | .[0]), (select(tag == "!!str")) )' \
    "$app_config"
}

runtime_version() {
  runtimes | awk -F@ -v want="$1" '$1 == want { print $2; exit }'
}

# --- php --------------------------------------------------------------------
app_type="$(yq -r '.type // ""' "$app_config")"
php_version=""
case "$app_type" in
  php:*)        php_version="${app_type#php:}" ;;
  composable:*) php_version="$(runtime_version php)" ;;
  "")           warn "no 'type' declared in $app_config_rel" ;;
  *)            warn "unrecognised app type '$app_type'" ;;
esac
[ -n "$php_version" ] || warn "could not determine a PHP version"

# --- nodejs -----------------------------------------------------------------
nodejs_version="$(runtime_version nodejs)"
if [ -z "$nodejs_version" ]; then
  nodejs_version="$(yq -r '.dependencies.nodejs.nodejs // .dependencies.nodejs.nodejs_version // ""' "$app_config")"
fi

# --- database ---------------------------------------------------------------
# relationships.database has two documented forms: a short scalar
# ("mysqldb:mysql") or an extended map ({service: mysqldb, endpoint: mysql}).
# The tag must be checked before picking apart the value: naively slicing the
# map's rendered text on ':' pulls out "service" (or "{service") instead of
# the actual service name.
db_type=""; db_version=""
service_name=""
rel_tag="$(yq -r '.relationships.database | tag' "$app_config")"
case "$rel_tag" in
  '!!null')
    warn "no 'database' relationship declared, skipping the database key"
    ;;
  '!!map')
    service_name="$(yq -r '.relationships.database.service // ""' "$app_config")"
    if [ -z "$service_name" ]; then
      warn "'database' relationship is a malformed map (no 'service' key) in $app_config_rel, skipping the database key"
    fi
    ;;
  *)
    relationship="$(yq -r '.relationships.database // ""' "$app_config")"
    service_name="${relationship%%:*}"
    ;;
esac

if [ -n "$service_name" ]; then
  if [ ! -f "$services" ]; then
    warn "$services_rel not found, skipping the database key"
  else
    service_type="$(yq -r ".\"$service_name\".type // \"\"" "$services")"
    case "$service_type" in
      mariadb:*)      db_type="mariadb";  db_version="${service_type#mariadb:}" ;;
      mysql:*)        db_type="mysql";    db_version="${service_type#mysql:}" ;;
      oracle-mysql:*) db_type="mysql";    db_version="${service_type#oracle-mysql:}" ;;
      postgresql:*)   db_type="postgres"; db_version="${service_type#postgresql:}" ;;
      "")             warn "service '$service_name' is not defined in $services_rel" ;;
      *)              warn "unrecognised database service type '$service_type'" ;;
    esac

    # Snapshot of versions DDEV v1.25.3 supports, per
    # https://ddev.readthedocs.io/en/stable/users/extend/database-types/ —
    # refresh this list when DDEV's supported matrix changes. Unsupported
    # versions only get a warning, never a failure: a future DDEV release
    # adding versions must not block anyone.
    if [ -n "$db_type" ]; then
      supported=0
      case "$db_type" in
        mariadb)
          case "$db_version" in
            5.5|10.0|10.1|10.2|10.3|10.4|10.5|10.6|10.7|10.8|10.11|11.4|11.8|12.3) supported=1 ;;
          esac
          ;;
        mysql)
          case "$db_version" in
            5.5|5.6|5.7|8.0|8.4) supported=1 ;;
          esac
          ;;
        postgres)
          case "$db_version" in
            9|10|11|12|13|14|15|16|17|18) supported=1 ;;
          esac
          ;;
      esac
      [ "$supported" -eq 1 ] || warn "$db_type $db_version (service '$service_name' in $services_rel) is not a version DDEV v1.25.x supports; ddev start will reject it"
    fi
  fi
fi

# --- docroot ----------------------------------------------------------------
web_root="$(yq -r '.web.locations."/".root // ""' "$app_config")"
docroot=""
if [ -n "$web_root" ]; then
  docroot="${app_root:+$app_root/}${web_root#/}"
else
  warn 'no web.locations."/".root declared, skipping the docroot key'
fi

# --- what we deliberately do not translate ----------------------------------
for section in crons mounts workers; do
  if [ "$(yq -r ".$section // \"\" | length" "$app_config")" != "0" ]; then
    note "$section declared in $app_config_rel, not reproduced locally"
  fi
done
if [ "$(yq -r '.hooks // "" | length' "$app_config")" != "0" ]; then
  note "build/deploy hooks declared in $app_config_rel, not reproduced locally"
fi

# --- emit -------------------------------------------------------------------
hash_paths=("$app_config_rel" "$services_rel")
source_hash="$(rdg_source_hash "$root" "${hash_paths[@]}")"

cat <<EOF
# GENERATED by 'ddev rdg-sync'. Do not edit.
# Derived from $app_config_rel and $services_rel.
# Change the runtime there, run 'ddev rdg-sync', and commit the result.
# source-files: ${hash_paths[*]}
# source-sha256: $source_hash
EOF

[ -n "$php_version" ]    && printf 'php_version: "%s"\n' "$php_version"
[ -n "$nodejs_version" ] && printf 'nodejs_version: "%s"\n' "$nodejs_version"
[ -n "$docroot" ]        && printf 'docroot: %s\n' "$docroot"
[ -n "$app_root" ]       && printf 'composer_root: %s\n' "$app_root"

if [ -n "$db_type" ]; then
  printf 'database:\n    type: %s\n    version: "%s"\n' "$db_type" "$db_version"
fi

exit 0
