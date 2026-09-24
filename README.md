# ddev-rdg

Local DDEV setup shared across the fleet. On an Upsun repo it derives DDEV
configuration from the hosting config, so runtime versions live in exactly one place;
on a repo that is not on Upsun it supplies the parts that are the same everywhere and
leaves `.ddev/config.yaml` to you.

## Three shapes

Which file you edit depends on how — and whether — the repo is hosted on Upsun. The
add-on works this out for itself, from which tracked config files exist.

| | source of truth | `ddev rdg-sync` | `ddev upsun-*-pull` |
|---|---|---|---|
| **fixed** — Upsun Fixed | `.platform.app.yaml` + `.platform/services.yaml` | regenerates `config.platformsh.yaml` | `platform` provider |
| **flex** — Upsun Flex | `.upsun/config.yaml` | regenerates `config.upsun.yaml` | `upsun` provider |
| **native** — everything else | `.ddev/config.yaml`, hand-written | nothing to derive, and says so | refused |

In both derived shapes a `pre-start` guard refuses to start on stale values.

Precedence, when more than one signal is present:

    .ddev/rdg-native  >  .upsun/config.yaml  >  RDG_APP_ROOT  >  .platform.app.yaml

**Flex beats every Fixed signal**, and that ordering is load-bearing rather than
arbitrary. `upsun convert` rewrites the tracked files, but nothing cleans up what was
never tracked: a converted repo keeps `.platform/local/project.yaml` naming the
pre-conversion project, and a repo converted on a branch has `.platform.app.yaml` back
the moment anyone checks out `master`. Deriving from those would pin PHP and database
versions to dead config and point `ddev pull` at a project id that no longer exists —
confidently, and with nothing in the output to say so. Only the tracked
`.upsun/config.yaml` decides; the gitignored link files never do, which is also why a
fresh clone with no `.upsun/local/project.yaml` still resolves correctly.

A repo carrying a `.platform.app.yaml` it does not actually deploy from — an abandoned
Platform.sh evaluation, with no `.platform/local/project.yaml` and an AWS buildspec
instead — should declare itself: `touch .ddev/rdg-native` and commit it. That forces
native mode and beats every other signal, `RDG_APP_ROOT` included.

### Which application, on Flex

A Flex config can declare several applications under `applications:`. With one, it is
used. With several, `ddev rdg-sync` refuses and names them; set `RDG_APP` to choose:

    RDG_APP=drupal ddev rdg-sync

`RDG_APP_ROOT` is its Upsun Fixed counterpart and means nothing on a Flex repo.

In native mode the guard stands aside, `ddev rdg-sync` is a no-op that explains itself,
and both `upsun-*-pull` commands refuse — there is no hosted environment behind the
repo, so `ddev import-db --file=<dump>` is how a database arrives. What a native repo
does get is everything that is identical between repos: `rdg/theme-watch.sh`, the
`corepack_enable` it needs, and `web-build/Dockerfile.rdg-theme-toolchain` for the
asset pipeline's native builds. Only the daemon block itself is yours to declare, as in
[docs/dkr-to-ddev.md](docs/dkr-to-ddev.md#part-3-migrating-a-repo-that-is-not-on-upsun).

**New to DDEV, or migrating a site off `dkr`?** Start with
[docs/dkr-to-ddev.md](docs/dkr-to-ddev.md) — a walkthrough for people who know `dkr`
and nothing about DDEV, covering both daily use and a one-time repo migration. The rest
of this README is reference material for the add-on itself.

## Install

On a **native** repo there is nothing to derive, so the dance below does not apply:

    ddev add-on get Rapid-Development-Group/ddev-rdg
    git add .ddev && git commit
    ddev restart

No `--skip-hooks`, no `ddev rdg-sync`. The rest of this section is for Upsun repos.

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

`git add .ddev` rather than a file list: the generated files
(`config.platformsh.yaml` or `config.upsun.yaml`, `nginx/platform-locations.conf`,
the second only when the repo needs it) and
the add-on's own installed files all belong in the commit. A clone that has
`config.platformsh.yaml` but not `rdg/theme-watch.sh` will crash-loop the theme
daemon. DDEV's own `.ddev/.gitignore` already excludes what should not be tracked.

Note: `ddev add-on remove rdg` deletes the three generated files, but leaves
`.ddev/providers/platform.yaml` behind — removal is gated on DDEV's
generated-marker comment, which that file deliberately does not carry. Delete it
by hand if unwanted.

## Upgrading

**DDEV never updates add-ons on its own.** There is no auto-update and no notification
when a new version exists; an installed add-on stays at whatever version it was
installed from until someone re-runs the install.

    ddev add-on list --installed                       # what you have
    ddev add-on get Rapid-Development-Group/ddev-rdg   # take the latest release
    git add .ddev && git commit
    ddev restart

Three things to expect:

- **`providers/platform.yaml` and `providers/upsun.yaml` are skipped**, loudly: *"NOT
  overwriting … The #ddev-generated signature was not found."* Correct and harmless —
  those files omit the marker on purpose. To take a new version, delete it first and
  re-run.
- **Upgrading does not re-derive.** `config.platformsh.yaml` is only rewritten by
  `ddev rdg-sync`, so run that too when a release changes the derivation. The pre-start
  guard hashes only the *source* files, so it will not catch this for you.
- **Add-on resolution is by GitHub *release*, not tag.** A version tagged but not
  released is invisible; and for the first minute or so after publishing a release,
  `ddev add-on get` can still resolve the previous one. Check with
  `ddev add-on list --installed`, and pin explicitly if needed:

      ddev add-on get Rapid-Development-Group/ddev-rdg --version v1.3.0

## Usage

### Pulling from an Upsun environment

    ddev upsun-db-pull [environment]      # database only
    ddev upsun-files-pull [environment]   # public files only

Sugar for `ddev pull platform --skip-files --environment="PLATFORM_ENVIRONMENT=<env>"`
and its `--skip-db` counterpart, so choosing an environment costs one word instead of
sixty characters.

Named `upsun-*` because that is what the service is called now, whichever plan a
project is on. Both shapes are supported, and the shape decides the provider:

- **Upsun Fixed** — the rebranded Platform.sh: `.platform/`, the `platform` CLI,
  `PLATFORMSH_CLI_TOKEN`, DDEV's `platform` provider.
- **Upsun Flex** — `.upsun/config.yaml`, the `upsun` CLI, DDEV's `upsun` provider.

Neither uses DDEV's stock recipe. Both `providers/platform.yaml` and
`providers/upsun.yaml` are vetted copies with two changes: `files_import_command`
downloads the one public-files mount into `$DDEV_FILES_DIR` rather than every mount
into `/var/www/html` (mount paths are relative to the *app* root, so the stock version
puts public files beside the docroot and drags down `private/` with them), and
`db_push_command` / `files_push_command` are deleted. Both files omit the
`#ddev-generated` marker so DDEV never reverts them.

**One token covers both.** The two CLIs are the same binary under two names, and an
Upsun account's API token authenticates either, so `providers/upsun.yaml` falls back to
`PLATFORMSH_CLI_TOKEN` when `UPSUN_CLI_TOKEN` is unset. Anyone who set the token up once
for a Fixed repo has nothing to do for a Flex one. Set `UPSUN_CLI_TOKEN` only if the two
really are different accounts; it wins when both are present.

Which provider is chosen comes from the tracked hosting config, never from
`.upsun/local/project.yaml` or `.platform/local/project.yaml` — both are gitignored, so
a fresh clone has neither, and a converted repo keeps the *Fixed* one pointing at a
dead project.

With no argument neither command passes `--environment` at all. Whatever the project
pins as `PLATFORM_ENVIRONMENT` in its own `.ddev/config.yaml` applies, and with nothing
pinned the provider asks Upsun for the project's **production environment** — its
default branch, via `platform project:info default_branch`. That is `master` on older
projects and `main` on newer ones, so neither is assumed, and a new repo needs to pin
nothing to pull from production.

This replaces DDEV's stock fallback, the *local* git branch. On a feature branch or a
worktree that pulls an environment which usually does not exist, and when it does exist
and is Inactive, the provider resumes it — a change to remote state nobody asked for.
Pin `PLATFORM_ENVIRONMENT` only when a repo should pull from something other than
production by default.

Each command prints the environment it is about to pull from. DDEV's own confirmation
prompt says only *"You're about to delete the current database and replace with the
results of a fresh pull"* — it never names the environment, so the commands do.

Neither passes `-y`: replacing local data is worth one keypress. Neither takes flags
either — for `--skip-import` and friends, use `ddev pull platform` directly.

**Naming an inactive environment resumes it on Upsun.** The provider's
`auth_command` runs `platform environment:resume` when the environment is not active.
That is a change to remote state, and on a typical project most non-production
environments are Inactive.

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

### Secrets from 1Password

Every `ddev start` resolves the repo's 1Password references into
`.ddev/.env.web.op.local`, which DDEV loads into the web container. That's what
`dkr up` did through `op run`. The references come from the first of these that exists:

- `.ddev/secrets.env`: committed, one `NAME="op://vault/item/field"` per line. Use
  this for any repo without `dkr`.
- `.env`: a dkr-era repo's own file. Only its `op://` lines are used, so dkr's
  `DB_HOST` and `*_TAG` values never reach the container.

A repo with neither gets no 1Password step at all, and `op` is never called.

**It never blocks the start.** If `op` is missing, signed out or offline, the start
prints a warning and keeps going: with the last good file if there is one, with no
secrets if not. `ddev op-secrets` is the strict version, useful for refreshing without
a restart or for seeing the full error:

    ddev op-secrets && ddev restart

Signing in is the 1Password app's CLI integration (Settings → Developer), so a start
costs one Touch ID prompt per terminal session.

**Why a file and not memory, the way `dkr` did it.** A hook runs as a child of
`ddev`, so it can't set variables in the process that later runs `docker compose up`.
Wrapping `op run -- ddev start` would miss every other way DDEV recreates the
containers, such as `ddev restart`, `ddev start -a` or an add-on install, and each of
those would bring the site up with its secrets silently empty. The file is mode 600,
written atomically, gitignored by DDEV (the `.local` suffix), and deleted when the
add-on is removed. With `dkr` the values sat in the container's config, readable
through `docker inspect`, and that is still true here.

Values are written out escaped for DDEV's dotenv parser, so a `$`, a quote or a
multi-line PEM key arrives exactly as stored. `op inject`'s output would pass them
through raw instead. To keep AI agents from reading the file, add a deny rule to the
repo's `.claude/settings.json`: `"permissions": {"deny": ["Read(./.ddev/.env.web.op.local)"]}`.
That covers the file tools but not a shell `cat`, so treat it as a guard rail, not a
wall.

### Running several checkouts of one repo at once

A worktree per branch, or two clones side by side, each up in the browser at the same
time. **Omit `name:` from `.ddev/config.yaml`** and DDEV names the project after the
enclosing directory, which is the only thing that has to differ:

    git worktree add ../rdg2020-vite vite
    cd ../rdg2020-vite && ddev start        # https://rdg2020-vite.ddev.site

The name is not cosmetic. It builds the container names, the hostname, and the database
volume (`<project>-mariadb`), so two directories sharing one name share one database and
whichever started last owns it. DDEV refuses that outright — *"Project 'x' was found in
configured directory … and it is already used by project 'x'"* — which is why a repo that
pins `name:` can only ever be checked out once.

Nothing else needs changing. Every port goes through the one shared `ddev-router` and is
routed by `Host`, the derived theme dev-server on 35728/35729 included, so the checkouts
do not contend for ports. Mailpit follows the project name, so each gets its own
`https://mailpit.<project>.ddev.site`.

Keep the directory name to lowercase letters, digits and hyphens, and slug a branch
that is not:

    git worktree add ../rdg2020-op-500 OP-500-rdg-theme

DDEV will not stop you if you do not — v1.25.4 accepted `Bad.Name` even from
`--project-name` — but the name becomes a hostname, and a dot in it makes
`<name>.ddev.site` three labels, which the `*.ddev.site` wildcard certificate does not
cover. Capitals do work, awkwardly: DDEV lowercases them in the hostname and keeps them
in the container and volume names.

A branch-derived name is deliberately *not* what this does. It would rename the project
on every `git checkout` in the primary checkout, orphaning that branch's containers and
volume and handing you an empty database under a new name. The directory is the stable
discriminator; with the command above the branch rides along in it anyway.

Two things do not come with a new checkout, both because they are gitignored:

- **The database.** A new name gets a new, empty volume. Either pull again, or hop:

      ddev -d ~/Sites/rdg2020 export-db --file=/tmp/db.sql.gz
      ddev -d ~/Sites/rdg2020-vite import-db --file=/tmp/db.sql.gz

- **The Upsun link file** — `.platform/local/project.yaml`, or `.upsun/local/project.yaml`
  on Flex. Without it `ddev upsun-db-pull` has no project id to resolve and fails saying
  nothing about worktrees. Copy the directory across once:

      cp -r ~/Sites/rdg2020/.platform/local ~/Sites/rdg2020-vite/.platform/

## Mailpit on a hostname

Installing the add-on puts Mailpit's UI at `https://mailpit.<project>.ddev.site`, in
both modes, without the repo doing anything.

DDEV serves it on `mailpit_http_port` / `mailpit_https_port` against the *bare* project
hostname — and there is one `ddev-router` for every project on the machine, so the
default 8025/8026 belongs to whichever project started first. With several projects up,
which is the point of moving off `dkr`, you read another project's mail and nothing says
so. A hostname is per-project by construction.

Two generated files, neither carrying `#ddev-generated` (DDEV regenerates
`traefik/config/` and would take the router with it):

| | |
|---|---|
| `.ddev/traefik/config/mailpit.yaml` | one router on the https entrypoint pointing at the web container's port 8025, with `priority: 100` so it outranks the router DDEV generates for the same hostname — that one points at port 80, i.e. at the application |
| `.ddev/config.mailpit.yaml` | `additional_hostnames`, which is what gets the name into the **mkcert certificate**. The cert's `*.ddev.site` wildcard matches a single label, so it does not cover a subdomain of the project host; without this the name resolves and then fails TLS |

**SMTP is untouched** — the app still sends to `localhost:1025` inside the web container,
and the port-based URL keeps working.

Both embed the project name, so `ddev rdg-sync` rewrites them every run and a rename
self-heals. On a native repo, re-run `ddev add-on get` after a rename. The name comes
from `config.yaml` when it declares one and from the enclosing directory when it does
not — the same two places DDEV takes it from, so a checkout that omits `name:` to
[run alongside its siblings](#running-several-checkouts-of-one-repo-at-once) still gets
its own Mailpit. A name that is not a DNS label is declined out loud and Mailpit keeps
its port-based URL — DDEV does not refuse such a project, so this is the only thing that
says anything. A name carrying capitals is served: the hostname is lowercased and the
container name is not, matching what DDEV does for the project's own routers.

## What it derives

`php_version`, `nodejs_version`, `database`, `docroot`, `composer_root`, the theme
asset daemon, the dev-server port, the build toolchain, and nginx snippets for
`web.locations` outside the docroot.

The theme daemon runs a script the repo declares, so the bundler is never named here:
`dev` if `package.json` has one, `start` otherwise, and the chosen name goes into the
generated `command:` so it is visible without opening `package.json`. Neither means no
daemon, said out loud rather than silently.

The dev-server port is `5173` when the theme builds with Vite and `35729` otherwise.
Vite counts whether it is a declared dependency **or** just named in the script being
run — a theme that gets it through a wrapper package (`rdg-vite` is ours) lists no
`vite` of its own, and reading only the dependency list hands that repo `35729` while
its dev server listens on `5173`.

One exception in that last item: a location declaring `scripts: true` is a PHP entry
point, which needs `fastcgi_pass` and a `SCRIPT_FILENAME` rather than the static
`try_files` block this generates. Those are skipped and named on stderr — write them by
hand in `.ddev/nginx/*.conf`, which is the hook DDEV does not regenerate.

### Redis

If the app relates a Redis service and the [`ddev-redis`](https://github.com/ddev/ddev-redis)
add-on is installed, `ddev rdg-sync` also writes `.ddev/.env.redis` pinning
`REDIS_DOCKER_IMAGE` to the version the repo's services config declares —
`.platform/services.yaml` on Fixed, the `services:` block of `.upsun/config.yaml` on
Flex.

This is a second output file rather than another key in `config.platformsh.yaml`,
because DDEV has no Redis version setting — the add-on reads that variable out of a
dotenv file which docker-compose interpolates.

It is worth deriving rather than leaving to the add-on's default. That default is a
floating `redis:7`, and an unpinned major floats to whatever the newest minor is —
`redis:8` resolved to 8.10 while the hosted service ran 8.0.6. Two Redis minors apart
is not a difference worth meeting in production.

Two things to know:

- **Changing the version needs the cache volume dropped**, at least downwards. Redis
  writes its snapshot in a version-specific format and an older server refuses a newer
  one (`Can't handle RDB format version 15`). It is a cache, so
  `ddev stop && docker volume rm ddev-<project>_redis && ddev start`.
- **`ddev redis-backend` and this command both own that file.** Switching backend by
  hand — to Valkey, say — is overwritten on the next sync. Change the service version in
  the services config instead; that is the source of truth, and a `valkey:` service type
  derives to the Valkey image on its own.

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
    for f in flex-subdir flex-stale-fixed; do
      bash rdg/derive.sh "tests/fixtures/$f" 2>/dev/null \
        > "tests/expected/$f.config.upsun.yaml"
    done
    bash rdg/nginx-locations.sh \
      tests/fixtures/composable-subdir/drupal/.platform.app.yaml drupal/web \
      > tests/expected/composable-subdir.platform-locations.conf
    bash rdg/nginx-locations.sh \
      tests/fixtures/flex-subdir/.upsun/config.yaml drupal/web drupal 2>/dev/null \
      > tests/expected/flex-subdir.platform-locations.conf

`flex-stale-fixed` is the one fixture worth understanding before editing: it is a Flex
repo carrying leftover Fixed files whose every value differs from the Flex one, so a
derivation that reads the wrong file fails the golden diff instead of passing by
coincidence.

`tests/rdg-sync.bats` drives `commands/host/rdg-sync` with a stub `ddev` on
`PATH`, so it needs no running project.
