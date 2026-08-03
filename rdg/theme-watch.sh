#!/usr/bin/env bash
#ddev-generated

# Long-running theme asset watcher, run as a DDEV web_extra_daemon.
#
# Replaces the dedicated node container these projects used to run under
# docker-compose. Deliberately bundler-agnostic: it runs the repo's own
# 'yarn start', so the choice of bundler is the repo's business.

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

yarn --network-concurrency 1

exec yarn start
