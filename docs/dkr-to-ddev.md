# Moving from `dkr` to DDEV

For anyone who has used `dkr` and has never used DDEV. It assumes nothing about either
beyond "I type `dkr up` and the site comes up".

Three parts, and you probably want only one:

- **[Part 1: using a repo that already has DDEV](#part-1-using-a-repo-that-already-has-ddev)** —
  you cloned a site, it has a `.ddev/` directory, you want it running.
- **[Part 2: migrating an Upsun repo](#part-2-migrating-an-upsun-repo)** — once per
  site, by whoever does the migration.
- **[Part 3: migrating a repo that is not on Upsun](#part-3-migrating-a-repo-that-is-not-on-upsun)** —
  same job, different half of the fleet.

## Which kind of repo is this?

Parts 2 and 3 differ in one thing only — **which file is the source of truth** — and
everything else follows from it. Check for a `.platform.app.yaml`, at the repo root or
one directory below it:

| | hosted on | source of truth | `ddev rdg-sync` | `ddev upsun-db-pull` |
|---|---|---|---|---|
| **derived** | Upsun Fixed | `.platform.app.yaml` | regenerates DDEV config from it | works |
| **native** | anything else (AWS, a VPS…) | `.ddev/config.yaml`, hand-written | nothing to derive, and says so | refuses; use `ddev import-db` |

The add-on works this out for itself; nothing declares it. If you are ever unsure, run
`ddev rdg-sync` — on a native repo it tells you so and changes nothing.

## What DDEV is, and why

[DDEV](https://ddev.readthedocs.io/) does the same job `dkr` did: it runs a site's
containers on your machine — nginx, PHP, MariaDB, Redis, a mail catcher, the theme asset
watcher. The difference is ownership. `dkr` was a bash wrapper we wrote around a
`docker-compose.yml` we wrote, so every bug was ours. DDEV is a maintained tool a large
part of the Drupal world uses, so most problems are already somebody else's solved
problem.

Everything site-specific lives in the repo's `.ddev/` directory, which is committed. A
clone is expected to start correctly with no local setup beyond installing DDEV itself.

**`dkr` still works.** Nothing here is a forced cutover, and the two can coexist in the
same repo — see [Running both side by side](#running-both-side-by-side).

---

# Part 1: using a repo that already has DDEV

## First-time setup

You already have Docker Desktop, because `dkr` needed it. Steps 1–3 are once per machine,
ever. Steps 4–7 are once per repo.

**1. Stop `dkr` if it is running for this repo.**

```sh
dkr down
```

Both stacks can be *installed* at once, but only one can *run* at a time: the `dkr`
compose file binds fixed host ports — 8000, 4306, 6379, 35729 — and DDEV wants 35729 for
livereload too.

**2. Install DDEV.**

```sh
brew install ddev/ddev/ddev     # the add-on needs >= 1.24.8
mkcert -install                 # once, ever — makes local https trusted by your browser
```

`mkcert` arrives as a dependency of the DDEV formula, so there is nothing extra to
install. Skipping `mkcert -install` is not fatal, but every page load carries a
certificate warning.

**3. Add your Upsun API token**, so pulling the production database works:

```sh
ddev config global --web-environment-add="PLATFORMSH_CLI_TOKEN=<your token>"
```

This writes to `~/.ddev/global_config.yaml` — outside the repo on purpose, because it is
a credential. Note the variable is still `PLATFORMSH_CLI_TOKEN` on an Upsun **Fixed**
project; see [Fixed vs Flex](#upsun-fixed-vs-upsun-flex). Skip this step if you never
pull.

**4. Start the project**, from anywhere inside the repo — DDEV finds `.ddev/` by walking
up from your current directory:

```sh
ddev start
```

The first run downloads container images and takes a few minutes. There is nothing to
configure first.

**5. Install PHP dependencies.**

```sh
ddev composer install
```

`ddev composer` runs inside the container against the project's PHP version, and already
knows which subdirectory holds `composer.json`. You do not `cd` anywhere.

**6. Get a database and files.**

```sh
ddev pull platform
```

Production database plus the public files directory; slow the first time. Afterwards use
[`ddev upsun-db-pull`](#pulling-from-upsun), which is faster and can name an environment.

**7. Open the site.**

```sh
ddev launch          # opens the URL
ddev drush uli       # one-time login link for user 1
```

The URL is `https://<project>.ddev.site`, where `<project>` is the `name` in
`.ddev/config.yaml` — not `docker.localhost:8000`. `ddev describe` prints it if you are
unsure. DDEV routes by hostname, so **several projects can run at once** and nothing has
to be stopped first. `*.ddev.site` resolves to 127.0.0.1 in public DNS, so with
`use_dns_when_possible: true` there is normally no `/etc/hosts` edit and no password
prompt; offline, DDEV falls back to `/etc/hosts` and will ask.

## Did it work?

```sh
ddev describe                                          # every service OK/healthy
ddev exec supervisorctl status webextradaemons:theme    # RUNNING
```

`ddev describe` also prints the database connection details for a GUI client.

## Day-to-day

```sh
ddev start / ddev stop / ddev restart
ddev drush …             ddev composer …
ddev ssh                 # shell in the web container
ddev logs -s web -f      # includes theme compile output
ddev sequelace           # open the database in Sequel Ace (or: ddev tableplus)
ddev mailpit             # captured outgoing mail
ddev upsun-db-pull       # refresh the database (optionally: <environment>)
ddev upsun-files-pull    # refresh the public files
ddev poweroff            # stop every DDEV project and its router
```

The two `upsun-*` commands are **Upsun-only**. On a native repo they refuse and point
you at `ddev import-db --file=<dump.sql.gz>`, which is how a database arrives when there
is no hosted environment to pull from.

There is **no separate theme build step**. `ddev start` runs the asset watcher as a
daemon, which installs dependencies and does a full compile before it begins watching —
which is why the first `ddev start` after a clone takes longer than later ones.

## `dkr` → DDEV

| `dkr` | DDEV |
|---|---|
| `dkr up` / `down` / `cycle` | `ddev start` / `stop` / `restart` |
| `dkr bash [svc]` | `ddev ssh [-s svc]` |
| `dkr drush …` / `composer …` | `ddev drush …` / `ddev composer …` |
| `dkr logs [svc]` | `ddev logs -f [-s svc]` |
| `dkr ps` / `stats` | `ddev list` / `ddev debug …` |
| `dkr uli` | `ddev drush uli` (prints a launchable URL) |
| `dkr open` | `ddev launch` |
| `dkr db` | `ddev sequelace` or `ddev tableplus` |
| `dkr platform-db-pull [env]` | `ddev upsun-db-pull [env]` — Upsun repos; else `ddev import-db --file=…` |
| (no equivalent) | `ddev upsun-files-pull [env]` — Upsun repos only |
| `dkr clean` | `ddev poweroff` |
| `dkr grf` | `git checkout -- <files>` |

`ddev sequelace` and `ddev tableplus` ship with DDEV itself and only appear in `ddev -h`
when the app is actually in `/Applications` — so a teammate without Sequel Ace sees no
such command rather than an error. The database is named **`db`**, not after the project;
credentials are `db` / `db`, and `root` / `root` also works. The host port is random and
changes on restart, so run the command rather than saving a favourite.

## Two things that will trip you up

**`ddev start` sometimes refuses to start and tells you to run `ddev rdg-sync`.** That is
working as designed: someone edited `.platform.app.yaml` and the derived DDEV config no
longer matches it. Do what the message says. See
[the staleness guard](#the-staleness-guard). This cannot happen on a native repo —
there is no upstream to drift from, so the guard stands aside.

**Do not run `ddev add-on get` in a repo that already has the add-on committed.** Its
files and its generated config are tracked, which is what makes a clone correct on first
start. Running it again tries to overwrite `.ddev/providers/platform.yaml`, which DDEV
refuses because that file deliberately carries no generated-marker — a confusing warning
for no gain. You need `ddev add-on get` only when *adopting* the add-on into a new repo,
or when [upgrading](#upgrading-the-add-on) it.

## The theme watcher

Under `dkr`, a second container (`node:16`) existed only to run `yarn docker-start` —
`yarn install`, then a bundler in watch mode — with livereload published on 35729.

DDEV does the same work inside the web container via `web_extra_daemons`, so there is no
second container. The daemon is named `theme`, not `webpack`: it runs the repo's own
`yarn start`, so swapping bundlers needs no change here.

```sh
ddev exec supervisorctl status webextradaemons:theme
ddev logs -s web -f            # compile output
```

Livereload is exposed at `https://<project>.ddev.site:35729`. The LiveReload browser
extension defaults to the page's own host and port 35729, so it needs no configuration —
where under `dkr` it had to point at `localhost:35729`.

Two details carried over from the old compose service, both in `.ddev/rdg/theme-watch.sh`:

- **`CHOKIDAR_USEPOLLING=1`.** The project is a mounted filesystem, so a bundler's watcher
  gets no inotify events for host-side edits. Polling makes a host `.scss` edit show up in
  the compiled CSS within a few seconds.
- **`CPPFLAGS=-DPNG_ARM_NEON_OPT=0`.** On Apple silicon, `imagemin`'s three native
  binaries have x86_64-only prebuilts and compile from source, and `optipng-bin`'s bundled
  libpng then fails to link on aarch64 without this. Without it `yarn install` exits
  non-zero. The old compose file set the same flag.

## Pulling from Upsun

```sh
ddev upsun-db-pull                 # database, from the environment the repo pins
ddev upsun-db-pull staging         # database, from a named environment
ddev upsun-files-pull              # public files
ddev upsun-files-pull staging
```

These exist for one reason: `dkr platform-db-pull` took the environment as a positional
argument, and DDEV's equivalent is
`ddev pull platform --skip-files -y --environment="PLATFORM_ENVIRONMENT=staging"`. Nobody
types that. `dkr` was database-only, which is why files are a separate verb rather than a
flag.

With no argument neither command passes `--environment` at all, so whatever the repo pins
in its own `.ddev/config.yaml` applies.

Three things worth knowing:

- **Naming an inactive environment resumes it on Upsun.** The provider runs
  `environment:resume` when an environment is not active, and on a typical project only
  production is Active. That is a change to remote state, which `dkr` never made. Both
  commands warn before handing off.
- **DDEV's confirmation prompt does not name the environment.** It says only *"You're
  about to delete the current database and replace with the results of a fresh pull."*
  That is why these commands print the environment themselves. Neither passes `-y`.
- **`ddev pull` starts a stopped project first**, so neither command needs the project up.

Neither takes any other flag. For `--skip-import` or a multi-variable override, use
`ddev pull platform` directly — it is still the underlying mechanism.

**There is no `ddev push`.** The two push commands are deleted from the provider recipe on
purpose. DDEV's stock recipe derives the environment from your current git branch, which
is never a real environment name locally, so a stray `ddev push` fails safe — but a repo
that pins `PLATFORM_ENVIRONMENT` for pulling turns "fails safe" into "targets
production". `dkr` had no push verb, so keeping them would have added a
production-overwriting capability by accident.

### Upsun Fixed vs Upsun Flex

The commands are named for Upsun because that is what the service is called now. The DDEV
provider they invoke is `platform`, and that is correct rather than leftover:

- **Upsun Fixed** is the rebranded Platform.sh — a `.platform/` directory, the `platform`
  CLI, `PLATFORMSH_CLI_TOKEN`, `.platform.app.yaml` + `.platform/services.yaml`. This is
  what the fleet is on, and what the add-on supports.
- **Upsun Flex** is a different shape — one `.upsun/config.yaml` with top-level
  `applications:` / `services:` / `routes:`, the `upsun` CLI, `UPSUN_CLI_TOKEN`.

On a Flex project the commands **refuse** rather than fall through to `ddev pull upsun`.
That is deliberate: DDEV's stock `upsun` recipe downloads every mount to
`/var/www/html` — public files beside the docroot instead of inside it — and still ships
both push commands. Flex support would need a vetted `providers/upsun.yaml` here and a
second config reader in `rdg/derive.sh`.

## What the add-on actually does

`.ddev/config.yaml` used to restate every runtime value that `.platform.app.yaml` already
declared. It no longer does. `ddev rdg-sync` reads `.platform.app.yaml`,
`.platform/services.yaml` and the theme's `package.json`, and writes three files:

| Generated file | What it carries |
|---|---|
| `.ddev/config.platformsh.yaml` | `php_version`, `nodejs_version`, `database`, `docroot`, `composer_root`, the theme daemon and its ports |
| `.ddev/nginx/platform-locations.conf` | one `location ^~` block per `web.locations` entry outside the docroot |
| `.ddev/web-build/Dockerfile.rdg-theme` | the native-build toolchain the asset pipeline needs |

So **bumping a PHP version is a one-file edit to `.platform.app.yaml`**, and hosting
config cannot drift from local config. All three generated files are committed
deliberately: a colleague pulling a branch that changes `.platform.app.yaml` gets the
matching DDEV config in the same commit.

The nginx snippet is why static pages served from outside the docroot — landing pages and
similar `web.locations` entries — work locally at all. DDEV knows nothing about them
otherwise, and they fall through to Drupal.

After editing `.platform.app.yaml`:

```sh
ddev rdg-sync
git add .ddev
ddev restart          # nothing derived applies until the next start
```

`ddev rdg-sync` also reports what it deliberately does *not* translate — crons, mounts,
build and deploy hooks — so the gap is visible rather than silent.

### The staleness guard

A `pre-start` hook re-hashes the source files and compares them against a digest recorded
in the generated config. If they differ, `ddev start` **aborts** rather than starting on
stale values. A pre-start hook runs after DDEV has parsed its config, so anything the hook
wrote would only take effect next time — failing loudly is the honest behaviour.

Two recovery paths, both printed by the guard:

```sh
ddev rdg-sync && ddev start                                # project already running

ddev start --skip-hooks && ddev rdg-sync && ddev restart    # project is down
```

The second exists because `ddev rdg-sync` shells into the web container, so it needs the
project up — and the guard is what stopped it coming up.

### Upgrading the add-on

**DDEV never updates add-ons on its own.** No auto-update, no notification. An installed
add-on stays put until someone re-runs the install.

```sh
ddev add-on list --installed                       # what this repo has
ddev add-on get Rapid-Development-Group/ddev-rdg   # take the latest release
git add .ddev && git commit
ddev restart
```

Four things to expect:

- **`providers/platform.yaml` is skipped**, loudly: *"NOT overwriting … The
  #ddev-generated signature was not found."* Correct and harmless — it omits the marker on
  purpose so DDEV never reverts our recipe. To take a new version of that file, delete it
  first, then re-run.
- **Upgrading does not re-derive.** `config.platformsh.yaml` is only ever rewritten by
  `ddev rdg-sync`, so run that too when a release changes the derivation. The guard hashes
  only the *source* files, so it will not catch this for you.
- **Resolution is by GitHub *release*, not tag.** A tagged-but-unreleased version is
  invisible, and for a minute or so after publishing a release `ddev add-on get` can still
  resolve the previous one. Confirm with `ddev add-on list --installed`; pin with
  `--version vX.Y.Z` if needed.
- **Renamed files are not removed.** If a release renames a command, delete the old file
  by hand or both names appear in `ddev -h`.

## Running both side by side

`dkr` and DDEV can live in the same repo indefinitely. Keep `docker-compose.yml`, `.env`
and the `Brewfile`, and the team migrates at its own pace.

Only one can *run* at a time, because the `dkr` compose file binds fixed host ports. Stop
one before starting the other.

For this to work, `settings.php` must recognise both environments — see
[step 3 of Part 2](#3-teach-settingsphp-about-ddev). Retiring `dkr` for a repo means
deleting `docker-compose.yml` and `.env`.

---

# Part 2: migrating an Upsun repo

Once per site. Assumes the repo is an Upsun Fixed project with `.platform.app.yaml` at the
repo root or one level below it. If it has no such file, skip to
[Part 3](#part-3-migrating-a-repo-that-is-not-on-upsun).

## 1. Install the add-on

```sh
ddev config --project-type=drupal11 --project-name=<name>
ddev add-on get Rapid-Development-Group/ddev-rdg
ddev start --skip-hooks     # see below: plain 'ddev start' cannot work yet
ddev rdg-sync
git add .ddev && git commit
ddev restart                # nothing derived applies until this
```

`--skip-hooks` is needed **exactly once**. The add-on installs the pre-start guard, which
aborts while the generated config is missing — and `ddev rdg-sync` needs the project up,
because it shells into the web container. The guard would otherwise block the only command
that can satisfy it. After the first sync, `ddev start` works normally.

`git add .ddev` rather than a file list: the generated files *and* the add-on's own
installed files all belong in the commit. A clone that has `config.platformsh.yaml` but
not `rdg/theme-watch.sh` will crash-loop the theme daemon.

## 2. Write a minimal `.ddev/config.yaml`

Do not restate anything the add-on derives — no `php_version`, `nodejs_version`,
`docroot`, `composer_root`, or `database`. What belongs here is only what is *not* a fact
about the hosting config:

```yaml
name: <project>
type: drupal11

# For pulling. PLATFORM_PROJECT is deliberately absent -- see below.
web_environment:
    - PLATFORM_ENVIRONMENT=master
    - PLATFORM_APP=<app name from .platform.app.yaml>

webserver_type: nginx-fpm     # the generated nginx snippet is nginx syntax
xdebug_enabled: false
use_dns_when_possible: true
composer_version: "2"
ddev_version_constraint: ">= 1.24.8"
```

**Do not set `PLATFORM_PROJECT`.** Drupal's `settings.php` typically gates
`settings.platformsh.php` on it, so setting it locally loads the hosted settings, which
expect a `PLATFORM_RELATIONSHIPS` blob that does not exist on your machine. Pulling
derives the project ID from `.platform/local/project.yaml` instead, so it is not needed.

**`PLATFORM_ENVIRONMENT`** is worth pinning: the provider otherwise guesses the
environment from your current git branch, which is never a real environment name locally.

## 3. Teach `settings.php` about DDEV

Local dev overrides are usually gated on `getenv('DOCKER')`, which only `dkr` sets:

```php
$on_local = getenv('DOCKER') || getenv('IS_DDEV_PROJECT');
```

Both, not either — that is what lets `dkr` and DDEV coexist. Without it you lose verbose
errors, disabled CSS/JS aggregation, and `skip_permissions_hardening` under DDEV. On
rdg2020 this was the **only** tracked application file the migration had to touch.

## 4. Add Redis, if the site requires it

```sh
ddev add-on get ddev/ddev-redis
```

If `settings.php` unconditionally sets `cache.backend.redis` and a
`bootstrap_container_definition`, Redis is not optional locally — without it the site
cannot bootstrap at all. The add-on appends an include that overrides the host correctly.
Production Redis versions are old enough that pinning to match is not worth it.

## 5. Gitignore what the tooling now generates

```gitignore
/web/node_modules/
/web/.gitignore
```

DDEV maintains its own `.ddev/.gitignore` for the files it generates, so `git add .ddev`
is safe.

## 6. Verify, then leave `dkr` in place

```sh
ddev start
ddev composer install
ddev pull platform
ddev launch
```

Check the theme daemon is `RUNNING`, that any static landing pages resolve, and that a
`.scss` edit reaches the compiled CSS. Then **stop** — leave `docker-compose.yml`, `.env`
and the `Brewfile` alone so the rest of the team can migrate when they choose, and so the
two environments can be compared directly.

## Things that will not translate

`ddev rdg-sync` lists these every run rather than guessing:

- **Crons.** DDEV has no cron. Run `ddev drush core-cron` when you need it.
- **Mounts, workers, build and deploy hooks.** No local equivalent is generated.
- **Working directory.** On Upsun, `/app` is the *app* directory, so hooks say
  `cd web && drush …`. In DDEV, `/var/www/html` is the *repo* root, so the equivalent is
  `ddev exec -d /var/www/html/<app>/web …`. `ddev drush` and `ddev composer` already
  resolve correctly and need no `-d`.

## Why not `ddev/ddev-upsun`

DDEV's own add-on is supposed to do this job, and on a simple repo it does. It was
installed, tested, and removed here for three reasons, any one of which is fatal:

1. **The app config is not at the repo root.** Its detector only looks at
   `<repo root>/.platform.app.yaml`. Moving the file would change the app root on the
   hosting side, which is a production change.
2. **`composable:` runtimes are unsupported.** It reads a PHP version only from a
   `php:`-prefixed `type`, so a `composable:` type with `stack.runtimes` derives nothing
   at all. Node fails the same way.
3. **`docroot` comes out wrong regardless**, because it returns `web.locations."/".root`
   verbatim on the assumption that app root and repo root are the same directory.

It also sets `disable_settings_management: true` and deletes `settings.ddev.php`, assuming
`settings.platformsh.php` runs locally off generated `PLATFORM_*` variables. Where
`settings.php` gates that on `PLATFORM_PROJECT`, DDEV's own settings management works
fine, so that trade is a loss too.

`ddev-rdg` handles all three cases and leaves settings management alone.

---

# Part 3: migrating a repo that is not on Upsun

Once per site, for a repo with no `.platform.app.yaml` — hosted on AWS, a VPS, anywhere.
Same destination as Part 2, reached differently: **you write `.ddev/config.yaml` by
hand, and it is the source of truth.** Nothing derives it, so nothing can overwrite it.

You read `docker-compose.yml` and `.env` exactly once, here, while writing that file.
After that they are dead weight, which is the point — the end state deletes them.

## 1. Install the add-on

```sh
ddev config --project-type=drupal10 --project-name=<name> --docroot=<path/to/docroot>
ddev add-on get Rapid-Development-Group/ddev-rdg
```

No `--skip-hooks` and no `ddev rdg-sync`: both exist to satisfy a staleness guard that
has nothing to guard here. What the add-on is actually for on a native repo is
`.ddev/rdg/theme-watch.sh` and the `corepack_enable` that script depends on.

It also installs `providers/platform.yaml` and the two `upsun-*-pull` commands, which
are inert. They refuse by name rather than failing obscurely, so nobody has to wonder
whether they were meant to work.

## 2. Translate the compose file

Every service in a `dkr` stack is either built into DDEV or an official add-on. Nothing
here needs a custom `docker-compose.*.yaml`:

| `dkr` compose service | DDEV |
|---|---|
| `nginx` + `php` (wodby) | the built-in web container — `php_version`, `webserver_type` |
| `traefik`, `PROJECT_BASE_URL=docker.localhost:8000` | the built-in router — `https://<project>.ddev.site` |
| `mariadb` | the built-in `db` container — `database:` |
| `mailhog` / `mailpit` | built in — `ddev mailpit` |
| `redis` | `ddev add-on get ddev/ddev-redis` |
| `solr` | `ddev add-on get ddev/ddev-drupal-solr` |
| `minio` | `ddev add-on get ddev/ddev-minio` |
| `chrome` / chromedriver | `ddev add-on get ddev/ddev-selenium-standalone-chrome` |
| `webpack` / `theme` node container | `web_extra_daemons` — see step 4 |

Read versions off the wodby image tags in `.env`. `PHP_TAG=8.1-dev-4.61.2` means
`php_version: "8.1"`; `MARIADB_TAG=10.5-3.12.5` means MariaDB 10.5. The docroot is the
`NGINX_SERVER_ROOT` combined with whatever the compose file mounts at
`/var/www/html` — `./drupal/:/var/www/html` plus `NGINX_SERVER_ROOT: /var/www/html/web`
gives `docroot: drupal/web` and `composer_root: drupal`.

## 3. Write `.ddev/config.yaml`

```yaml
name: <project>
type: drupal10
docroot: drupal/web           # from the mount + NGINX_SERVER_ROOT
composer_root: drupal         # where composer.json actually lives
php_version: "8.1"            # from PHP_TAG
nodejs_version: "14"          # from the node image tag
database:
    type: mariadb
    version: "10.5"           # from MARIADB_TAG
webserver_type: nginx-fpm
corepack_enable: true         # the theme daemon runs yarn; this provides it
use_dns_when_possible: true

# Only what the app genuinely needs. DDEV supplies its own database credentials,
# so do not copy the DB_* block over wholesale -- see step 5.
web_environment:
    - S3_FOLDER=dev-public.example.com
```

Unlike Part 2 there is no "do not restate what the add-on derives" rule, because nothing
is derived. Everything the site needs goes in this file.

Two things about editing it:

- **`ddev config <flags>` rewrites this file and strips every comment.** Use it to
  create the file, then edit by hand. The annotations explaining where a value came from
  are the most useful thing in it, and they are silently lost otherwise.
- **Changing `database:` after the project has started fails**, because a volume already
  exists at the old version: *"the configured database type does not match the current
  actual database"*. Get the version right before the first start, or
  `ddev stop --remove-data --omit-snapshot` — which destroys the local database, so
  export first if it holds anything.

## 4. The theme watcher

Under `dkr` this was a second container running `yarn docker-start`. In DDEV it is a
daemon inside the web container, and it runs the same shipped script the Upsun repos
use:

```yaml
web_extra_daemons:
    - name: theme
      command: "bash /var/www/html/.ddev/rdg/theme-watch.sh"
      directory: /var/www/html/drupal/web
web_extra_exposed_ports:
    - name: livereload
      container_port: 35729
      http_port: 35728
      https_port: 35729
```

`theme-watch.sh` already does `yarn --network-concurrency 1` and then `exec yarn start`,
which is exactly what a `docker-start` script does — so repos with one need no change to
`package.json`. It also carries the two fixes that container needed: polling (a mounted
filesystem produces no inotify events) and the `arm64` libpng build flag. See
[The theme watcher](#the-theme-watcher).

**You almost certainly also need a build toolchain.** `imagemin`'s binary dependencies
(`gifsicle`, `optipng`, `mozjpeg`) ship x86_64-only prebuilts, so on Apple silicon yarn
compiles them from source — and fails without the tools to do it. The symptom is the
daemon crash-looping on `theme-watch: dependency install failed`, preceded a few lines
earlier by the real cause, `Command failed: …/gifsicle/vendor/gifsicle --version`.

On Upsun repos `ddev rdg-sync` writes this file for you. Native repos maintain it by
hand — `.ddev/web-build/Dockerfile.<something>`, since DDEV reads every
`web-build/Dockerfile.*`:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf automake libtool dh-autoreconf make pkg-config zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*
```

Adding it needs a `ddev restart`, and a stale `node_modules` from the failed installs is
worth deleting first.

## 5. Teach `settings.php` about DDEV

The Part 2 change applies unchanged — local overrides gated on `getenv('DOCKER')` need
to accept DDEV too, and both, so `dkr` keeps working:

```php
$on_local = getenv('DOCKER') || getenv('IS_DDEV_PROJECT');
```

Then two traps specific to native repos.

**The dkr-era `DB_*` variables.** `dkr` set `DB_HOST`, `DB_NAME`, `DB_USER` and
`DB_PASSWORD` in the compose environment, and dkr-era settings read them directly —
sometimes unconditionally, as `$_SERVER['DB_HOST']`. DDEV sets none of them, so that is
a PHP warning on every request before the site even reaches a database. Declare them in
`web_environment` and the existing code keeps working, with one path for both tools:

```yaml
web_environment:
    - DB_HOST=db
    - DB_USER=db
    - DB_PASSWORD=db
```

`web_environment` does reach `$_SERVER` under nginx-fpm, not only `getenv()` — verified
on DDEV 1.25.3 — so a settings file reading either style needs no change.

**`settings.ddev.php` wins over anything the repo sets.** DDEV appends its include to
the *end* of `settings.php`, so it runs after every settings file the repo includes and
overrides `$databases['default']['default']` with its own — database `db`, user `db`.
A repo that names its local database something else will find that name quietly ignored.

Let DDEV win. Its tooling — `ddev mysql`, `ddev sequelace`, `ddev export-db`, snapshots —
all assume the database is called `db`, and fighting that costs more than it returns.
What matters is that the repo's settings files not *claim* otherwise:

```php
// The default connection is dkr's only. Under DDEV it comes from settings.ddev.php,
// which settings.php includes after this file and which therefore wins.
if (!getenv('IS_DDEV_PROJECT')) {
  $databases['default']['default']['database'] = getenv('DB_NAME') . '_us';
}
```

Additional connections (a migration source, a second country) are untouched by
`settings.ddev.php` and keep working as they are, once their host stops assuming one
container per database.

## 6. Getting a database

There is no pull provider, so no `ddev upsun-db-pull`:

```sh
ddev import-db --file=<dump.sql.gz>
```

Source the dump however the repo already documents it — most of these sites have a
nightly backup on S3. Check the repo's own README before inventing a process.

## 7. Verify, then leave `dkr` in place

```sh
ddev start
ddev composer install
ddev import-db --file=<dump.sql.gz>
ddev launch
```

Check the theme daemon is `RUNNING` (`ddev exec supervisorctl status
webextradaemons:theme`) and that a `.scss` edit reaches the compiled CSS. Then **stop** —
leave `docker-compose.yml`, `.env` and the `Brewfile` alone until the team has moved, so
the two can be compared directly.

## Two things worth checking for before you start

Neither is universal, but both are silent when got wrong.

**More than one database.** Some of these sites run several — `tmt-brand-d8` has two,
`smb-franchise-d9` three. DDEV uses one `db` container and can hold as many databases as
you like inside it:

```sh
ddev import-db --database=<name> --file=<dump.sql.gz>
```

The trap is the *host*, not the name: `dkr` ran a container per database, so settings
files tend to build the hostname from the database (`mariadb-us`, `mariadb-ca`). Under
DDEV every one of them is on host `db` and only the database name differs.

`ddev import-db --database=` creates the database as needed, but a database you want to
exist while *empty* — an unpopulated migration source — has to be created by hand, and
`ddev mysql` connects as an unprivileged user:

```sh
ddev exec 'mysql -uroot -proot -e "CREATE DATABASE IF NOT EXISTS <name>;
  GRANT ALL ON \`<name>\`.* TO \"db\"@\"%\"; FLUSH PRIVILEGES;"'
```

**Hostnames pinned in Drupal config, not just in nginx.** A second hostname is one line:

```yaml
additional_hostnames:
    - ca.<project>          # -> https://ca.<project>.ddev.site
```

But if the site uses the Domain module, the local hostname is *also* a config entity —
`conf/sync/domain_alias.alias.*.yml` with `pattern: 'docker.localhost:8000'`. Nothing
matches `*.ddev.site` until a `domain_alias` exists for it. Symptom: the site loads, but
as the wrong domain, with nothing in the logs about hostnames.

Add one alias per hostname, alongside dkr's rather than replacing them — they coexist
happily, and the `environment: local` key means neither affects production:

```yaml
# conf/sync/domain_alias.alias.<id>.yml
uuid: <a fresh uuid>
langcode: en
status: true
dependencies: {  }
id: <id>
domain_id: <the domain.record id this hostname belongs to>
pattern: '<project>.ddev.site'
redirect: 0
environment: local
```

Then `ddev drush config:import --partial --source=<config dir>`. Verify with the
negotiator rather than by eye, since a wrong answer still returns HTTP 200:

```sh
ddev drush --uri=https://ca.<project>.ddev.site \
  ev 'echo \Drupal::service("domain.negotiator")->getActiveId(), PHP_EOL;'
```

That `--uri` is also how you run any drush command against the second country, where
under `dkr` it was the production URL.
