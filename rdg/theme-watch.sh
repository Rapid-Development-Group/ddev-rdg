#!/usr/bin/env bash
#ddev-generated

# Long-running theme asset watcher, run as a DDEV web_extra_daemon.
#
# Replaces the dedicated node container these projects used to run under
# docker-compose. Deliberately bundler-agnostic: it runs a script the repo
# declares, so the choice of bundler is the repo's business.
#
# $1 is which script, derived and passed by 'ddev rdg-sync', because the fleet
# uses two names for the same job. It defaults to 'start' so that a
# config.platformsh.yaml generated before this argument existed keeps working:
# DDEV never re-derives on an add-on upgrade, so those configs stay in the wild
# until someone runs 'ddev rdg-sync' again.
theme_script="${1:-start}"

# The daemon's `directory` already sets this, but DDEV_DOCROOT makes the script
# correct when run by hand too.
cd "/var/www/html/${DDEV_DOCROOT:-.}" || exit 1

export NODE_ENV=development

# The project is a mounted filesystem, so the watcher gets no inotify events.
# These are honoured by the tooling we use today and harmless otherwise, but they
# are a hint, not a guarantee -- chokidar itself reads no environment. A bundler
# that does its own watching needs polling enabled in its own config.
export CHOKIDAR_USEPOLLING=1
export CHOKIDAR_INTERVAL=1000

# imagemin's image binaries ship x86_64-only prebuilts, so on Apple silicon they
# compile from source, and the bundled libpng fails to link on aarch64 with
# 'undefined reference to png_init_filter_functions_neon' unless the NEON path is
# compiled out. Harmless once those dependencies are gone.
export CPPFLAGS="-DPNG_ARM_NEON_OPT=0"

# Gated explicitly rather than a blanket `set -e`: without this, a failed install
# (network blip, lockfile conflict, corrupt node_modules) falls straight through to
# the start command below, and DDEV's crash-loop restart (up to 15 retries) re-attempts
# a doomed start on top of it, burying the real install failure in the same log stream.
yarn --network-concurrency 1 || { echo "theme-watch: dependency install failed" >&2; exit 1; }

# exec, not a bare invocation: replaces this shell with the watcher process so DDEV's
# process supervisor can signal it directly, rather than a wrapper shell that could
# swallow the signal.
exec yarn "$theme_script"
