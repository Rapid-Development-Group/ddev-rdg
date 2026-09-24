#!/usr/bin/env bats

# What the add-on ships, and the properties of the shipped files that DDEV itself
# depends on. None of this is exercised by driving a script, so it is asserted
# directly against install.yaml and config.rdg.yaml.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INSTALL="$REPO_ROOT/install.yaml"
  STATIC_CONFIG="$REPO_ROOT/config.rdg.yaml"
  PROVIDERS="$REPO_ROOT/providers/platform.yaml
$REPO_ROOT/providers/upsun.yaml"
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

@test "every shipped file carries DDEV's generated marker, except the pull providers" {
  # The Critical finding this guards: without the marker DDEV silently overwrites
  # a shipped file on the next start (it searches the whole file for the string,
  # not just line 1). The two provider recipes are the deliberate exception -- they
  # are ours, and the marker is what would make DDEV revert them.
  local f count=0 failed=""
  while IFS= read -r f; do
    count=$((count + 1))
    if [ ! -f "$f" ]; then
      failed="$failed
  listed in project_files but does not exist: $f"
      continue
    fi
    if printf '%s\n' "$PROVIDERS" | grep -qxF "$f"; then
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
  # The Upsun Flex counterpart. Its absence would leave 'ddev upsun-db-pull' on a
  # Flex repo resolving to DDEV's stock recipe, which downloads every mount to the
  # wrong place and still carries both push commands.
  printf '%s\n' "$entries" | grep -qx 'providers/upsun.yaml'
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
  # Two tasks, the guard first: a drifted project aborts before op-secrets asks
  # for a 1Password unlock it is not going to use.
  [ "$(yq -r '.hooks["pre-start"] | length' "$STATIC_CONFIG")" = "2" ]
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

@test "removal deletes the files rdg-sync generates" {
  # They carry no #ddev-generated marker, so removal would otherwise leave
  # config.platformsh.yaml declaring a daemon whose script was just deleted, with
  # config.rdg.yaml gone so nothing complains: a project that starts crash-looping.
  #
  # The theme toolchain Dockerfile is deliberately NOT in this list any more: it ships
  # with the add-on and carries the marker, so DDEV removes it itself.
  local actions
  actions="$(yq -r '.removal_actions[]' "$INSTALL")"
  printf '%s\n' "$actions" | grep -qF 'config.platformsh.yaml'
  # Both generated names. A repo is one shape or the other, but neither file
  # carries the marker, so removal has to name both or a converted repo keeps the
  # one it is no longer generating.
  printf '%s\n' "$actions" | grep -qF 'config.upsun.yaml'
  printf '%s\n' "$actions" | grep -qF 'nginx/platform-locations.conf'
}

@test "the theme toolchain ships with the add-on, for every repo" {
  # Native repos have no Upsun config to derive from, so a generated toolchain could
  # never reach them -- each kept its own copy of the same three lines.
  local entries
  entries="$(yq -r '.project_files[]' "$INSTALL")"
  printf '%s\n' "$entries" | grep -qx 'web-build/Dockerfile.rdg-theme-toolchain'
  # The packages that actually matter; without autoconf/dh-autoreconf the imagemin
  # build dies at 'autoreconf -ivf'.
  local f="$REPO_ROOT/web-build/Dockerfile.rdg-theme-toolchain"
  grep -qF 'autoconf' "$f"
  grep -qF 'dh-autoreconf' "$f"
  grep -qF 'zlib1g-dev' "$f"
}

@test "installing cleans up the Dockerfile rdg-sync used to generate" {
  # The old generated file carries no marker, so DDEV will not remove it on upgrade and
  # the toolchain would be installed twice.
  local actions
  actions="$(yq -r '.post_install_actions[]' "$INSTALL")"
  printf '%s\n' "$actions" | grep -qF 'rm -f web-build/Dockerfile.rdg-theme'
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

# --- the Mailpit hostname ------------------------------------------------------

@test "installing puts Mailpit's UI on a hostname, in every mode" {
  # Not left to each repo to remember. DDEV serves Mailpit on a PORT against the
  # bare project hostname, one ddev-router serves every project, and the default
  # 8025/8026 therefore belongs to whichever project started first -- so without
  # this you silently read another project's mail.
  local actions
  actions="$(yq -r '.post_install_actions[]' "$INSTALL")"
  printf '%s\n' "$actions" | grep -qF 'rdg/mailpit-hostname.sh'
}

@test "removal deletes both Mailpit files, which carry no ddev marker" {
  local actions
  actions="$(yq -r '.removal_actions[]' "$INSTALL")"
  printf '%s\n' "$actions" | grep -qF 'traefik/config/mailpit.yaml'
  printf '%s\n' "$actions" | grep -qF 'config.mailpit.yaml'
}

@test "the Mailpit generator ships, and is reachable from post_install_actions" {
  printf '%s\n' "$(shipped_files)" | grep -qF '/rdg/mailpit-hostname.sh'
}

@test "the generated Mailpit files must NOT carry the ddev-generated marker" {
  # DDEV regenerates traefik/config/ and owns config.*.yaml carrying the marker, so
  # a marker here means the router vanishes on the next restart -- intermittently,
  # which is the worst way for it to fail.
  local proj="$BATS_TEST_TMPDIR/p"
  mkdir -p "$proj/.ddev"
  printf 'name: demo\ntype: drupal11\n' > "$proj/.ddev/config.yaml"
  bash "$REPO_ROOT/rdg/mailpit-hostname.sh" "$proj/.ddev"
  ! grep -qF '#ddev-generated' "$proj/.ddev/traefik/config/mailpit.yaml"
  ! grep -qF '#ddev-generated' "$proj/.ddev/config.mailpit.yaml"
}

@test "the router points at the web container's Mailpit and outranks DDEV's own" {
  local proj="$BATS_TEST_TMPDIR/p"
  mkdir -p "$proj/.ddev"
  printf 'name: demo\ntype: drupal11\n' > "$proj/.ddev/config.yaml"
  bash "$REPO_ROOT/rdg/mailpit-hostname.sh" "$proj/.ddev"
  local r="$proj/.ddev/traefik/config/mailpit.yaml"
  [ "$(yq -r '.http.services."demo-mailpit-ui".loadbalancer.servers[0].url' "$r")" = "http://ddev-demo-web:8025" ]
  [ "$(yq -r '.http.routers."demo-mailpit-ui".priority' "$r")" -gt 0 ]
  [ "$(yq -r '.http.routers."demo-mailpit-ui".tls' "$r")" = "true" ]
  # additional_hostnames, not additional_fqdns: DDEV appends '.ddev.site' itself,
  # and a bare 'mailpit' here would publish https://mailpit.ddev.site and claim that
  # name in the namespace every other project shares.
  [ "$(yq -r '.additional_hostnames[0]' "$proj/.ddev/config.mailpit.yaml")" = "mailpit.demo" ]
}

@test "a project name that is not a DNS label is declined, not mangled" {
  local proj="$BATS_TEST_TMPDIR/bad"
  mkdir -p "$proj/.ddev"
  printf 'name: "my project"\ntype: drupal11\n' > "$proj/.ddev/config.yaml"
  run bash "$REPO_ROOT/rdg/mailpit-hostname.sh" "$proj/.ddev"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'not a DNS label'
  [ ! -f "$proj/.ddev/traefik/config/mailpit.yaml" ]
  [ ! -f "$proj/.ddev/config.mailpit.yaml" ]
}

@test "a config.yaml with no name takes the enclosing directory, as DDEV does" {
  # Omitting 'name:' is how one repo runs as several projects at once -- a
  # worktree per branch, each its own stack -- so this is a normal configuration,
  # and DDEV names such a project after its directory. Guessing differently here
  # would point mailpit.<project>.ddev.site at the application, which answers 200.
  local proj="$BATS_TEST_TMPDIR/rdg2020-vite"
  mkdir -p "$proj/.ddev"
  printf 'type: drupal11\n' > "$proj/.ddev/config.yaml"
  run bash "$REPO_ROOT/rdg/mailpit-hostname.sh" "$proj/.ddev"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.additional_hostnames[0]' "$proj/.ddev/config.mailpit.yaml")" = "mailpit.rdg2020-vite" ]
  [ "$(yq -r '.http.services."rdg2020-vite-mailpit-ui".loadbalancer.servers[0].url' \
      "$proj/.ddev/traefik/config/mailpit.yaml")" = "http://ddev-rdg2020-vite-web:8025" ]
}

@test "the enclosing directory is resolved when .ddev is given as a relative path" {
  # install.yaml calls this as 'bash rdg/mailpit-hostname.sh .' with .ddev as the
  # working directory. dirname of '.' is '.', so a naive parent lookup names the
  # .ddev directory itself and every project in the fleet would be called 'ddev'.
  local proj="$BATS_TEST_TMPDIR/relative-case"
  mkdir -p "$proj/.ddev"
  printf 'type: drupal11\n' > "$proj/.ddev/config.yaml"
  run bash -c "cd '$proj/.ddev' && bash '$REPO_ROOT/rdg/mailpit-hostname.sh' ."
  [ "$status" -eq 0 ]
  [ "$(yq -r '.additional_hostnames[0]' "$proj/.ddev/config.mailpit.yaml")" = "mailpit.relative-case" ]
}

@test "a name carrying capitals is lowercased in the host but not in the container" {
  # DDEV accepts such a name rather than refusing it, and is itself inconsistent:
  # 'Rdg2020-Bad' gets the container 'ddev-Rdg2020-Bad-web' behind the rule
  # 'HostRegexp(`^rdg2020-bad.ddev.site$`)'. Following only one of the two gives
  # either a rule that never matches or a service pointing at no container.
  local proj="$BATS_TEST_TMPDIR/Rdg2020-Bad"
  mkdir -p "$proj/.ddev"
  printf 'type: drupal11\n' > "$proj/.ddev/config.yaml"
  run bash "$REPO_ROOT/rdg/mailpit-hostname.sh" "$proj/.ddev"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://mailpit.rdg2020-bad.ddev.site"* ]]

  local r="$proj/.ddev/traefik/config/mailpit.yaml"
  grep -qF 'rule: HostRegexp(`^mailpit\.rdg2020-bad\.ddev\.site$`)' "$r"
  grep -qF 'url: http://ddev-Rdg2020-Bad-web:8025' "$r"
  [ "$(yq -r '.additional_hostnames[0]' "$proj/.ddev/config.mailpit.yaml")" = "mailpit.rdg2020-bad" ]
}

@test "an explicit name still wins over the directory it sits in" {
  local proj="$BATS_TEST_TMPDIR/some-directory"
  mkdir -p "$proj/.ddev"
  printf 'name: explicit\ntype: drupal11\n' > "$proj/.ddev/config.yaml"
  bash "$REPO_ROOT/rdg/mailpit-hostname.sh" "$proj/.ddev"
  [ "$(yq -r '.additional_hostnames[0]' "$proj/.ddev/config.mailpit.yaml")" = "mailpit.explicit" ]
  ! grep -qF some-directory "$proj/.ddev/traefik/config/mailpit.yaml"
}

@test "a quoted project name is unquoted before it reaches the hostname" {
  local proj="$BATS_TEST_TMPDIR/q"
  mkdir -p "$proj/.ddev"
  printf 'name: "demo"\ntype: drupal11\n' > "$proj/.ddev/config.yaml"
  bash "$REPO_ROOT/rdg/mailpit-hostname.sh" "$proj/.ddev"
  [ "$(yq -r '.additional_hostnames[0]' "$proj/.ddev/config.mailpit.yaml")" = "mailpit.demo" ]
}
