#!/usr/bin/env bash
#ddev-generated
# Derives the Redis Docker image from Platform.sh config. Pure: reads the two
# config files, prints one image tag to stdout. Prints nothing when the project
# has no Redis service. Warnings go to stderr.
#
# Separate from derive.sh because the answer is not DDEV config. DDEV has no
# Redis version key -- Redis comes from the ddev-redis add-on, which reads
# REDIS_DOCKER_IMAGE out of a dotenv file that docker-compose interpolates. So
# this returns a value for rdg-sync to write somewhere else, rather than a line
# for config.platformsh.yaml.
set -euo pipefail

app_config="${1:?usage: derive-redis.sh <app-config-path> <services-path>}"
services="${2:?usage: derive-redis.sh <app-config-path> <services-path>}"

warn() { printf 'rdg-sync: warning: %s\n' "$*" >&2; }

[ -f "$app_config" ] || { warn "$app_config not found, skipping the Redis image"; exit 0; }
[ -f "$services" ]   || { warn "$services not found, skipping the Redis image"; exit 0; }

# Every service the app actually relates to, in declaration order.
#
# A relationship is either a scalar ("rediscache:redis") or an extended map
# ({service: rediscache, endpoint: redis}). The inner parentheses matter: without
# them the comma binds looser than the pipe and the second select runs against
# the document root, silently dropping every scalar entry -- the same trap
# derive.sh documents for stack.runtimes.
related_services() {
  yq -r '.relationships // {} | to_entries[] | .value |
           ( (select(tag == "!!map") | .service // ""),
             (select(tag == "!!str") | split(":")[0]) )' "$app_config"
}

# Relationship-driven rather than scanning services.yaml for anything of type
# redis, because a service the app does not relate to is one the app cannot
# reach -- reproducing its version locally would be pinning to something the
# site never talks to.
image=""
matched=""
while IFS= read -r service; do
  [ -n "$service" ] || continue

  # strenv, not string concatenation into the expression: a service name
  # containing a double quote would close the yq string early and abort with a
  # raw parse error instead of a useful message.
  service_type="$(service_name="$service" yq -r '.[strenv(service_name)].type // ""' "$services")"

  case "$service_type" in
    redis:*)  candidate="redis:${service_type#redis:}" ;;
    valkey:*) candidate="valkey/valkey:${service_type#valkey:}" ;;
    *)        continue ;;
  esac

  if [ -n "$image" ]; then
    # Two key-value services and no way to know which one the local single
    # container should be. Keeping the first is a guess; saying so is not.
    warn "more than one Redis-like service is related ('$matched' and '$service'), using '$matched'"
    continue
  fi

  image="$candidate"
  matched="$service"
done < <(related_services)

[ -n "$image" ] && printf '%s\n' "$image"
exit 0
