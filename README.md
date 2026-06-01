# gwt — Git Worktree Manager for Laravel (bare-clone pattern)

A small, dependency-free **zsh** tool that makes working with multiple branches of a
Laravel project at the same time fast and painless. It uses git's *bare-clone +
worktree* pattern, so every branch you check out gets its **own folder** — no
stashing, no context-switching, no "let me just commit this WIP first".

Each worktree gets its **own independent dependencies** (`vendor/`,
`node_modules/`), installed by your project's own install command, its **own
database(s)** and **own Redis cache index**, created and wired into its env, and —
paired with **Laravel Herd** on macOS — its **own `*.test` site with TLS**, driven
by a single `APP_DOMAIN` value in the branch's `.env`. Branches never interfere
with each other — no shared state, no stash dance.

```
~/projects/myapp/
├── myapp.git/              ← bare repo (the .git database + local gwt.conf)
├── myapp-main/             ← worktree; own vendor/node_modules, myapp-main.test
├── myapp-feature-login/    ← worktree; own vendor/node_modules, myapp-feature-login.test
└── myapp-hotfix-123/       ← worktree; own vendor/node_modules, myapp-hotfix-123.test
```

**gwt is tuned for Laravel + Laravel Herd.** Exactly *how* it installs deps, runs
the site, and rewrites the env lives in a tiny per-project config file
(`gwt.conf`) — so you can adjust the commands without editing the tool.

---

## Why use it?

- **Work on several branches in parallel** — each branch is a real directory you can
  open in a separate editor window, run, and test independently.
- **Isolated dependencies per branch** — each worktree installs its own deps, so a
  branch that bumps a package version can never corrupt another branch.
- **Isolated data per branch** — `gwt add` creates this branch's databases and
  allocates it a Redis cache index, then points its env at them. A migration on
  one branch cannot rewrite another's data, and `cache:clear` in one worktree no
  longer flushes everyone else's cache.
- **A `*.test` site per branch** — pair with Laravel Herd and each worktree gets its
  own `<project>-<branch>.test` host with TLS, from one `APP_DOMAIN` env line.
- **One command to set up a branch** — `gwt add my-feature` adds a worktree, copies
  `.env` / `.env.testing`, copies shared project-root files, creates its databases
  and Redis index, installs deps, runs your hooks, and links the Herd site.
- **Multi-project & zero global config** — it figures out which project you're in from
  your current directory. Per-project settings live next to the repo, privately.
- **Safe by default** — a `--test` (dry-run) mode previews every action, and destructive
  operations are guarded.

---

## Requirements

### Required

| Requirement | Notes |
|---|---|
| **macOS** | The only platform gwt is developed and tested on. See [Other platforms](#other-platforms) below. |
| **zsh** | Uses zsh-only features throughout — `vared`, glob qualifiers (`(D.N)`), parameter modifiers (`${x:A}`), `&!`, associative arrays. It is **not** bash-compatible and never will be. |
| **git ≥ 2.7** | `git worktree list --porcelain` landed in 2.7. Git's own config parser reads your `gwt.conf`, so there is no INI dependency. |
| **awk** + coreutils | The `workspace.xml` merger is plain awk. Everything else is `cp` / `mv` / `mkdir` / `tr`. No Python, Ruby or Node needed. |

### Optional — each gated on a feature you turn on

| Tool | Needed for | Turn it off with |
|---|---|---|
| **Laravel Herd** | The per-branch `*.test` site + TLS (`herd link` / `herd secure`) | drop the `[server]` commands |
| **composer**, **yarn** / **npm**, **php** | Whatever your `[install] cmd` and `[hooks]` actually call | they are your commands — use anything |
| **mysql** or **psql** client | Per-worktree databases | `[db] driver = none` |
| **redis-cli** | Flushing a worktree's cache index on removal | `[redis] isolate = none` |
| **terminal-notifier** | Nicer desktop notifications; falls back to `osascript` when absent | nothing to configure |

`gwt doctor` reports which of these are on `PATH` and whether the database and
Redis servers are reachable, so you do not have to guess.

### IDE support

`gwt ide sync` and the IDE seeding on `gwt add` support two editors:

| Editor | Status |
|---|---|
| **PhpStorm** | Tested. The file manifest and the `workspace.xml` component merger were built against real `.idea` folders. |
| **VS Code** | Implemented and exercised, but not battle-tested. `.vscode/*.json` files are plain JSON with no per-project identity in them, so they need no merging — the copy is straightforward. |

Other JetBrains IDEs (IntelliJ IDEA, WebStorm, PyCharm) use the same `.idea`
layout, so the file sync should work unchanged — but the "is the IDE running"
check matches PhpStorm's process path specifically, so you would not get that
warning. Treat them as unsupported until someone confirms otherwise.

Neither editor is required. With no `.idea` or `.vscode` in a worktree, gwt
simply skips the IDE step.

> **Important:** `.idea/workspace.xml` cannot be synced while PhpStorm is open —
> it keeps that file in memory and rewrites it on its own schedule. See
> [Quit the IDE before syncing workspace.xml](#quit-the-ide-before-syncing-workspacexml).

### Other platforms

gwt is not tested on Linux. Most of it is portable, but these are macOS-specific
and would need attention:

- **Laravel Herd** does not exist on Linux — you would replace the `[server]`
  commands with whatever serves your sites.
- **`chflags`** (clearing BSD immutable flags during a force-remove) and
  **`osascript`** (notification fallback) are BSD/macOS only. Both are already
  called with errors suppressed, so they degrade rather than break.
- **IDE detection** matches macOS `.app` bundle paths, so the running-IDE warning
  would silently never fire.

Patches welcome; just do not assume it works today.

---

## Installation

### Easy install (macOS) — double-click

Clone or download the repo, then **double-click `install.command`**. macOS opens
it in Terminal, where it:

1. checks that **zsh** is installed (and stops with a clear message if it isn't),
2. copies `gwt.zsh` (and the example configs) into `~/.zsh/gwt/`,
3. adds a `source` line to your `~/.zshrc` (only once — safe to re-run),
4. loads it so `gwt` works in new terminals.

Every `add` / `remove` / `install` is appended to a daily log at
`~/.zsh/gwt/logs/DD-MM-YYYY.log`.

Then open a new terminal (or run `source ~/.zshrc`) and try `gwt -h`.

> If double-clicking opens the file in a text editor instead of running it, run
> it once from a terminal: `sh /path/to/install.command`. Afterwards macOS
> remembers to open `.command` files in Terminal.

### Manual install

1. Clone this repo (or just grab `gwt.zsh`):

   ```sh
   git clone <this-repo-url> ~/tools/gwt
   ```

2. Source it from your `~/.zshrc`:

   ```sh
   echo 'source ~/tools/gwt/gwt.zsh' >> ~/.zshrc
   source ~/.zshrc
   ```

3. Verify:

   ```sh
   gwt -h
   ```

> `oh-my-zsh` users: its git plugin aliases `gwt` to `git worktree`. The script removes
> that alias automatically, so just make sure `gwt.zsh` is sourced **after** oh-my-zsh.

---

## Quick start

```sh
# 1. Create (or pick) the folder you want the project to live in, and cd into it.
mkdir -p ~/projects/myapp && cd $_

# 2. One-time setup: clone the bare repo, create the reference worktree, scaffold
#    a Laravel + Herd gwt.conf, and run its install step.
gwt init

# 3. From now on, work on any branch in its own folder:
gwt add feature/login         # add an existing branch (local or on origin)
gwt add main my-experiment    # create "my-experiment" off "main" and check it out

# 4. Jump into a worktree (gwt is a shell function, so this really cd's):
gwt cd feature/login

# 5. See everything:
gwt list

# 6. Clean up when done (one or more at once):
gwt remove my-experiment
gwt remove feature/login my-experiment --force   # also delete the local branches
```

---

## Commands

```
gwt init                 First-time project setup, in the CURRENT folder: clone a
                         bare repo, create the reference worktree, scaffold a local
                         gwt.conf, and run its install step. Run once per project.

gwt add <existing-branch>
                         Add an existing branch (local, or one that only exists on
                         origin) as a new worktree, then install its own deps.

gwt add <existing-branch> <new-branch>
                         Create <new-branch> off <existing-branch>, then check it
                         out as a worktree.

gwt cd <branch>          cd into a worktree (no arg → the project folder).

gwt list                 List all worktrees of the current project.

gwt config [show|edit|path|upgrade]
                         Show the resolved config, or edit gwt.conf in $EDITOR.
                         'upgrade' appends the sections an older config is
                         missing — gwt.conf is scaffolded once and never
                         rewritten, so new features never reach an existing
                         project on their own.

gwt ide sync             Push the IDE settings of the worktree you are IN to
                         every other worktree, reference included — so the next
                         'gwt add' inherits them too. Detects PhpStorm (.idea)
                         and VS Code (.vscode). Must be run inside a worktree.
                         New worktrees are seeded from the reference on add.

gwt db [status|create|drop] [<branch>]
                         Per-worktree databases and Redis index. 'status' prints
                         what gwt recorded against each worktree next to what its
                         env files actually name; 'create' provisions them for a
                         worktree that predates the [db] section.

gwt doctor               Sanity-check: config present, referenced tools on PATH,
                         dependency dirs are real (not symlinked), and each
                         worktree really is isolated (own database, own Redis
                         index, no wildcard SESSION_DOMAIN, no dead env keys).

gwt remove <branch>...   Remove one or MORE worktrees: run pre-remove hook, stop
                         each dev server, then delete the folder. The git branch
                         is KEPT (commits stay safe) unless you pass --force.

gwt help | -h | --help   Show help.
```

### Flags

| Flag | Applies to | Effect |
|---|---|---|
| `--test`, `--dry` | any command | Preview everything without making changes. |
| `--force` | `remove` | **Nuke it all.** Skip the dependency-dir guard, delete the **local** git branch (force-deleting even unmerged commits), drop the databases gwt recorded for the worktree and release its Redis index. **Never touches the remote.** |

> By default `gwt remove` deletes the worktree folder but **keeps the branch** (and
> refuses if the worktree still has real `vendor/` / `node_modules/`), so your work
> is never lost — re-add the branch with `gwt add <branch>`. A worktree and a
> branch are independent in git. Databases are kept too, and gwt tells you how to
> drop them. One flag, `--force`, does the full teardown: deps + folder + local
> branch + databases + Redis index in one go. It only ever drops resources gwt
> itself created and recorded, never the reference worktree's. gwt has no
> `git push`/remote-delete code path, so the remote is always safe.
>
> Remove several at once: `gwt remove staging feature/login old-spike --force`.

---

## Configuration

Each project gets one config file at **`<project>.git/gwt.conf`**. It lives
inside the bare dir, which means it is **local to your machine and never
committed** — it can't accidentally end up in a teammate's checkout. It uses
git-config INI syntax and is read with `git config --file` (no extra
dependency). `gwt init` scaffolds one for you; edit it any time with
`gwt config edit`.

```ini
# <project>.git/gwt.conf  (Laravel + Herd — the scaffolded default)
[deps]
  heavy = vendor              # heavy dep dirs, guarded on removal (repeatable)
  heavy = node_modules

[install]
  cmd = "composer install && yarn install"   # runs in EACH new worktree

[env]
  copy = .env                 # gitignored files copied into new worktrees (repeatable)
  copy = .env.testing         # seeded from .env.testing.example when absent
  set  = APP_DOMAIN=$GWT_DOMAIN.test   # per-worktree override (repeatable, $GWT_* expanded)
  set  = SESSION_COOKIE=${GWT_IDENT}_session

# Per-file overrides — written into that ONE file. This is how .env and
# .env.testing end up with different databases.
[env ".env"]
  set = DB_DATABASE=$GWT_IDENT           # e.g. myapp_feature_login
[env ".env.testing"]
  set = DB_DATABASE=${GWT_IDENT}_test

[db]                          # databases created per worktree; none = off
  driver = mysql              # mysql | postgres | none
  host = 127.0.0.1
  port = 3306
  user = root
  password =
  create = $GWT_IDENT         # repeatable — one per database this worktree needs
  create = ${GWT_IDENT}_test
  guard  = DB_DATABASE        # post-install runs only if env names one of them
  drop-on-remove = force      # never | force | always

[redis]                       # a Redis cache index per worktree; none = off
  isolate = cache-db
  min = 1                     # index range to allocate from
  max = 15
  env-db     = REDIS_CACHE_DB # env key that receives the allocated index
  env-prefix = CACHE_PREFIX
  prefix     = $GWT_IDENT:
  flush-on-remove = force

[ide]                         # .idea / .vscode settings shared between worktrees
  seed = true                 # gwt add seeds a new worktree from the reference
  skip = commandlinetools     # never copied — generated, or points back at the
  skip = shelf                # worktree it came from
  workspace-skip = ProjectId  # workspace.xml components that never travel
  workspace-skip = RunManager

[copy]
  shared = .gwt               # copy its CONTENTS into each worktree, keeping relative paths
  # shared_root = $GWT_WORKTREE_PARENT   # base dir (default: project root)

[server]                      # Herd site for this worktree
  url  = "https://$GWT_DOMAIN.test"
  up   = "herd link $GWT_DOMAIN && herd secure $GWT_DOMAIN"
  down = "herd unsecure $GWT_DOMAIN 2>/dev/null; herd unlink $GWT_DOMAIN 2>/dev/null"

[hooks]
  post-create  = "mkdir -p bootstrap/cache"   # any shell, after a worktree is created
  # post-install = "php artisan migrate:fresh --seed" # after deps install; can use
                                                      # vendor/. Off by default —
                                                      # see The post-install guard
  pre-remove   =                              # any shell, before a worktree is removed
```

### The APP_DOMAIN env pattern

Each branch's site is kept self-contained through a **single** `APP_DOMAIN` value
in `.env` / `.env.testing` — `APP_URL` and the Herd TLS cert paths all
interpolate from `${APP_DOMAIN}`:

```ini
APP_DOMAIN=app.myapp.test
APP_URL="https://${APP_DOMAIN}"
VITE_HTTPS_KEY_PATH="…/Certificates/${APP_DOMAIN}.key"
VITE_HTTPS_CERT_PATH="…/Certificates/${APP_DOMAIN}.crt"
```

So pointing a branch at its own host is one declarative line —
`[env] set = APP_DOMAIN=$GWT_DOMAIN.test` — which rewrites `APP_DOMAIN` to
`<project>-<branch>.test` (e.g. `myapp-staging.test`) in every copied env file;
`herd secure` then issues the matching cert.

### Per-worktree env overrides

`[env] set = KEY=VALUE` (repeatable) writes `KEY` into each `[env] copy` file
after it's copied — replacing the existing `KEY=` line, or appending it. `VALUE`
is expanded with the `$GWT_*` variables. This is the readable replacement for the
hand-written `sed` that used to live in a `post-create` hook: declare what each
worktree's env should say, and gwt does the editing.

A plain `[env] set` writes the same value into *every* copied file, which cannot
express the one thing a Laravel worktree most needs: `.env` and `.env.testing`
must point at **different** databases. So the same directive can be scoped to a
single file — git's INI reader treats the quoted name as a subsection:

```ini
[env ".env"]
  set = DB_DATABASE=$GWT_IDENT
[env ".env.testing"]
  set = DB_DATABASE=${GWT_IDENT}_test
```

### Per-worktree databases and Redis

A worktree with its own files, hostname and dependencies is still not isolated if
it shares a database and a cache with every other branch. `gwt add` therefore
**creates** the backing stores each worktree needs and records them in the bare
repo's git config:

```
gwt.<slug>.db              one entry per database created for this worktree
gwt.<slug>.redis-cache-db  the Redis index allocated to this worktree
```

That ledger is the safety mechanism, not bookkeeping. Removal only ever drops
what is written there — never a name recomputed from the current config — so
editing `gwt.conf` after the fact cannot redirect a drop at the shared project
database, and an index is never handed to two worktrees at once. Inspect it with
`gwt db status`, which prints what gwt recorded against each worktree next to
what its env files actually name; the two disagreeing is what you're looking for.

**Why Redis isolation is by database index, not key prefix.** A prefix looks like
the obvious answer and does not actually work: Laravel's `cache:clear` ends in
`FLUSHDB`, which ignores prefixes entirely, and SCAN-based cache busting matches
patterns the client never prefixes (predis prefixes `SSCAN` / `ZSCAN` / `HSCAN`,
which take a key argument, but not plain `SCAN`). Two worktrees sharing one index
wipe each other's cache whatever prefix they write under. An index per worktree
is what actually contains those operations; the prefix is written on top as a
second layer for the code paths that read keys rather than nuke them.

### Keeping IDE settings consistent across worktrees

Every worktree is a separate project to PhpStorm and VS Code, and **neither has a
global default** for most of what lives in `.idea` / `.vscode` — so each new one
starts blank and you reconfigure it by hand. `gwt add` seeds a new worktree from
the reference worktree, and `gwt ide sync`, run *inside* the worktree whose
settings are right, pushes them to every other worktree. The reference is one of
the targets, which is what makes the next `gwt add` inherit them too.

Most of `.idea` is portable. What needs care is the handful of files that either
name the worktree or point back into it:

| File | Handling |
|---|---|
| `<worktree>.iml`, `modules.xml` | **Copied and renamed.** This is where Settings ▸ Directories lives — source and excluded folder marks. Every path inside is `$MODULE_DIR$`-relative, so only the *filename* is per-worktree: gwt writes the contents under the target's own module name and repoints `modules.xml` at it. |
| `workspace.xml` | **Merged**, component by component — see below. |
| `commandlinetools/` | Skipped — stores an absolute path to the source worktree's `artisan`. |
| `dataSources/`, `shelf/` | Skipped — local query history and shelved changes. |


`workspace.xml` is **merged component by component**, never copied. Each synced
component replaces the same-named one in the target and everything else is left
alone, so a sync carries your settings without carrying the target's run configs
away with them. `[ide] workspace-skip` lists the components that never travel —
`ProjectId` is meant to be unique per project, and `RunManager`,
`ChangeListManager`, `TaskManager` and `PropertiesComponent` are per-project
state. `<MESSAGE>` children are dropped too: in `VcsManagerConfiguration` those
are your local commit-message history sitting next to the setting you want.

#### Quit the IDE before syncing workspace.xml

**`workspace.xml` cannot be synced reliably while the IDE is open.** It keeps the
file in memory and writes it on its own schedule, so a setting you just toggled is
probably not on disk yet — and it rewrites that file in every project it has open,
undoing whatever gwt wrote. `gwt ide sync` detects a running PhpStorm or VS Code
and warns, but cannot work around it. Change the setting, **quit the IDE**, sync,
then reopen. Every other file syncs fine either way.

#### The "Analyze code" checkbox

`Settings → Version Control → Commit → Analyze code` lives in
`.idea/workspace.xml`, and there is **no global default for it** — the IDE's
"Settings for New Projects" template carries no `VcsManagerConfiguration` at all,
which is why unticking it in Settings only affects the project you are in. Untick
it once, run `gwt ide sync`, and every worktree — present and future — has it off.

### The post-install guard

`[hooks] post-install` is the only place a command that needs `vendor/` can run —
`post-create` fires *before* the install that creates `vendor/`. In practice that
makes it where migrations go:

```ini
post-install = "php artisan migrate:fresh --seed"
```

It ships **commented out** in the scaffold; uncomment it once you have read the
caveat below.

`migrate:fresh` drops every table it can reach. So before that hook runs, gwt
re-reads the env the worktree **actually has on disk** and requires `[db] guard`
(default `DB_DATABASE`) to name a database gwt created for *this* worktree. If
env wiring failed and a file still points at the shared project database, the
hook is skipped and reported rather than run. The check fails **closed**: if the
guard itself cannot be evaluated, the hook is skipped too.

> **The guard only exists when `[db]` is managing your databases.** With
> `[db] driver = none` there is nothing to check a value against, so the guard is
> inactive and the hook runs against whatever the env names. That is why the
> scaffold ships `post-install` **commented out** — enable a destructive command
> here only once `[db]` is set up.

### The `.gwt` directory

`[copy] shared = .gwt` copies the **contents** of a project-root directory into
every new worktree, **preserving relative paths** — so each personal file lands
where the app actually expects it:

```
~/projects/myapp/
├── myapp.git/
├── .gwt/                              ← beside the bare repo, never inside a checkout
│   ├── .idea/workspace.xml            → <worktree>/.idea/workspace.xml
│   ├── phpunit.local.xml              → <worktree>/phpunit.local.xml
│   └── database/seeders/LocalSeeder.php  → <worktree>/database/seeders/LocalSeeder.php
└── myapp-<slug>/
```

Existing files in the worktree are never overwritten, and symlinks are reported
and skipped rather than copied. Everything `shared` copies **in** should be
gitignored by the project, or it shows up as untracked in every worktree —
`gwt doctor` checks each copied path and names the one to add.

`shared` is repeatable, and `shared_root` overrides the base directory the items
resolve against (default: the project root). To land a whole folder at the
worktree root under its own name, nest it: `.gwt/backups/…` → `backups/…`.

#### Stopping PhpStorm from re-checking "Analyze code"

That checkbox is per project, stored in `.idea/workspace.xml`:

```xml
<component name="VcsManagerConfiguration">
  <option name="CHECK_CODE_SMELLS_BEFORE_PROJECT_COMMIT" value="false" />
</component>
```

There is **no global default for it.** The IDE's "Settings for New Projects"
template (`options/project.default.xml`) doesn't carry `VcsManagerConfiguration`
at all, so unticking it under Settings → Version Control → Commit only affects
the project you're currently in. Every worktree is a separate project, so the box
comes back on each new one.

Putting exactly that file at `.gwt/.idea/workspace.xml` seeds it into each
worktree before you ever open it — PhpStorm reads it on open and adds its own
components alongside, so you don't need a copy of your whole `.idea`. Only a
directory-contents copy can place a **nested** path like this, which is why
`shared` works the way it does.

### Variables available to commands

Every command in `[install]`, `[server]`, and `[hooks]` runs **inside the target
worktree** with these exported:

| Variable | Value |
|---|---|
| `$GWT_DIR` | absolute path of the worktree the command runs in |
| `$GWT_PROJECT` | project name |
| `$GWT_SLUG` | branch slug (`feature/login` → `login`) |
| `$GWT_DOMAIN` | `<project>-<slug>` — handy for per-branch hostnames (matches the folder name) |
| `$GWT_REF` | reference branch name |
| `$GWT_REF_DIR` | reference worktree path |
| `$GWT_WORKTREE_PARENT` | project root (holds the bare repo + worktrees) |
| `$GWT_IDENT` | `<project>_<slug>`, every character outside `[A-Za-z0-9_]` folded to `_` (`myapp_feature_login`) — the spelling used for database names, cache prefixes and cookie names |
| `$GWT_REF_IDENT` | the same, for the reference branch |

Quote values containing spaces or shell operators: `up = "herd link $GWT_DOMAIN"`.

### Ready-made template

The [`examples/`](examples/) directory has the copy-paste
[`laravel-herd.gwt.conf`](examples/laravel-herd.gwt.conf) — the same template
`gwt init` scaffolds. To reset or tweak your config, run `gwt config edit`.

---

## How it works

### The layout

`gwt init` turns the **current directory** into a project folder:

```
<cwd>/
├── <project>.git/          ← bare clone (no working tree) + local gwt.conf
└── <project>-<ref>/        ← the "reference" worktree (e.g. myapp-main)
```

Every later `gwt add <branch>` (or `gwt add <base> <branch>`) adds a sibling
worktree `<project>-<branch>/`.

### Independent dependencies

Every worktree installs its **own** `vendor/` and `node_modules/` by running your
`[install] cmd` when it's created. Nothing is shared or symlinked between
worktrees, so a branch that changes a dependency version can never affect another
branch.

> **Why not symlink to save disk/time?** Sharing a dir like `vendor/` via symlink
> breaks tools that resolve paths *through* it. PHP's Composer autoloader, for
> example, derives your application's base path from the real `vendor` location —
> so a symlinked `vendor` makes every worktree load app code from a single place,
> causing edits to silently not take effect. Real, independent deps avoid this
> entire class of bug. The `[deps] heavy = …` list exists only so `gwt remove`
> can guard against deleting freshly-installed deps without `--force`.

### Independent data

The same reasoning applies below the filesystem. `gwt add` creates this
worktree's databases, allocates it a Redis cache index, and writes both into its
env — so a migration on one branch cannot rewrite another's data, and
`cache:clear` in one worktree no longer flushes everyone else's cache. Sessions
are covered too: `SESSION_COOKIE` is named per worktree, so isolation survives a
switch from the `file` driver to `redis` or `database`.

Everything gwt creates is recorded in the bare repo, and only recorded resources
are ever dropped. See [Per-worktree databases and Redis](#per-worktree-databases-and-redis).

### Local, per-project config

There is **no global/shared config file**. State is derived from where you are:

- `gwt init` is run from the folder you want the project created in.
- Every other command derives the project from your current directory (a worktree,
  or the project folder itself) via `git rev-parse`.
- The reference branch is stored in the bare repo's git config (`gwt.ref`);
  everything else lives in `<project>.git/gwt.conf`. Both stay with the bare repo
  and never collide between projects.

You can use `gwt` across any number of projects with zero shared state — just `cd`
into the one you want.

---

## Examples

Preview an init without touching anything:

```sh
gwt init --test
```

Create a hotfix branch off `main` and work on it:

```sh
cd ~/projects/myapp/myapp-main      # anywhere inside the project
gwt add main hotfix/urgent
gwt cd hotfix/urgent
```

Tear a worktree down completely — dep folders **and** the local branch:

```sh
gwt remove hotfix/urgent --force
```

Remove several worktrees in one go:

```sh
gwt remove hotfix/urgent feature/login old-spike --force
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Error: not inside a gwt project` | Run the command from inside the project (a worktree or the project folder), or run `gwt init` to create one. |
| `command not found: vite` (or similar) after a worktree checkout | This worktree's deps weren't installed, or your `[install] cmd` failed. Run `gwt doctor`, then re-run the install command inside the worktree. |
| Dev server / install command didn't run | Check it's set in `gwt.conf` (`gwt config show`) and that the tool is on `PATH` (`gwt doctor`). Commands with spaces must be quoted. |
| `herd secure failed` (Laravel example) | Laravel Herd isn't installed/running, or the site isn't linked. Run `herd secure <domain>` manually, or check the `laravel-herd.gwt.conf` example. |
| Code edits don't take effect / a worktree's `node_modules` or `vendor` is a symlink | A dep dir is symlinked to another worktree (legacy setup). `gwt doctor` flags this. Remove the link and reinstall: `rm <dir> && <install cmd>` inside the worktree. |
| Two worktrees are writing to the same database | `gwt doctor` reports it, and `gwt db status` shows which. Fix the config, then `gwt db create <branch>` to provision that worktree and repoint its env. |
| `Post-install REFUSED — env is not pointing at this worktree's own database` | Working as designed: the env named a database gwt did not create for this worktree, so the hook (which usually runs `migrate:fresh`) was skipped instead of destroying shared data. Run `gwt db status`, fix the mismatch, then `gwt db create <branch>`. |
| A worktree's overrides seem to have no effect | `gwt doctor` warns when nothing reads a key gwt writes — e.g. `REDIS_PREFIX` in a project whose `config/database.php` redis block has no `options.prefix`. The env line is written, but nothing consumes it. |
| The new `[db]` / `[redis]` sections aren't in my `gwt.conf` | `gwt.conf` is scaffolded once and never rewritten. Run `gwt config upgrade` to append what's missing (preview with `gwt --dry config upgrade`). |
| `no free Redis index left` | Every index between `[redis] min` and `max` is taken. Raise `max`, or reclaim indexes from worktrees you've removed: `gwt db drop <branch>`. |

---

## Extending

There's nothing to extend in the code — **adapting it means writing `gwt.conf`**,
not editing `gwt.zsh`. Declare the heavy dep dirs, the install command, the
env/shared files to copy, the Herd (or other) dev-server commands, and any hooks.
See [`examples/`](examples/) for the Laravel/Herd template.

> **zsh gotcha for contributors:** if you *do* hack on `gwt.zsh`, never name a
> local variable `path` — in zsh `path` is tied to `$PATH`, and assigning a
> directory to it wipes your command search path. Use `dir`.

---

## License

MIT — do whatever you like.
