#!/usr/bin/env bats

# What the add-on ships, and the properties of the shipped files that DDEV itself
# depends on. None of this is exercised by driving a script, so it is asserted
# directly against install.yaml and config.rdg.yaml.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INSTALL="$REPO_ROOT/install.yaml"
  STATIC_CONFIG="$REPO_ROOT/config.rdg.yaml"
  PROVIDER="$REPO_ROOT/providers/platform.yaml"
}

# Expands project_files into the concrete file list DDEV would copy into .ddev/.
shipped_files() {
  local entry f
  while IFS= read -r entry; do
    case "$entry" in
      */) find "$REPO_ROOT/${entry%/}" -type f | sort ;;
      *)  printf '%s\n' "$REPO_ROOT/$entry" ;;
    esac
  done < <(yq -r '.project_files[]' "$INSTALL")
}

@test "every shipped file carries DDEV's generated marker, except the pull provider" {
  # The Critical finding this guards: without the marker DDEV silently overwrites
  # a shipped file on the next start (it searches the whole file for the string,
  # not just line 1). The provider is the deliberate exception -- it is ours, and
  # the marker is what would make DDEV revert our recipe.
  local f count=0 failed=""
  while IFS= read -r f; do
    count=$((count + 1))
    if [ ! -f "$f" ]; then
      failed="$failed
  listed in project_files but does not exist: $f"
      continue
    fi
    if [ "$f" = "$PROVIDER" ]; then
      if grep -qF '#ddev-generated' "$f"; then
        failed="$failed
  must NOT carry the marker (DDEV would overwrite our recipe): $f"
      fi
    elif ! grep -qF '#ddev-generated' "$f"; then
      failed="$failed
  missing the marker (DDEV will overwrite it): $f"
    fi
  done < <(shipped_files)

  # A sanity floor: if project_files ever expands to nothing the loop above would
  # vacuously pass.
  [ "$count" -ge 8 ] || { echo "project_files expanded to only $count files"; return 1; }
  [ -z "$failed" ] || { echo "$failed"; return 1; }
}

@test "install.yaml ships the deriver, the static config, the provider and the scripts" {
  # Dropping commands/host/rdg-sync leaves a project with a pre-start guard and no
  # way to satisfy it: every start aborts and 'ddev rdg-sync' is not a command.
  local entries
  entries="$(yq -r '.project_files[]' "$INSTALL")"
  printf '%s\n' "$entries" | grep -qx 'commands/host/rdg-sync'
  # The pull wrappers: shipped but not load-bearing for startup, so their absence
  # would be silent -- 'ddev upsun-db-pull' would just not be a command.
  printf '%s\n' "$entries" | grep -qx 'commands/host/upsun-db-pull'
  printf '%s\n' "$entries" | grep -qx 'commands/host/upsun-files-pull'
  printf '%s\n' "$entries" | grep -qx 'rdg/'
  printf '%s\n' "$entries" | grep -qx 'config.rdg.yaml'
  printf '%s\n' "$entries" | grep -qx 'providers/platform.yaml'
}

@test "the shipped file list covers every script rdg-sync and the guard invoke" {
  local shipped
  shipped="$(shipped_files)"
  printf '%s\n' "$shipped" | grep -qF '/rdg/derive.sh'
  printf '%s\n' "$shipped" | grep -qF '/rdg/nginx-locations.sh'
  printf '%s\n' "$shipped" | grep -qF '/rdg/check-sync.sh'
  printf '%s\n' "$shipped" | grep -qF '/rdg/source-hash.sh'
  printf '%s\n' "$shipped" | grep -qF '/rdg/theme-watch.sh'
  # Sourced by both pull wrappers; ships inside rdg/ rather than as its own entry.
  printf '%s\n' "$shipped" | grep -qF '/rdg/pull-args.sh'
  # Sourced by check-sync.sh, rdg-sync and pull-args.sh. Its absence would break
  # the pre-start hook on every project, derived and native alike.
  printf '%s\n' "$shipped" | grep -qF '/rdg/mode.sh'
}

@test "post_install_actions chmods every host command the add-on ships" {
  # A non-executable host command is not registered by DDEV at all: it vanishes
  # from 'ddev -h' with no error, which reads as a broken install rather than a
  # packaging slip. Derived from project_files so a third command cannot be added
  # without its chmod.
  local actions entry
  actions="$(yq -r '.post_install_actions[]' "$INSTALL")"
  while IFS= read -r entry; do
    case "$entry" in
      commands/host/*)
        printf '%s\n' "$actions" | grep -qF "chmod +x $entry" \
          || { echo "project_files has $entry with no matching chmod"; return 1; }
        ;;
    esac
  done < <(yq -r '.project_files[]' "$INSTALL")
}

@test "fail_on_hook_fail makes the pre-start guard authoritative, not advisory" {
  # With this false the guard prints its diagnosis and the project starts anyway
  # on stale derived values -- exactly the silent drift the guard exists to stop.
  [ "$(yq -r '.fail_on_hook_fail' "$STATIC_CONFIG")" = "true" ]
}

@test "the static config wires the guard as a pre-start exec-host task" {
  [ "$(yq -r '.hooks["pre-start"] | length' "$STATIC_CONFIG")" = "1" ]
  # exec-host, not exec: the guard runs on the host precisely because the project
  # may be down, which is when there is no container to exec into.
  [ "$(yq -r '.hooks["pre-start"][0]["exec-host"]' "$STATIC_CONFIG")" = "bash .ddev/rdg/check-sync.sh ." ]
}

@test "the static config ships corepack_enable, the derived daemon's prerequisite" {
  # The daemon runs 'yarn', and the only yarn on PATH in ddev-webserver is the
  # corepack shim this setting creates. Without it the daemon crash-loops 15 times
  # reporting a dependency install failure, which names the wrong cause.
  [ "$(yq -r '.corepack_enable' "$STATIC_CONFIG")" = "true" ]
}

@test "removal deletes the three generated files" {
  # They carry no #ddev-generated marker, so removal would otherwise leave
  # config.platformsh.yaml declaring a daemon whose script was just deleted, with
  # config.rdg.yaml gone so nothing complains: a project that starts crash-looping.
  local actions
  actions="$(yq -r '.removal_actions[]' "$INSTALL")"
  printf '%s\n' "$actions" | grep -qF 'config.platformsh.yaml'
  printf '%s\n' "$actions" | grep -qF 'nginx/platform-locations.conf'
  printf '%s\n' "$actions" | grep -qF 'web-build/Dockerfile.rdg-theme'
}

@test "no shipped file has an active line that names webpack" {
  # The design is bundler-agnostic: the daemon invokes the repo's own 'yarn start'
  # and derives the dev-server port from the repo's own dependencies, so no shipped
  # code may branch on, invoke, or hardcode a bundler by name.
  #
  # Comment lines are excluded on purpose. derive.sh explains where the 35729
  # default comes from (webpack-livereload-plugin's port, which is what the fleet
  # uses today) and that explanation is the reason the number is not arbitrary.
  # Banning the word in prose would delete the rationale, not the coupling.
  local f failed=""
  while IFS= read -r f; do
    if grep -v '^[[:space:]]*#' "$f" | grep -qi webpack; then failed="$failed $f"; fi
  done < <(shipped_files)
  [ -z "$failed" ] || { echo "bundler-specific active lines in:$failed"; return 1; }
}
