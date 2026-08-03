# ddev-rdg

Derives DDEV configuration from `.platform.app.yaml` and `.platform/services.yaml`,
so runtime versions live in exactly one place.

> **Not ready for use yet — no release has been tagged.**
>
> `rdg/theme-watch.sh` does not exist yet, but the generated config already declares a
> daemon that runs it, so installing from this branch and restarting leaves a
> crash-looping daemon. `ddev add-on get` resolves to the latest *release*, so there is
> nothing to install by accident until the first tag lands.
>
> Remaining before v1.0.0: the theme watcher and pull provider, and an end-to-end
> verification against the pilot project.

## Install

    ddev add-on get Rapid-Development-Group/ddev-rdg
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
