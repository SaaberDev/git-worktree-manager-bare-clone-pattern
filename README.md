# gwt — Git Worktree Manager (bare-clone pattern)

A small, dependency-free **zsh** tool that makes working with multiple branches of a
project at the same time fast and painless. It uses git's *bare-clone + worktree*
pattern, so every branch you check out gets its **own folder** — no stashing, no
context-switching, no "let me just commit this WIP first".

Heavy per-project dependencies (`vendor/`, `node_modules/`, `.venv/`) are installed
**once** in a reference worktree and **symlinked** into every other worktree, so
spinning up a new branch costs seconds and almost no disk.

```
~/projects/laravel/myapp/
├── myapp.git/              ← bare repo (the .git database)
├── myapp-staging/          ← reference worktree (real deps installed here)
├── myapp-feature-login/    ← worktree; vendor/ + node_modules/ symlinked
└── myapp-hotfix-123/       ← worktree; vendor/ + node_modules/ symlinked
```

---

## Why use it?

- **Work on several branches in parallel** — each branch is a real directory you can
  open in a separate editor window, run, and test independently.
- **No re-installing dependencies per branch** — deps live in one place and are shared
  via symlinks. A new worktree is ready almost instantly.
- **One command to set up a branch** — `gwt my-feature` clones nothing, just adds a
  worktree, links deps, copies `.env`, and (for Laravel) wires up the local dev server
  with TLS.
- **Multi-project & zero global config** — it figures out which project you're in from
  your current directory. Per-project settings live inside the repo itself.
- **Project-type aware** — first-class support for Laravel, Node, Python and .NET, plus
  a `generic` mode for everything else.
- **Safe by default** — a `--test` (dry-run) mode previews every action, and destructive
  operations are guarded.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **zsh** | The script uses zsh-only features (`vared`, glob qualifiers, parameter modifiers). It is **not** bash-compatible. |
| **git ≥ 2.5** | For `git worktree` support. |
| Per-type tooling | Installed only for the project type you choose (see below). |

Project-type tooling:

| Type | Needs | Local dev server |
|---|---|---|
| `laravel` | `composer`, `yarn`, and **[Laravel Herd](https://herd.laravel.com/)** (macOS) | Herd site + auto TLS (`*.test`) |
| `node` | `npm` / `yarn` / `pnpm` (auto-detected from lockfile) | — |
| `python` | `python3` + `pip`, or `poetry` | — |
| `dotnet` | `dotnet` SDK | — |
| `generic` | nothing — just git worktrees | — |

> **Platform note:** the `laravel` driver is **macOS-specific** (it uses Laravel Herd
> paths and BSD `sed`). The `node`, `python`, `dotnet`, and `generic` drivers have no
> such dependency.

---

## Installation

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
mkdir -p ~/projects/laravel/myapp && cd $_

# 2. One-time setup: clone the bare repo, create the reference worktree,
#    install deps, and (for Laravel) wire up the dev server.
gwt init

# 3. From now on, work on any branch in its own folder:
gwt feature/login              # check out an existing branch
gwt my-experiment staging      # create a new branch off "staging" and check it out

# 4. See everything:
gwt list

# 5. Clean up when done:
gwt remove my-experiment
```

---

## Commands

```
gwt init                 First-time project setup, in the CURRENT folder:
                         clone a bare repo, create the reference worktree,
                         set up .env, link the dev server, and install
                         dependencies. Run once per project.

gwt <branch>             Check out an existing branch as a new worktree,
                         sharing vendor/ + node_modules/ (symlinked) from
                         the reference worktree.

gwt <branch> <base>      Create <branch> off <base>, then check it out as
                         a new worktree.

gwt list                 List all worktrees of the current project.

gwt remove <branch>      Remove a worktree: tear down its dev-server link
                         and dependency symlinks, then delete it.

gwt help | -h | --help   Show help.
```

### Flags

| Flag | Applies to | Effect |
|---|---|---|
| `--test`, `--dry` | any command | Preview everything without making changes. |
| `--force` | `remove` | Also delete **real** (non-symlinked) dependency directories. |

---

## How it works

### The layout

`gwt init` turns the **current directory** into a project folder:

```
<cwd>/
├── <project>.git/          ← bare clone (no working tree, just the git database)
└── <project>-<ref>/        ← the "reference" worktree (e.g. myapp-staging)
```

Every later `gwt <branch>` adds a sibling worktree `<project>-<branch>/` next to it.

### Shared dependencies

The **reference worktree** is the only one with real `vendor/` / `node_modules/` /
`.venv/`. Every other worktree gets these as **symlinks** pointing back to the
reference. That's why new worktrees are instant and cheap — and why you should run
`gwt init` once to populate the reference.

> If a branch changes its dependencies, re-run the install in that worktree
> (`composer install`, `yarn install`, etc.) to give it real, independent deps.

### No global config

There is **no config file**. The active project is derived from where you are:

- `gwt init` is run from the folder you want the project created in.
- Every other command derives the project from your current directory (a worktree, or
  the project folder itself) via `git rev-parse`.
- The two per-project settings — **type** and **reference branch** — are stored in the
  bare repo's own git config (`gwt.type`, `gwt.ref`), so they travel with the repo and
  never collide between projects.

This means you can use `gwt` across any number of projects with zero shared state — just
`cd` into the one you want.

---

## Examples

Preview an init without touching anything:

```sh
gwt init --test
```

Create a hotfix branch off `main` and work on it:

```sh
cd ~/projects/laravel/myapp/myapp-staging   # anywhere inside the project
gwt hotfix/urgent main
```

Remove a worktree, including real dep folders if it has any:

```sh
gwt remove hotfix/urgent --force
```

---

## Extending: adding a new project type

The core flow is type-agnostic. Each type is just a set of *driver* functions named
`_gwt_<type>_<action>`; anything a type doesn't define falls back to a no-op `generic`
implementation. To add, say, a `rust` type, define the actions you care about:

```zsh
_gwt_rust_ref_default()  { echo "main"; }
_gwt_rust_dep_dirs()     { echo "target"; }     # dirs to share via symlink
_gwt_rust_install_deps() { local dir="$1"; ( cd "$dir" && cargo fetch ); }
```

…and add a line to the `_gwt_prompt_project_type` menu. Nothing in the core flow
changes.

> **zsh gotcha for contributors:** do **not** name a local variable `path` — in zsh
> `path` is tied to `$PATH`, and assigning a directory to it wipes your command search
> path. Use `dir` (as the drivers do).

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Error: not inside a gwt project` | Run the command from inside the project (a worktree or the project folder), or run `gwt init` to create one. |
| `command not found: vite` (or similar) after a worktree checkout | The reference worktree's deps are missing. Re-run `gwt init` (idempotent) or `composer install && yarn install` in the reference worktree. |
| `herd secure failed` | Laravel Herd isn't installed/running, or the site isn't linked. Run `herd secure <domain>` manually. |
| Arrow keys print `^[[D` in prompts | You're on an older copy — prompts use `vared` (ZLE), which supports arrow keys/history. Re-source the latest `gwt.zsh`. |

---

## License

MIT — do whatever you like.
