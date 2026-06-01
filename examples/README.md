# gwt config example

[`laravel-herd.gwt.conf`](laravel-herd.gwt.conf) is a **ready-made starting
point** — the same Laravel + Laravel Herd template `gwt init` scaffolds. `gwt`
does not read this file directly; copy its contents into your project's own
config:

```sh
gwt config edit          # opens <project>.git/gwt.conf in $EDITOR
# …paste the example, tweak, save.
```

(`gwt init` already writes this template for you. The file is kept here for
reference and for re-pasting if you want to reset your config.)

## The config model

`gwt.conf` lives at `<project>.git/gwt.conf` — inside the bare dir, so it is
**local to your machine and never committed**. It uses git-config INI syntax and
is parsed with `git config --file`. Sections:

| Section / key             | Purpose                                                        |
|---------------------------|----------------------------------------------------------------|
| `[deps] heavy = <dir>`    | Heavy dep dir (e.g. `vendor`, `node_modules`), listed so removal can guard it. Installed real & independent in every worktree (no symlinking). Repeatable. |
| `[install] cmd = <cmd>`   | Run in **each** new worktree to install its own dependencies.  |
| `[env] copy = <file>`     | Gitignored env file copied from the reference into each new worktree (or seeded from `<file>.example`). Repeatable — e.g. `.env` and `.env.testing`. |
| `[env] set = KEY=VALUE`   | Per-worktree override written into every copied env file (the `KEY=` line is replaced, or appended). `$GWT_*` expanded. Repeatable. Replaces hand-written `sed` in hooks. |
| `[env "<file>"] set = KEY=VALUE` | The same, but written into **that one file only**. This is how `.env` and `.env.testing` end up with different `DB_DATABASE` values. Repeatable. |
| `[db] driver`             | `mysql` \| `postgres` \| `none` (default). `none` disables all database handling. |
| `[db] host/port/user/password/charset/collation` | How to reach the server. The password is passed via the environment, never in `argv`. |
| `[db] create = <name>`    | A database to create for each worktree. Repeatable — typically one for `.env` and one for `.env.testing`. |
| `[db] guard = <KEY>`      | Env key the post-install hook is checked against. See [The post-install guard](#the-post-install-guard). |
| `[db] drop-on-remove`     | `never` \| `force` (default) \| `always` — when `gwt remove` may drop them. |
| `[redis] isolate`         | `cache-db` or `none` (default). `cache-db` allocates a Redis database index per worktree. |
| `[redis] min` / `max`     | The index range to allocate from (default 1–15).               |
| `[redis] env-db` / `env-prefix` / `prefix` | Env keys that receive the allocated index and the per-worktree cache prefix. |
| `[redis] flush-on-remove` | `never` \| `force` (default) \| `always` — when `gwt remove` may `FLUSHDB` and release the index. |
| `[ide] seed`              | `true` (default) / `false` — whether `gwt add` seeds a new worktree's `.idea` / `.vscode` from the reference worktree. |
| `[ide] skip = <pattern>`  | Files/dirs inside an IDE config dir that are never copied. Defaults: `commandlinetools`, `shelf`, `dataSources*`, `httpRequests`, `sonarlint`, `.DS_Store`. Repeatable. `<worktree>.iml`, `modules.xml` and `workspace.xml` are handled specially and ignore this list. |
| `[ide] workspace-skip = <component>` | `.idea/workspace.xml` components that are never synced — per-project state rather than settings. Defaults: `ProjectId`, `RunManager`, `ChangeListManager`, `TaskManager`, `PropertiesComponent`. Repeatable. |
| `[copy] shared = <dir>`   | A project-root directory whose **contents** are copied into each worktree, **preserving relative paths** — `.gwt/database/seeders/LocalSeeder.php` lands at `database/seeders/LocalSeeder.php`. Repeatable. Existing files are left untouched; symlinks are skipped. |
| `[copy] shared_root = <dir>` | Override the base dir the `shared` items resolve against (default: the project root). |
| `[server] url`            | Browsable dev URL (shown after create).                        |
| `[server] up` / `down`    | Commands to start / stop the dev server for a worktree.        |
| `[hooks] post-create`     | Arbitrary shell run after a worktree is created.               |
| `[hooks] post-install`    | Arbitrary shell run **after `[install] cmd` finishes**, in the background. The only place a command that needs `vendor/` can go. Ships commented out; guarded by `[db] guard` when `[db]` is in use — see below. |
| `[hooks] pre-remove`      | Arbitrary shell run before a worktree is removed.              |

### Per-worktree databases and Redis

A worktree with its own files, hostname and dependencies is still not isolated
if it shares a database and a cache with every other branch. So `gwt add`
**creates** the backing stores each worktree needs and records them in the bare
repo's git config:

```
gwt.<slug>.db              one entry per database created for this worktree
gwt.<slug>.redis-cache-db  the Redis index allocated to this worktree
```

That ledger is the safety mechanism, not bookkeeping. Removal only ever drops
what is written there — never a name recomputed from the current config — so
editing `gwt.conf` after the fact cannot redirect a drop at the shared project
database, and an index is never handed to two worktrees at once.

Inspect it any time with `gwt db status`, which prints what gwt recorded against
each worktree next to what its env files actually name. The two disagreeing is
the case worth looking for.

#### Why Redis isolation is by database index, not key prefix

A key prefix looks like the obvious answer and does not actually work:

- Laravel's `cache:clear` ends in **`FLUSHDB`**, which ignores prefixes entirely.
- SCAN-based cache busting matches patterns the client never prefixes. predis
  prefixes `SSCAN` / `ZSCAN` / `HSCAN`, which take a key argument, but not plain
  `SCAN` — so a `scan('*')` sweep hits every worktree's keys.

Two worktrees sharing one index therefore wipe each other's cache no matter what
prefix they write under. Allocating an index per worktree is what actually
contains those two operations. The prefix is still written on top, as a second
layer for the code paths that read keys rather than nuke them.

Both env keys (`REDIS_CACHE_DB`, `CACHE_PREFIX`) already exist in a stock Laravel
config and default to today's values, so a developer who never sets them sees no
change at all.

### The `.gwt` directory

`[copy] shared = .gwt` copies the **contents** of a project-root directory into
every worktree, preserving relative paths:

```
~/projects/myapp/
├── myapp.git/
├── .gwt/                              ← beside the bare repo, never inside a checkout
│   ├── .idea/workspace.xml            → <worktree>/.idea/workspace.xml
│   ├── phpunit.local.xml              → <worktree>/phpunit.local.xml
│   └── database/seeders/LocalSeeder.php  → <worktree>/database/seeders/LocalSeeder.php
└── myapp-<slug>/
```

Each personal file lands where the app actually expects it, rather than in a
folder at the worktree root. Existing files are never overwritten, and symlinks
are reported and skipped rather than copied.

Everything `shared` copies **in** should be gitignored by the project, or it
shows up as untracked in every worktree. `gwt doctor` checks each copied path
and tells you which one to add to `.gitignore`.

#### Stopping PhpStorm from re-checking "Analyze code"

That checkbox is stored per project, in `.idea/workspace.xml`:

```xml
<component name="VcsManagerConfiguration">
  <option name="CHECK_CODE_SMELLS_BEFORE_PROJECT_COMMIT" value="false" />
</component>
```

There is **no global default for it** — the IDE's "Settings for New Projects"
template (`options/project.default.xml`) does not carry `VcsManagerConfiguration`
at all, which is why unticking it in Settings → Version Control → Commit only
ever affects the project you're in. Every new worktree is a new project, so the
box comes back.

Putting exactly that file at `.gwt/.idea/workspace.xml` seeds it into each
worktree before you first open it. PhpStorm reads it on open and adds its own
components alongside — you don't need a copy of your whole `.idea`. Only a
directory-contents copy can place a **nested** path like this, which is why
`shared` works the way it does.

### Keeping IDE settings consistent across worktrees

Every worktree is a separate project to PhpStorm and VS Code, and **neither has a
global default** for most of what lives in `.idea` / `.vscode`. So each new one
starts blank and you reconfigure it by hand. Two things fix that:

- **`gwt add`** seeds the new worktree's IDE config from the reference worktree.
- **`gwt ide sync`**, run *inside* the worktree whose settings are right, pushes
  them to every other worktree — the reference included, so the next `gwt add`
  inherits them too.

It must be run from inside a worktree; the project root has nothing to sync from,
and gwt says so rather than guessing.

#### What is and isn't copied

Most of `.idea` is portable. What needs care is the handful of files that either
name the worktree or point back into it:

| File | Handling |
|---|---|
| `<worktree>.iml`, `modules.xml` | **Copied and renamed.** This is where Settings ▸ Directories lives — source and excluded folder marks. Every path inside is `$MODULE_DIR$`-relative, so only the *filename* is per-worktree: gwt writes the contents under the target's own module name and repoints `modules.xml` at it. |
| `workspace.xml` | **Merged**, component by component — see below. |
| `commandlinetools/` | Skipped — stores an absolute path to the source worktree's `artisan`. |
| `dataSources/`, `shelf/` | Skipped — local query history and shelved changes. |


`workspace.xml` is **merged component by component**. Each synced component
replaces the same-named one in the target; everything else the target has is left
alone. `[ide] workspace-skip` names the components that never travel — `ProjectId`
is meant to be unique per project, and `RunManager` / `ChangeListManager` /
`TaskManager` / `PropertiesComponent` are per-project state, including the
last-opened file path.

`<MESSAGE>` children are dropped from whatever does sync. In
`VcsManagerConfiguration` those are your local commit-message history sitting
right next to the setting you actually want — copying the component wholesale
would put one worktree's commit messages in every other worktree's dropdown.

#### Quit the IDE before syncing workspace.xml

**`workspace.xml` cannot be synced reliably while the IDE is open**, in either
direction:

- The IDE keeps it in memory and writes it on its own schedule, so a setting you
  just toggled is very likely **not on disk yet** — there is nothing for gwt to
  copy.
- It rewrites that file in every project it currently has open, **undoing**
  whatever gwt put there.

`gwt ide sync` detects a running PhpStorm or VS Code and warns, but it cannot
work around it. The reliable sequence is:

1. Change the setting.
2. **Quit the IDE** (that is what flushes `workspace.xml` to disk).
3. `gwt ide sync` from inside that worktree.
4. Reopen.

Everything else — `php.xml`, `inspectionProfiles/`, `laravel-idea.xml`,
`.vscode/settings.json` — syncs fine whether the IDE is running or not.

#### The "Analyze code" checkbox

`Settings → Version Control → Commit → Analyze code` is stored per project, in
`.idea/workspace.xml`:

```xml
<component name="VcsManagerConfiguration">
  <option name="CHECK_CODE_SMELLS_BEFORE_PROJECT_COMMIT" value="false" />
</component>
```

There is **no global default for it** — the IDE's "Settings for New Projects"
template (`options/project.default.xml`) carries no `VcsManagerConfiguration` at
all, which is why unticking it in Settings only ever affects the project you are
in. Untick it once, run `gwt ide sync`, and every worktree — present and future —
has it off.

### The post-install guard

`[hooks] post-install` is the only place a command that needs `vendor/` can run —
`post-create` fires *before* the install that creates `vendor/` in the first
place. In practice that makes it where migrations go:

```ini
post-install = "php artisan migrate:fresh --seed"
```

It ships **commented out** in the scaffold; uncomment it once you have read the
caveat below.

`migrate:fresh` drops every table it can reach, so before that hook runs gwt
re-reads the env the worktree **actually has on disk** and requires `[db] guard`
(default `DB_DATABASE`) to name a database gwt created for *this* worktree. If
env wiring failed and a file still points at the shared project database, the
hook is skipped and reported instead of run.

The check fails **closed**: if the guard itself cannot be evaluated — gwt did not
re-load in the detached install shell — the hook is skipped too. An unguarded
`migrate:fresh` is the one outcome worth refusing outright.

> **The guard only exists when `[db]` is managing your databases.** With
> `[db] driver = none` there is nothing to check a value against, so the guard is
> inactive and the hook runs against whatever the env names. That is why the
> scaffold ships `post-install` **commented out** — enable a destructive command
> here only once `[db]` is set up.

### Upgrading an existing project

`gwt.conf` is scaffolded once at `gwt init` and **never rewritten**, so a project
set up before a feature existed keeps running its old config forever — editing
the template in `gwt.zsh` does nothing for it. To pull in the sections a config
is missing, without disturbing anything already in it:

```sh
gwt config upgrade       # preview first with: gwt --dry config upgrade
```

Existing worktrees are left alone. Give one its own resources with
`gwt db create <branch>`, which creates the databases, allocates a Redis index,
and rewrites that worktree's env to point at them.

### The APP_DOMAIN env pattern

The template keeps each branch's site self-contained through a **single**
`APP_DOMAIN` value in `.env` / `.env.testing`. Everything else interpolates from
it, so the `post-create` hook only has to rewrite one line per branch:

```ini
APP_DOMAIN=app.myapp.test
APP_URL="https://${APP_DOMAIN}"
VITE_HTTPS_KEY_PATH="…/Certificates/${APP_DOMAIN}.key"
VITE_HTTPS_CERT_PATH="…/Certificates/${APP_DOMAIN}.crt"
```

A single declarative line — `[env] set = APP_DOMAIN=$GWT_DOMAIN.test` — rewrites
`APP_DOMAIN` (e.g. `myapp-staging.test`) in both env files, and `herd secure
$GWT_DOMAIN` issues the matching cert. No hand-written `sed` needed.

### Variables available to commands

Every command in `[install]`, `[server]`, and `[hooks]` runs **inside the target
worktree** with these exported:

| Variable               | Value                                             |
|------------------------|---------------------------------------------------|
| `$GWT_DIR`             | absolute path of the worktree the command runs in |
| `$GWT_PROJECT`         | project name (e.g. `myapp`)                        |
| `$GWT_SLUG`            | branch slug (e.g. `feature/login` → `login`)       |
| `$GWT_DOMAIN`          | `<project>-<slug>` (per-branch hostname)           |
| `$GWT_REF`             | reference branch name                             |
| `$GWT_REF_DIR`         | reference worktree path                           |
| `$GWT_WORKTREE_PARENT` | project root (holds the bare repo + worktrees)    |
| `$GWT_IDENT`           | `<project>_<slug>` with every character outside `[A-Za-z0-9_]` folded to `_` (e.g. `myapp_feature_login`) — the spelling used for database names, cache prefixes and cookie names |
| `$GWT_REF_IDENT`       | the same, for the reference branch                |

Quote any value containing spaces or shell operators:
`up = "herd link $GWT_DOMAIN"`.
