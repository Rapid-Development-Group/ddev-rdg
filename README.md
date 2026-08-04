# ddev-rdg

Derives DDEV configuration from `.platform.app.yaml` and `.platform/services.yaml`,
so runtime versions live in exactly one place.

## Install

First run, on a repo that has no `.ddev/config.platformsh.yaml` yet:

    ddev add-on get Rapid-Development-Group/ddev-rdg
    ddev start --skip-hooks     # see below: plain 'ddev start' cannot work yet
    ddev rdg-sync
    git add .ddev && git commit
    ddev restart               # nothing derived applies until this

`--skip-hooks` is required exactly once. The add-on installs a `pre-start` guard
that aborts the start while `config.platformsh.yaml` is missing or stale, and
`ddev rdg-sync` shells into the web container, so it needs the project up — the
guard would otherwise block the only command that can satisfy it. After the first
sync, `ddev start` works normally.

`ddev restart` is not optional. A `pre-start` hook runs after DDEV has parsed the
config, so the values `rdg-sync` just wrote take effect on the *next* start.

`git add .ddev` rather than a file list: three generated files
(`config.platformsh.yaml`, `nginx/platform-locations.conf`,
`web-build/Dockerfile.rdg-theme`, the last two only when the repo needs them) and
the add-on's own installed files all belong in the commit. A clone that has
`config.platformsh.yaml` but not `rdg/theme-watch.sh` will crash-loop the theme
daemon. DDEV's own `.ddev/.gitignore` already excludes what should not be tracked.

Note: `ddev add-on remove rdg` deletes the three generated files, but leaves
`.ddev/providers/platform.yaml` behind — removal is gated on DDEV's
generated-marker comment, which that file deliberately does not carry. Delete it
by hand if unwanted.

## Usage

### Pulling from a Platform.sh environment

    ddev platform-db-pull [environment]      # database only
    ddev platform-files-pull [environment]   # public files only

Sugar for `ddev pull platform --skip-files --environment="PLATFORM_ENVIRONMENT=<env>"`
and its `--skip-db` counterpart, so choosing an environment costs one word instead of
sixty characters.

With no argument neither command passes `--environment` at all, so whatever the project
pins in its own `.ddev/config.yaml` applies — deliberately not hardcoded to `master`,
since repos pin different environments.

Neither passes `-y`: DDEV's confirmation is what shows which environment is about to
overwrite local data, and picking the environment is the whole point. Neither takes any
flags either — for `--skip-import` and friends, use `ddev pull platform` directly.

Note that the provider resumes a paused environment (`platform environment:resume`)
before pulling from it, which is a change to remote state.

### Keeping the derived config in sync

Edit `.platform.app.yaml`, then run `ddev rdg-sync` and commit the result. A
`pre-start` hook refuses to start the project if the two have drifted, and prints
both recovery paths — including `ddev start --skip-hooks` for when the project is
down and `rdg-sync` therefore cannot reach the container.

If the repo already declares `web_extra_daemons` or `web_extra_exposed_ports` by
hand, `rdg-sync` refuses to run and names them: DDEV *appends* list keys when
merging `.ddev/config*.yaml`, so a hand-written block would survive alongside the
derived one and DDEV would reject the project for a duplicate `container_port`.
Delete those blocks first.

## What it derives

`php_version`, `nodejs_version`, `database`, `docroot`, `composer_root`, the theme
asset daemon, the dev-server port, the build toolchain, and nginx snippets for
`web.locations` outside the docroot.

## What it does not translate

Crons, mounts, workers, and build/deploy hooks. `ddev rdg-sync` lists these so the
gap is visible rather than silent.

## Developing this add-on

    brew install bats-core yq jq
    bats tests/

Each fixture in `tests/fixtures/` has a committed golden output in
`tests/expected/`, diffed whole. When a change to the derivation is deliberate,
regenerate the goldens and read the diff before committing it:

    for f in composable-subdir classic-root no-theme vite-theme; do
      bash rdg/derive.sh "tests/fixtures/$f" 2>/dev/null \
        > "tests/expected/$f.config.platformsh.yaml"
    done
    bash rdg/nginx-locations.sh \
      tests/fixtures/composable-subdir/drupal/.platform.app.yaml drupal/web \
      > tests/expected/composable-subdir.platform-locations.conf

`tests/rdg-sync.bats` drives `commands/host/rdg-sync` with a stub `ddev` on
`PATH`, so it needs no running project.
