# ddev-rdg

Derives DDEV configuration from `.platform.app.yaml` and `.platform/services.yaml`,
so runtime versions live in exactly one place.

## Install

    ddev add-on get Rapid-Development-Group/ddev-rdg
    ddev rdg-sync
    git add .ddev/config.platformsh.yaml && git commit

Note: `ddev add-on remove rdg` leaves `.ddev/providers/platform.yaml` behind
intentionally (it cannot be auto-deleted). Delete it by hand if unwanted.

## Usage

Edit `.platform.app.yaml`, then run `ddev rdg-sync` and commit the result. A
`pre-start` hook refuses to start the project if the two have drifted, and prints
both recovery paths — including `ddev start --skip-hooks` for when the project is
down and `rdg-sync` therefore cannot reach the container.

If the repo already declares `web_extra_daemons` or `web_extra_exposed_ports` by
hand, `rdg-sync` refuses to run and names them: DDEV *appends* list keys when
merging `.ddev/config*.yaml`, so a hand-written block would survive alongside the
derived one and DDEV would reject the project for a duplicate `container_port`.
Delete those blocks first.

Commit the add-on's own files alongside the generated ones, as you would for any
DDEV add-on. A clone that has `config.platformsh.yaml` but not `rdg/theme-watch.sh`
will crash-loop the theme daemon.

## What it derives

`php_version`, `nodejs_version`, `database`, `docroot`, `composer_root`, the theme
asset daemon, the dev-server port, the build toolchain, and nginx snippets for
`web.locations` outside the docroot.

## What it does not translate

Crons, mounts, workers, and build/deploy hooks. `ddev rdg-sync` lists these so the
gap is visible rather than silent.

## Developing this add-on

    brew install bats-core yq
    bats tests/
