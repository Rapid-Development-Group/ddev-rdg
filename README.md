# ddev-rdg

Derives DDEV configuration from `.platform.app.yaml` and `.platform/services.yaml`,
so runtime versions live in exactly one place.

## Install

    ddev add-on get rapiddg/ddev-rdg
    ddev rdg-sync
    git add .ddev/config.platformsh.yaml && git commit

Note: `ddev add-on remove rdg` leaves `.ddev/providers/platform.yaml` behind
intentionally (it cannot be auto-deleted). Delete it by hand if unwanted.

## Usage

Edit `.platform.app.yaml`, then run `ddev rdg-sync` and commit the result. A
`pre-start` hook refuses to start the project if the two have drifted.

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
