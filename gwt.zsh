# ---------------------------------------------------------------------------
# gwt — git worktree manager for Laravel (bare-clone pattern)
#
# Worktrees that work like cheap branches: every branch gets its own folder
# and its OWN independent dependencies (installed via the project's [install]
# cmd), so branches never interfere with each other — no stash dance.
#
# gwt is tuned for Laravel + Laravel Herd on macOS: every branch becomes its
# own <project>-<branch>.test site with per-branch TLS, driven entirely by a
# single APP_DOMAIN value in the worktree's .env / .env.testing. All project
# behaviour lives in a per-project config file:
#
#       <project>.git/gwt.conf       (local only — never committed)
#
# parsed with git's own INI reader (`git config --file`). The file declares
# what to copy, how to install, how to run the dev server, plus shell hooks.
# See `gwt help` and the examples/ directory.
# ---------------------------------------------------------------------------

# oh-my-zsh git plugin aliases gwt → "git worktree"; remove it so our
# function definition below is not blocked.
unalias gwt 2>/dev/null

# Daily action log lives next to this script (…/logs/DD-MM-YYYY.log), so the new
# ~/.zsh/gwt/ layout keeps gwt.zsh, examples and logs together. %x is this
# sourced file's path; :A:h resolves it to the real directory. Overridable.
_GWT_LOG_DIR="${GWT_LOG_DIR:-${${(%):-%x}:A:h}/logs}"

# gwt holds NO global state. There is no shared/global config file. The active
# project is derived from the current directory (see _gwt_load_context). The
# reference branch lives in the bare repo's git config (gwt.ref); everything
# else lives in the bare repo's local gwt.conf. Both travel with the bare repo
# and never collide between projects.

# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------

# Normalise a branch name to a URL/folder-safe slug.
# feature/PROJ-5031 → proj-5031
# hotfix/PROJ-99    → proj-99
# staging           → staging
_gwt_normalize() {
  local branch="$1"
  branch="${branch##*/}"   # strip prefix up to and including last /
  branch="${branch:l}"     # lowercase
  branch="${branch//_/-}"  # underscores → dashes
  echo "$branch"
}

# Identifier-safe resource name for a worktree: <project>_<slug>, with every
# character outside [A-Za-z0-9_] folded to '_'. Database names, cache prefixes
# and cookie names all have to be plain identifiers, so they share this one
# spelling — that way the name gwt creates is the name the env points at.
_gwt_ident() {
  local s="${GWT_PROJECT}_$1"
  echo "${s//[^A-Za-z0-9_]/_}"
}

# True if the bare repo has the given LOCAL branch.
_gwt_branch_exists() {
  git -C "$GWT_BARE_ROOT" show-ref --verify --quiet "refs/heads/$1" 2>/dev/null
}

# True if the bare repo has a remote-tracking branch origin/<branch>. New
# branches pushed AFTER the bare clone land only under refs/remotes/origin/*
# (per the fetch refspec), never as a local head — so this is how we spot a
# branch that exists "on the remote" but not yet locally.
_gwt_remote_branch_exists() {
  git -C "$GWT_BARE_ROOT" show-ref --verify --quiet "refs/remotes/origin/$1" 2>/dev/null
}

# Derive the active project from the current directory and populate the GWT_*
# vars (callers declare them local). Returns non-zero when the CWD is not
# inside — or alongside — a gwt-managed bare-clone project.
#
# Resolution order:
#   1. The common git dir of the worktree we're standing in, if it follows the
#      bare-clone naming (<project>.git, not a normal repo's ".git").
#   2. A single <project>.git bare directory sitting in the CWD (lets you run
#      from the project's parent folder).
_gwt_load_context() {
  local c common_dir=""
  c="$(git rev-parse --git-common-dir 2>/dev/null)"
  if [[ -n "$c" ]]; then
    c="${c:A}"
    [[ "${c:t}" == *.git && "${c:t}" != ".git" ]] && common_dir="$c"
  fi
  if [[ -z "$common_dir" ]]; then
    local matches=( *.git(N/) )
    (( ${#matches} == 1 )) && common_dir="${matches[1]:A}"
  fi
  [[ -n "$common_dir" ]] || return 1

  GWT_BARE_ROOT="$common_dir"
  GWT_WORKTREE_PARENT="${common_dir:h}"
  GWT_PROJECT="${${common_dir:t}%.git}"
  GWT_REF_WORKTREE="$(git -C "$GWT_BARE_ROOT" config gwt.ref 2>/dev/null)"
  [[ -n "$GWT_REF_WORKTREE" ]] || GWT_REF_WORKTREE="main"
  return 0
}

# ---------------------------------------------------------------------------
# Config (local-only, lives in the bare dir, parsed by git's INI reader)
# ---------------------------------------------------------------------------

# Path to the project's local config file.
_gwt_conf_path() { echo "$GWT_BARE_ROOT/gwt.conf"; }

# Read a single config value: _gwt_cfg <section.key> [default]
_gwt_cfg() {
  local key="$1" def="$2" val
  val="$(git config --file "$GWT_BARE_ROOT/gwt.conf" --get "$key" 2>/dev/null)"
  if [[ -n "$val" ]]; then echo "$val"; else echo "$def"; fi
}

# Read all values for a repeatable key (deps.heavy, env.copy):
# _gwt_cfg_all <section.key>
_gwt_cfg_all() {
  git config --file "$GWT_BARE_ROOT/gwt.conf" --get-all "$1" 2>/dev/null
}

# Expand a config string ($GWT_DIR/$GWT_DOMAIN/… ) for the given slug.
#
# ONLY the $GWT_* tokens are substituted — every other shell reference is left
# verbatim. This matters for [env] set values like  APP_URL="https://${APP_DOMAIN}"
# where ${APP_DOMAIN} must survive into the .env file as a real dotenv reference,
# not be expanded here. (The previous version eval'd the whole string, which both
# dropped non-GWT ${…} refs — turning them into empty strings — and was an
# eval-injection footgun.) Plain string replacement, no eval.
_gwt_expand() {
  local s="$1" slug="$2" k
  local -A vals=(
    GWT_WORKTREE_PARENT "$GWT_WORKTREE_PARENT"
    GWT_REF_IDENT       "$(_gwt_ident "$(_gwt_normalize "$GWT_REF_WORKTREE")")"
    GWT_REF_DIR         "$GWT_WORKTREE_PARENT/${GWT_PROJECT}-${GWT_REF_WORKTREE}"
    GWT_PROJECT         "$GWT_PROJECT"
    GWT_DOMAIN          "${GWT_PROJECT}-${slug}"
    GWT_IDENT           "$(_gwt_ident "$slug")"
    GWT_SLUG            "$slug"
    GWT_DIR             "$GWT_WORKTREE_PARENT/${GWT_PROJECT}-${slug}"
    GWT_REF             "$GWT_REF_WORKTREE"
  )
  # Longest names first so $GWT_REF doesn't partially match inside $GWT_REF_DIR
  # or $GWT_REF_IDENT. Replace both the ${NAME} and bare $NAME spellings.
  for k in GWT_WORKTREE_PARENT GWT_REF_IDENT GWT_REF_DIR GWT_PROJECT GWT_DOMAIN GWT_IDENT GWT_SLUG GWT_DIR GWT_REF; do
    s="${s//\$\{$k\}/${vals[$k]}}"
    s="${s//\$$k/${vals[$k]}}"
  done
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Command runner
#
# _gwt_run_cmd <label> <cmd> <dir> <slug>
# Runs a config-defined command inside <dir> with the gwt context exported, or
# previews it in --test/--dry mode. No-op when <cmd> is empty.
# ---------------------------------------------------------------------------
_gwt_run_cmd() {
  local label="$1" cmd="$2" dir="$3" slug="$4"
  [[ -z "$cmd" ]] && return 0
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] $label: $cmd"
    return 0
  fi
  echo "  [..] $label…"
  if ( cd "$dir" \
        && export GWT_DIR="$dir" \
                  GWT_PROJECT="$GWT_PROJECT" \
                  GWT_SLUG="$slug" \
                  GWT_DOMAIN="${GWT_PROJECT}-${slug}" \
                  GWT_IDENT="$(_gwt_ident "$slug")" \
                  GWT_REF="$GWT_REF_WORKTREE" \
                  GWT_REF_DIR="$GWT_WORKTREE_PARENT/${GWT_PROJECT}-${GWT_REF_WORKTREE}" \
                  GWT_REF_IDENT="$(_gwt_ident "$(_gwt_normalize "$GWT_REF_WORKTREE")")" \
        && eval "$cmd" ); then
    echo "  [ok] $label complete"
  else
    echo "  [error] $label failed — run it manually inside $dir"
  fi
}

# ---------------------------------------------------------------------------
# Desktop notification
#
# _gwt_notify <title> <message> [sound]
# Prefers terminal-notifier (its own app identity → banners show reliably). Falls
# back to osascript's `display notification`, which is built-in but only appears if
# "Script Editor" notifications are enabled in System Settings ▸ Notifications.
# Full binary paths so it works even from a freshly-sourced background shell.
# ---------------------------------------------------------------------------
_gwt_notify() {
  local title="$1" message="$2" sound="$3" tn osa
  if tn="$(command -v terminal-notifier 2>/dev/null)" && [[ -n "$tn" ]]; then
    "$tn" -title "$title" -message "$message" ${sound:+-sound "$sound"} >/dev/null 2>&1
    return 0
  fi
  osa="display notification \"$message\" with title \"$title\""
  [[ -n "$sound" ]] && osa="$osa sound name \"$sound\""
  /usr/bin/osascript -e "$osa" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Daily action log
#
# _gwt_log <action> <detail...>
# Appends one timestamped line to today's log (~/.zsh/gwt/logs/DD-MM-YYYY.log by
# default), recording what the user did: add / remove / install. The date lives
# in the filename, so each line carries only the time → entries stay short. No-op
# in dry mode; never fails the caller (a broken log must not break gwt).
# ---------------------------------------------------------------------------
_gwt_log() {
  [[ -n "$_GWT_DRY" || -z "$_GWT_LOG_DIR" ]] && return 0
  mkdir -p "$_GWT_LOG_DIR" 2>/dev/null || return 0
  print -r -- "$(date '+%H:%M:%S')  $*" >> "$_GWT_LOG_DIR/$(date '+%d-%m-%Y').log"
}

# ---------------------------------------------------------------------------
# Background install runner
#
# _gwt_run_install <cmd> <dir> <slug>
# The install step (composer/yarn) is slow, so we don't make the user wait on it
# or tie up the terminal. We run it DETACHED in the background: the job sources
# ~/.zshrc first (so PATH + version managers + composer/yarn/herd resolve exactly
# as in an interactive shell), runs the install inside <dir> with the gwt context
# exported, writes output to a log, and fires a desktop notification when it
# finishes. gwt returns control immediately.
#
# The [hooks] post-install command runs here too, right after the install
# succeeds — and this is the ONLY place it can run. Anything that needs vendor/
# (artisan migrate, say) cannot go in post-create, because post-create fires
# before the install that creates vendor/ in the first place.
#
# Locals are underscore-prefixed because the job re-sources ~/.zshrc, which could
# otherwise clobber common names like `cmd`/`dir`/`name` mid-flight.
# ---------------------------------------------------------------------------
_gwt_run_install() {
  local _gi_cmd="$1" _gi_dir="$2" _gi_slug="$3"
  local _gi_post
  _gi_post="$(_gwt_cfg hooks.post-install)"
  [[ -z "$_gi_cmd" && -z "$_gi_post" ]] && return 0
  if [[ -n "$_GWT_DRY" ]]; then
    [[ -n "$_gi_cmd" ]] && \
      echo "  [dry] install dependencies (background, source ~/.zshrc, notify on done): $_gi_cmd"
    [[ -n "$_gi_post" ]] && \
      echo "  [dry] post-install hook (background, after install, database-guarded): $_gi_post"
    return 0
  fi

  local _gi_name="${GWT_PROJECT}-${_gi_slug}"
  local _gi_ident _gi_ref_ident _gi_log
  _gi_ident="$(_gwt_ident "$_gi_slug")"
  _gi_ref_ident="$(_gwt_ident "$(_gwt_normalize "$GWT_REF_WORKTREE")")"
  _gi_log="${_GWT_LOG_DIR:-${TMPDIR:-/tmp}}/${_gi_name}-install.log"
  [[ -n "$_GWT_LOG_DIR" ]] && mkdir -p "$_GWT_LOG_DIR" 2>/dev/null

  # Everything the post-install guard needs is resolved HERE, in the foreground,
  # into plain strings. The background job must not have to reach back into git
  # config after re-sourcing ~/.zshrc.
  local _gi_guard_key="" _gi_guard_files="" _gi_allowed=""
  if [[ "$(_gwt_db_driver)" != none ]]; then
    _gi_guard_key="$(_gwt_cfg db.guard DB_DATABASE)"
    _gi_guard_files="$(_gwt_cfg_all env.copy)"
    _gi_allowed="$(_gwt_res_get "$_gi_slug" db)"
  fi

  # Detached subshell: &! = background + disown (zsh), so it outlives this shell.
  (
    # Source the interactive env FIRST (as requested), THEN cd — so a dotfile that
    # changes directory on load can't move the install out of the worktree.
    source "$HOME/.zshrc" >/dev/null 2>&1
    cd "$_gi_dir" || exit 1
    export GWT_DIR="$_gi_dir" \
           GWT_PROJECT="$GWT_PROJECT" \
           GWT_SLUG="$_gi_slug" \
           GWT_DOMAIN="${GWT_PROJECT}-${_gi_slug}" \
           GWT_IDENT="$_gi_ident" \
           GWT_REF="$GWT_REF_WORKTREE" \
           GWT_REF_DIR="$GWT_WORKTREE_PARENT/${GWT_PROJECT}-${GWT_REF_WORKTREE}" \
           GWT_REF_IDENT="$_gi_ref_ident"

    # Defined AFTER the source, so no dotfile can take it away — and so the job
    # still reports itself even if gwt failed to re-load in this shell.
    # _gi_report <log line> <notification> <sound>
    _gi_report() {
      print -r -- "$(date '+%H:%M:%S')  $1" >> "$_gi_log"
      whence -f _gwt_log    >/dev/null 2>&1 && _gwt_log    "$1"
      whence -f _gwt_notify >/dev/null 2>&1 && _gwt_notify "gwt · $_gi_name" "$2" "$3"
      return 0
    }

    if [[ -n "$_gi_cmd" ]]; then
      if ! eval "$_gi_cmd" >>"$_gi_log" 2>&1; then
        _gi_report "install  $_gi_name  FAILED" \
                   "Install FAILED — see ${_gi_log:t}." "Basso"
        exit 1
      fi
      print -r -- "$(date '+%H:%M:%S')  install  $_gi_name  ok" >> "$_gi_log"
      whence -f _gwt_log >/dev/null 2>&1 && _gwt_log "install  $_gi_name  ok"
    fi

    if [[ -z "$_gi_post" ]]; then
      _gi_report "install  $_gi_name  done" "Dependencies installed — ready to go." "Glass"
      exit 0
    fi

    # ── Guard the post-install hook ──
    # This hook is where migrations run, and migrate:fresh drops every table it
    # can reach. Refuse to run it unless the env on disk names a database gwt
    # created for THIS worktree. Fail CLOSED: if the guard itself is unavailable
    # (gwt did not re-load here), skip the hook rather than run it unchecked.
    if ! whence -f _gwt_guard_env_matches >/dev/null 2>&1; then
      _gi_report "post-install  $_gi_name  SKIPPED (gwt not loaded in background shell)" \
                 "Deps installed. Post-install SKIPPED — could not verify the database." "Basso"
      exit 1
    fi
    if ! _gwt_guard_env_matches "$_gi_dir" "$_gi_guard_key" "$_gi_guard_files" "$_gi_allowed"; then
      _gi_report "post-install  $_gi_name  REFUSED (env does not name this worktree's database)" \
                 "Deps installed. Post-install REFUSED — env is not pointing at this worktree's own database." "Basso"
      exit 1
    fi

    if eval "$_gi_post" >>"$_gi_log" 2>&1; then
      _gi_report "post-install  $_gi_name  ok" \
                 "Dependencies installed, database ready." "Glass"
    else
      _gi_report "post-install  $_gi_name  FAILED" \
                 "Post-install FAILED — see ${_gi_log:t}." "Basso"
      exit 1
    fi
  ) &!

  echo "  [..] install dependencies running in the background (PID $!)"
  [[ -n "$_gi_post" ]] && echo "       post-install hook runs after it, once the database is verified"
  echo "       a desktop notification will fire when it's done"
  echo "       log: ${_gi_log/#$HOME/~}"
}

# Run a plain command, or just print it when in --test/--dry mode.
_gwt_run() {
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Dependency helpers
#
# Every worktree installs its OWN real dependencies (via [install] cmd) — gwt no
# longer symlinks deps from a reference worktree. Sharing a dir like vendor/ via
# symlink breaks tools that resolve paths through it (e.g. PHP's Composer
# autoloader derives the app's base path from the real vendor location, so a
# symlinked vendor makes every worktree load code from the link's target). Real,
# independent deps per worktree are correct and predictable.
#
# [deps] heavy = <dir> still lists the heavy, gitignored dep dirs — used only to
# guard removal (don't silently delete real deps) and to report sizes.
# ---------------------------------------------------------------------------

# Return 0 (true) if any declared heavy dep dir exists in the worktree.
_gwt_check_real_deps() {
  local dir="$1" d
  for d in $(_gwt_cfg_all deps.heavy); do
    [[ -d "$dir/$d" && ! -L "$dir/$d" ]] && return 0
  done
  return 1
}

# Human-readable list of heavy dep dirs ("vendor, node_modules").
_gwt_dep_list() {
  local d out=""
  for d in $(_gwt_cfg_all deps.heavy); do
    out="${out:+$out, }$d"
  done
  echo "$out"
}

# Remove any symlinks in the bare repo's SHARED hooks/ dir that point into the
# worktree being removed. git hooks live in $GWT_BARE_ROOT/hooks (shared by all
# worktrees via --git-common-dir); a project's hook installer often symlinks
# them there pointing into whichever worktree ran it. When that worktree is
# deleted, those links dangle and break the next hook-install run. We clean ours
# up generically — without the project ever changing its installer.
_gwt_unlink_worktree_hooks() {
  local wt="$1" hooks_dir="$GWT_BARE_ROOT/hooks" l tgt
  [[ -d "$hooks_dir" ]] || return 0
  # Compare on resolved absolute paths so a /tmp ↔ /private/tmp (macOS) or other
  # symlinked-prefix difference between the worktree path and the link target
  # doesn't defeat the match. ${x:A} resolves symlinks + makes absolute.
  local wt_real="${wt:A}"
  for l in "$hooks_dir"/*(N@); do          # N@ = symlinks only, no error if none
    tgt="$(readlink "$l")"
    local tgt_real="${tgt:A}"
    # Match links whose target lives inside the worktree being removed.
    if [[ "$tgt_real" == "$wt_real"/* || "$tgt_real" == "$wt_real" ]]; then
      if [[ -n "$_GWT_DRY" ]]; then
        echo "  [dry] remove hook symlink ${l:t} → $tgt"
      else
        rm -f "$l"
        echo "  [ok] Removed hook symlink: ${l:t}"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Env-file helpers — driven by [env] copy = … (gitignored local files).
# ---------------------------------------------------------------------------

# Reference worktree: seed each env file from its .example sibling if missing.
_gwt_init_env() {
  local dir="$1" f
  for f in $(_gwt_cfg_all env.copy); do
    if [[ -f "$dir/$f" ]]; then
      echo "  [ok] $f found"
    elif [[ -f "$dir/$f.example" ]]; then
      if [[ -n "$_GWT_DRY" ]]; then
        echo "  [dry] copy $f.example → $f"
      else
        cp "$dir/$f.example" "$dir/$f"
        echo "  [ok] Copied $f.example → $f"
        echo "  [!]  Review $f for environment-specific values"
      fi
    else
      echo "  [info] No $f / $f.example — skipping"
    fi
  done
}

# New worktree: copy each env file from the reference worktree if missing.
_gwt_copy_env() {
  local ref_path="$1" dir="$2" f
  for f in $(_gwt_cfg_all env.copy); do
    if [[ -n "$_GWT_DRY" ]]; then
      echo "  [dry] copy $f from $GWT_REF_WORKTREE (if present)"
      continue
    fi
    if [[ -f "$dir/$f" ]]; then
      echo "  [warn] $f already exists — skipping copy"
    elif [[ -f "$ref_path/$f" ]]; then
      cp "$ref_path/$f" "$dir/$f"
      echo "  [ok] Copied $f from $GWT_REF_WORKTREE"
    else
      echo "  [info] No $f in reference worktree — skipping"
    fi
  done
}

# ---------------------------------------------------------------------------
# Per-worktree env tweaks — driven by [env] set = KEY=VALUE (repeatable).
#
# This replaces hand-written sed in [hooks] post-create for the common case of
# "point this worktree's env at its own values". VALUE is expanded with the gwt
# context vars ($GWT_DOMAIN, $GWT_DIR, …), then written into every [env] copy
# file: the existing KEY= line is replaced in place, or the key is appended.
# ---------------------------------------------------------------------------

# Set KEY=VALUE in an env file (replace the first KEY= line, else append).
# Pure zsh — no sed/awk — so values with slashes, spaces, or quotes are safe.
_gwt_env_put() {
  local file="$1" key="$2" value="$3" line found=0
  local -a out=()
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ! found )) && [[ "$line" == "${key}="* ]]; then
      out+=("${key}=${value}"); found=1
    else
      out+=("$line")
    fi
  done < "$file"
  (( found )) || out+=("${key}=${value}")
  # Write through a temp file and rename. The install and post-install hooks run
  # in the BACKGROUND while gwt re-asserts env here, so a truncate-then-write
  # would let a booting artisan read a half-empty .env. Rename is atomic.
  local tmp="${file}.gwt-tmp.$$" mode
  mode="$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null)"
  print -rl -- "${out[@]}" > "$tmp" || { rm -f "$tmp"; return 1; }
  [[ -n "$mode" ]] && chmod "$mode" "$tmp" 2>/dev/null
  mv -f "$tmp" "$file"
}

# Read KEY's value out of an env file, with any surrounding quotes stripped.
# Empty when the file or the key is missing. Used by the post-install guard,
# which has to know what the worktree ACTUALLY points at — not what gwt.conf
# says it should point at.
_gwt_env_get() {
  local file="$1" key="$2" line val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "${key}="* ]]; then
      val="${line#*=}"
      val="${val#[\"\']}"; val="${val%[\"\']}"
      print -r -- "$val"
      return 0
    fi
  done < "$file"
  return 0
}

# Apply a single KEY=VALUE directive to the given env files.
_gwt_apply_env_directive() {
  local directive="$1" slug="$2" dir="$3" label="$4"; shift 4
  local -a files=("$@")
  local key val f
  [[ -z "$directive" || "$directive" != *=* ]] && return 0
  key="${directive%%=*}"
  val="$(_gwt_expand "${directive#*=}" "$slug")"
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] set $key=$val in ${label:-env files}"
    return 0
  fi
  for f in "${files[@]}"; do
    [[ -f "$dir/$f" ]] && _gwt_env_put "$dir/$f" "$key" "$val"
  done
  echo "  [ok] Set $key=$val${label:+  ($label)}"
}

# Apply every [env] set directive to each [env] copy file inside <dir>, then
# every per-file [env "<file>"] set directive to that one file.
#
# The per-file form exists because a single global value cannot express the one
# thing a Laravel worktree most needs: .env and .env.testing must point at
# DIFFERENT databases. git's INI reader treats the quoted name as a subsection,
# so [env ".env.testing"] set = … reads back as env..env.testing.set.
_gwt_apply_env() {
  local dir="$1" slug="$2" directive f
  local -a copies=( ${(f)"$(_gwt_cfg_all env.copy)"} )

  for directive in ${(f)"$(_gwt_cfg_all env.set)"}; do
    _gwt_apply_env_directive "$directive" "$slug" "$dir" "" "${copies[@]}"
  done

  for f in "${copies[@]}"; do
    [[ -z "$f" ]] && continue
    for directive in ${(f)"$(_gwt_cfg_all "env.$f.set")"}; do
      _gwt_apply_env_directive "$directive" "$slug" "$dir" "$f" "$f"
    done
  done
}

# ---------------------------------------------------------------------------
# Per-worktree resources — databases and Redis, driven by [db] and [redis].
#
# Isolating files and the hostname is not enough. Two worktrees pointed at the
# same MySQL database and the same Redis index still stomp on each other's
# migrations, cache and queue jobs. So gwt CREATES the backing stores a worktree
# needs and records what it created, in the bare repo's git config:
#
#   gwt.<slug>.db              one entry per database created for this worktree
#   gwt.<slug>.redis-cache-db  the Redis index allocated to this worktree
#
# That ledger is the safety mechanism, not bookkeeping. Removal only ever drops
# what is written there — never a name recomputed from the current config — so
# editing gwt.conf after the fact cannot redirect a drop at the shared project
# database, and an index is never handed to two worktrees at once.
# ---------------------------------------------------------------------------

_gwt_res_get()  { git -C "$GWT_BARE_ROOT" config --get-all "gwt.${1}.${2}" 2>/dev/null; }
_gwt_res_add()  { git -C "$GWT_BARE_ROOT" config --add "gwt.${1}.${2}" "$3" 2>/dev/null; }
_gwt_res_clear() { git -C "$GWT_BARE_ROOT" config --unset-all "gwt.${1}.${2}" 2>/dev/null; return 0; }

# True when <value> is already recorded under gwt.<slug>.<key>.
_gwt_res_has() {
  local slug="$1" key="$2" want="$3" v
  for v in ${(f)"$(_gwt_res_get "$slug" "$key")"}; do
    [[ "$v" == "$want" ]] && return 0
  done
  return 1
}

# Absolute paths of every real (non-bare) worktree in the project.
_gwt_worktree_paths() {
  git -C "$GWT_BARE_ROOT" worktree list --porcelain 2>/dev/null | awk '
    /^worktree /{wt=$2; bare=0}
    /^bare$/{bare=1}
    /^$/{ if (wt != "" && !bare) print wt; wt="" }
    END{ if (wt != "" && !bare) print wt }'
}

# The slug of a worktree path: myapp-feature-login → feature-login.
_gwt_path_slug() {
  local base="${1:t}"
  echo "${base#${GWT_PROJECT}-}"
}

# The configured driver, normalised. "none" (the default) disables every
# database code path, so a project that never opts in behaves exactly as it did
# before any of this existed.
_gwt_db_driver() {
  local d
  d="$(_gwt_cfg db.driver none)"
  case "${d:l}" in
    mysql|mariadb)             echo mysql ;;
    postgres|postgresql|pgsql) echo postgres ;;
    *)                         echo none ;;
  esac
}

# The client binary the configured driver needs.
_gwt_db_bin() {
  case "$(_gwt_db_driver)" in
    mysql)    echo mysql ;;
    postgres) echo psql ;;
    *)        echo "" ;;
  esac
}

# Database names (and charset/collation) are interpolated straight into SQL, so
# they are VALIDATED rather than escaped: anything that is not a plain
# identifier is refused outright. gwt must never be the thing that runs a
# crafted statement on your behalf.
_gwt_db_valid_name() {
  [[ "$1" =~ '^[A-Za-z_][A-Za-z0-9_]{0,63}$' ]]
}

# Run one statement against the SERVER (no database selected). The password
# travels in the environment, never in argv — argv is world-readable via `ps`.
_gwt_db_sql() {
  local sql="$1" host port user pass
  host="$(_gwt_cfg db.host 127.0.0.1)"
  user="$(_gwt_cfg db.user root)"
  pass="$(_gwt_cfg db.password)"
  case "$(_gwt_db_driver)" in
    mysql)
      port="$(_gwt_cfg db.port 3306)"
      MYSQL_PWD="$pass" mysql -h "$host" -P "$port" -u "$user" -N -B -e "$sql"
      ;;
    postgres)
      port="$(_gwt_cfg db.port 5432)"
      PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d postgres -tAqc "$sql"
      ;;
    *) return 1 ;;
  esac
}

_gwt_db_exists() {
  local name="$1" out
  case "$(_gwt_db_driver)" in
    mysql)    out="$(_gwt_db_sql "SHOW DATABASES LIKE '$name'" 2>/dev/null)" ;;
    postgres) out="$(_gwt_db_sql "SELECT 1 FROM pg_database WHERE datname = '$name'" 2>/dev/null)" ;;
    *)        return 1 ;;
  esac
  [[ -n "$out" ]]
}

# Create <name> if absent, then record it against <slug>.
_gwt_db_create_one() {
  local name="$1" slug="$2" charset collation sql
  if ! _gwt_db_valid_name "$name"; then
    echo "  [error] refusing database name '$name' — not a plain identifier"
    return 1
  fi
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] create database '$name' and record it for '$slug'"
    return 0
  fi
  if _gwt_db_exists "$name"; then
    echo "  [ok] database '$name' already exists — adopting it for this worktree"
  else
    case "$(_gwt_db_driver)" in
      mysql)
        charset="$(_gwt_cfg db.charset utf8mb4)"
        collation="$(_gwt_cfg db.collation utf8mb4_unicode_ci)"
        if ! _gwt_db_valid_name "$charset" || ! _gwt_db_valid_name "$collation"; then
          echo "  [error] [db] charset/collation must be plain identifiers"
          return 1
        fi
        sql="CREATE DATABASE \`$name\` CHARACTER SET $charset COLLATE $collation"
        ;;
      postgres)
        sql="CREATE DATABASE \"$name\""
        ;;
    esac
    if _gwt_db_sql "$sql" >/dev/null 2>&1; then
      echo "  [ok] Created database '$name'"
    else
      echo "  [error] could not create database '$name' — is the server running,"
      echo "          and do the [db] host/port/user/password values work?"
      return 1
    fi
  fi
  _gwt_res_has "$slug" db "$name" || _gwt_res_add "$slug" db "$name"
}

# Create every [db] create = … database for <slug>.
_gwt_db_create() {
  local slug="$1" expr name bin rc=0
  [[ "$(_gwt_db_driver)" == none ]] && return 0
  bin="$(_gwt_db_bin)"
  if [[ -z "$_GWT_DRY" ]] && ! command -v "$bin" >/dev/null 2>&1; then
    echo "  [warn] [db] driver is '$(_gwt_db_driver)' but '$bin' is not on PATH —"
    echo "         skipping database setup. This worktree will share whatever"
    echo "         database its env already names."
    return 1
  fi
  for expr in ${(f)"$(_gwt_cfg_all db.create)"}; do
    [[ -z "$expr" ]] && continue
    name="$(_gwt_expand "$expr" "$slug")"
    _gwt_db_create_one "$name" "$slug" || rc=1
  done
  return $rc
}

# True when <name> is recorded for some slug OTHER than <slug>. A database two
# worktrees share has to outlive either of them.
_gwt_db_shared_with_other() {
  local slug="$1" name="$2" line k v other
  for line in ${(f)"$(git -C "$GWT_BARE_ROOT" config --get-regexp '^gwt\..*\.db$' 2>/dev/null)"}; do
    k="${line%% *}"; v="${line#* }"
    [[ "$v" == "$name" ]] || continue
    other="${k#gwt.}"; other="${other%.db}"
    [[ "$other" != "$slug" ]] && return 0
  done
  return 1
}

# Drop the databases recorded for <slug>, then forget them.
_gwt_db_drop() {
  local slug="$1" name ref_slug rc=0
  [[ "$(_gwt_db_driver)" == none ]] && return 0
  ref_slug="$(_gwt_normalize "$GWT_REF_WORKTREE")"
  if [[ "$slug" == "$ref_slug" ]]; then
    echo "  [warn] Refusing to drop databases for the reference worktree."
    return 0
  fi
  for name in ${(f)"$(_gwt_res_get "$slug" db)"}; do
    [[ -z "$name" ]] && continue
    if ! _gwt_db_valid_name "$name"; then
      echo "  [warn] skipping recorded name '$name' — not a plain identifier"
      continue
    fi
    if _gwt_db_shared_with_other "$slug" "$name"; then
      echo "  [warn] database '$name' is also recorded for another worktree — keeping it"
      continue
    fi
    if [[ -n "$_GWT_DRY" ]]; then
      echo "  [dry] drop database '$name'"
      continue
    fi
    case "$(_gwt_db_driver)" in
      mysql)    _gwt_db_sql "DROP DATABASE IF EXISTS \`$name\`" >/dev/null 2>&1 ;;
      postgres) _gwt_db_sql "DROP DATABASE IF EXISTS \"$name\"" >/dev/null 2>&1 ;;
    esac
    if (( $? == 0 )); then
      echo "  [ok] Dropped database '$name'"
    else
      rc=1
      echo "  [warn] Could not drop database '$name' — drop it by hand if you want it gone."
    fi
  done
  [[ -z "$_GWT_DRY" ]] && _gwt_res_clear "$slug" db
  return $rc
}

# ── Redis ──────────────────────────────────────────────────────────────────
# Isolation is by DATABASE INDEX, not by key prefix, because a prefix does not
# actually isolate: Laravel's cache:clear ends in FLUSHDB, and SCAN-based cache
# busting matches patterns the client never prefixes (predis prefixes SSCAN /
# ZSCAN / HSCAN, which take a key argument, but not plain SCAN). Worktrees
# sharing an index therefore wipe each other's cache whatever prefix they write
# under. The prefix is still written on top, as a second layer for the code
# paths that read keys rather than nuke them.
_gwt_redis_enabled() {
  [[ "$(_gwt_cfg redis.isolate none)" == "cache-db" ]]
}

# The index held by <slug>, or the lowest free one in [min,max]. Re-adding a
# worktree keeps the index it already had, so this is idempotent.
_gwt_redis_alloc() {
  local slug="$1" lo hi n line v
  v="$(_gwt_res_get "$slug" redis-cache-db | head -1)"
  if [[ -n "$v" ]]; then echo "$v"; return 0; fi
  lo="$(_gwt_cfg redis.min 1)"
  hi="$(_gwt_cfg redis.max 15)"
  local -A taken=()
  for line in ${(f)"$(git -C "$GWT_BARE_ROOT" config --get-regexp '^gwt\..*\.redis-cache-db$' 2>/dev/null)"}; do
    taken[${line#* }]=1
  done
  for n in {$lo..$hi}; do
    [[ -z "${taken[$n]}" ]] && { echo "$n"; return 0; }
  done
  return 1
}

# Allocate this worktree's Redis index and write the resource values into its
# env files: the index under [redis] env-db, the prefix under [redis] env-prefix.
# These are computed at runtime rather than declared as [env] set directives,
# because the index depends on what every OTHER worktree currently holds.
_gwt_redis_apply() {
  local slug="$1" dir="$2" idx key_db key_prefix prefix f
  _gwt_redis_enabled || return 0
  key_db="$(_gwt_cfg redis.env-db REDIS_CACHE_DB)"
  key_prefix="$(_gwt_cfg redis.env-prefix)"
  prefix="$(_gwt_expand "$(_gwt_cfg redis.prefix '$GWT_IDENT:')" "$slug")"

  if ! idx="$(_gwt_redis_alloc "$slug")"; then
    echo "  [warn] no free Redis index left between [redis] min and max —"
    echo "         this worktree will SHARE a cache index with another one."
    return 1
  fi
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] allocate Redis index $idx → $key_db${key_prefix:+, set $key_prefix=$prefix}"
    return 0
  fi
  _gwt_res_has "$slug" redis-cache-db "$idx" || _gwt_res_add "$slug" redis-cache-db "$idx"
  for f in ${(f)"$(_gwt_cfg_all env.copy)"}; do
    [[ -f "$dir/$f" ]] || continue
    _gwt_env_put "$dir/$f" "$key_db" "$idx"
    [[ -n "$key_prefix" ]] && _gwt_env_put "$dir/$f" "$key_prefix" "$prefix"
  done
  echo "  [ok] Redis index $idx${key_prefix:+  (prefix $prefix)}"
}

# Flush and release the Redis index held by <slug>. FLUSHDB is safe here for
# exactly one reason: the index belongs to this worktree alone.
_gwt_redis_release() {
  local slug="$1" idx host port
  idx="$(_gwt_res_get "$slug" redis-cache-db | head -1)"
  [[ -z "$idx" ]] && return 0
  if [[ "$idx" != <-> ]]; then
    echo "  [warn] recorded Redis index '$idx' is not a number — leaving it alone"
    return 1
  fi
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] FLUSHDB Redis index $idx, then release it"
    return 0
  fi
  host="$(_gwt_cfg redis.host 127.0.0.1)"
  port="$(_gwt_cfg redis.port 6379)"
  if command -v redis-cli >/dev/null 2>&1; then
    if redis-cli -h "$host" -p "$port" -n "$idx" FLUSHDB >/dev/null 2>&1; then
      echo "  [ok] Flushed Redis index $idx"
    else
      echo "  [warn] Could not flush Redis index $idx — is the server running?"
    fi
  fi
  _gwt_res_clear "$slug" redis-cache-db
  echo "  [ok] Released Redis index $idx"
}

# ── Post-install guard ─────────────────────────────────────────────────────
# The post-install hook is where migrations run, and `migrate:fresh` drops every
# table it can reach. So before it runs, the env the worktree ACTUALLY has on
# disk is re-read and every guard key must name a database gwt created for THIS
# worktree. If env wiring failed and a file still points at the shared project
# database, the hook is skipped instead of run.
#
# Inputs are plain strings, not config lookups, so this can run inside the
# detached install shell without reaching back into the bare repo.
_gwt_guard_env_matches() {
  local dir="$1" key="$2" files="$3" allowed="$4" f val a hit
  [[ -z "$key" ]] && return 0        # guard disabled — no database handling
  [[ -z "$allowed" ]] && return 1    # guard on, but gwt created nothing: refuse
  for f in ${(f)files}; do
    [[ -n "$f" && -f "$dir/$f" ]] || continue
    val="$(_gwt_env_get "$dir/$f" "$key")"
    [[ -z "$val" ]] && continue
    hit=0
    for a in ${(f)allowed}; do
      [[ "$val" == "$a" ]] && { hit=1; break }
    done
    (( hit )) || return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Shared items — driven by [copy] shared = <dir> (repeatable).
#
# A shared item is a DIRECTORY living outside the worktrees whose CONTENTS are
# copied into every worktree gwt creates, preserving relative paths:
#
#   .gwt/.idea/workspace.xml            → <worktree>/.idea/workspace.xml
#   .gwt/database/seeders/LocalSeeder.php  → <worktree>/database/seeders/LocalSeeder.php
#   .gwt/phpunit.local.xml              → <worktree>/phpunit.local.xml
#
# So each personal file lands where the app actually expects it, rather than in
# a folder at the worktree root. It is also the only way to seed a NESTED path —
# .idea/workspace.xml, say, which is how you stop PhpStorm re-checking "Analyze
# code" on every freshly created worktree (that setting is per-project workspace
# state, and the IDE has no global default for it).
#
# The directory sits at the project root beside the bare repo, so it is never
# inside a checkout and never needs gitignoring itself. What it copies IN does
# need to be gitignored by the project — `gwt doctor` checks that.
#
# Items are resolved against the project root (the folder holding the bare repo
# and all worktrees) by default. Override the base with [copy] shared_root —
# the gwt context vars ($GWT_WORKTREE_PARENT etc.) are expanded.
# ---------------------------------------------------------------------------

# Base directory the [copy] shared items are resolved against.
_gwt_shared_root() {
  local base
  base="$(_gwt_cfg copy.shared_root)"
  if [[ -n "$base" ]]; then
    _gwt_expand "$base" ""
  else
    echo "$GWT_WORKTREE_PARENT"
  fi
}

# Lay each [copy] shared directory's contents over <dir>, preserving relative
# paths. Existing files in the worktree are left untouched; a missing source is
# skipped with a note rather than treated as an error.
_gwt_copy_shared() {
  local dir="$1" item base src f rel dest
  base="$(_gwt_shared_root)"
  for item in $(_gwt_cfg_all copy.shared); do
    src="$base/$item"
    if [[ -f "$src" ]]; then
      echo "  [warn] shared '$item' is a file — [copy] shared takes a DIRECTORY whose"
      echo "         contents are copied in. Move it inside one and point shared at that."
      continue
    fi
    if [[ ! -d "$src" ]]; then
      echo "  [info] No shared '$item' at ${base/#$HOME/~} — skipping"
      continue
    fi
    # Glob qualifiers: (D) include dotfiles AND descend into dot directories
    # (.idea, .claude), (.) regular files only, (N) an empty match is not an error.
    for f in "$src"/**/*(D.N); do
      # .DS_Store is Finder's per-folder view settings, written into any folder
      # you so much as open. It is never something you want stamped onto a
      # worktree, and deleting them is not durable — the next Finder visit to
      # the shared dir recreates them.
      [[ "${f:t}" == ".DS_Store" ]] && continue
      rel="${f#$src/}"
      dest="$dir/$rel"
      if [[ -n "$_GWT_DRY" ]]; then
        echo "  [dry] copy shared $item → $rel"
      elif [[ -e "$dest" ]]; then
        echo "  [warn] shared '$rel' already exists in worktree — skipping"
      else
        mkdir -p "${dest:h}"
        cp -p "$f" "$dest"
        echo "  [ok] Copied $rel"
      fi
    done
    # Symlinks are reported rather than copied: a link inside a worktree either
    # points back out of it or silently fans one file out across every worktree.
    for f in "$src"/**/*(D@N); do
      echo "  [warn] shared '${f#$src/}' is a symlink — skipped"
    done
  done
}

# ---------------------------------------------------------------------------
# Config scaffolding — writes a starter gwt.conf the first time. It's a Laravel
# + Herd template the user edits; the running tool only ever reads gwt.conf.
# ---------------------------------------------------------------------------

_gwt_conf_header() {
  cat <<'HEADER'
# gwt project config — LOCAL ONLY, never committed (it lives in the bare dir).
#
# git-config INI syntax. Repeatable keys (deps.heavy, env.copy, env.set,
# db.create, copy.shared) may appear many times. Commands ([install] cmd,
# [server] up/down, [hooks] …) and [env] set values are expanded inside the
# target worktree with these variables available:
#
#   $GWT_DIR      absolute path of the worktree the command runs in
#   $GWT_PROJECT  project name            $GWT_SLUG  branch slug
#   $GWT_DOMAIN   <project>-<slug>         $GWT_REF   reference branch name
#   $GWT_REF_DIR  reference worktree path  $GWT_WORKTREE_PARENT  project root
#   $GWT_IDENT    <project>_<slug>, folded to [A-Za-z0-9_] — the spelling used
#                 for database names, cache prefixes and cookie names
#   $GWT_REF_IDENT  the same, for the reference branch
#
# Quote any command containing spaces or shell operators, e.g.
#   up = "herd link $GWT_DOMAIN"
HEADER
}

# The isolation sections live in their own functions so that `gwt config
# upgrade` can append exactly the ones an older project's config is missing,
# from the same source of truth the scaffold uses.

_gwt_conf_block_envfiles() {
  cat <<'EOF'
# Per-file env overrides. A plain [env] set writes the same value into every
# copied file, which cannot express the one thing a Laravel worktree most needs:
# .env and .env.testing must point at DIFFERENT databases. git's INI reader
# treats the quoted name as a subsection, so these apply to that file only.
[env ".env"]
  set = DB_DATABASE=$GWT_IDENT

[env ".env.testing"]
  set = DB_DATABASE=${GWT_IDENT}_test
EOF
}

_gwt_conf_block_hooks() {
  cat <<'EOF'

[hooks]
  # post-install runs in the background AFTER [install] cmd finishes — the only
  # place a command needing vendor/ can go, which makes it where migrations
  # belong. Left commented: read this before enabling it.
  #
  # When [db] driver is set, this hook is GUARDED — gwt re-reads the env on disk
  # and refuses to run it unless [db] guard names a database gwt created for this
  # worktree, so a migrate:fresh cannot land on a shared database. When [db]
  # driver = none there is nothing to check against and the guard is INACTIVE, so
  # the command runs against whatever the env happens to name. Only enable a
  # destructive command here if [db] is managing your databases.
  #
  # post-install = "php artisan migrate:fresh --seed && php artisan migrate:fresh --env=testing --seed && php artisan optimize:clear"
EOF
}

_gwt_conf_block_ide() {
  cat <<'EOF'

[ide]
  # Every worktree is a separate project to PhpStorm and VS Code, and neither has
  # a global default for most of what lives in .idea / .vscode — so a new one
  # starts blank and you reconfigure it by hand. gwt add seeds a new worktree
  # from the reference worktree, and `gwt ide sync`, run INSIDE the worktree whose
  # settings are right, pushes them to all the others (reference included, so the
  # next add inherits them). Set seed = false to stop gwt touching IDE config.
  seed = true

  # Never copied: generated state, or files holding paths into the worktree they
  # came from. commandlinetools stores an absolute path to that worktree's
  # artisan; dataSources and shelf are local query history and shelved changes.
  #
  # <worktree>.iml and modules.xml are NOT listed here — they are handled
  # specially, because .iml is where Settings > Directories lives (source and
  # excluded folder marks) and its contents are fully portable. Only its NAME is
  # per-worktree, so gwt copies the contents under the target's own module name
  # and repoints modules.xml at it.
  skip = commandlinetools
  skip = shelf
  skip = dataSources
  skip = dataSources.xml
  skip = dataSources.local.xml
  skip = httpRequests
  skip = sonarlint
  skip = .DS_Store

  # .idea/workspace.xml is MERGED component by component, not copied — each of
  # these components is per-project state rather than settings. Cloning them
  # would give every worktree the same ProjectId, and hand one worktree's run
  # configs and last-opened path to all the rest. <MESSAGE> children are dropped
  # from whatever IS synced: in VcsManagerConfiguration those are your local
  # commit-message history, not a setting.
  workspace-skip = ProjectId
  workspace-skip = RunManager
  workspace-skip = ChangeListManager
  workspace-skip = TaskManager
  workspace-skip = PropertiesComponent
EOF
}

_gwt_conf_block_db() {
  cat <<'EOF'

[db]
  # Per-worktree databases. gwt creates each one (empty) on `gwt add`, records
  # what it created in the bare repo, and the [env] set directives above point
  # the worktree at them. Set driver = none to turn all of this off.
  driver    = mysql
  host      = 127.0.0.1
  port      = 3306
  user      = root
  password  =
  charset   = utf8mb4
  collation = utf8mb4_unicode_ci

  # Repeatable — one line per database this worktree needs.
  create = $GWT_IDENT
  create = ${GWT_IDENT}_test

  # Safety interlock for [hooks] post-install. Before that hook runs, this env
  # key is read back out of every copied env file and must name a database gwt
  # created for THIS worktree. It is what stops a migrate:fresh from landing on
  # the shared project database when env wiring has gone wrong.
  guard = DB_DATABASE

  # never | force | always — when `gwt remove` may drop these databases.
  # Only ever drops names gwt recorded; never the reference worktree's.
  drop-on-remove = force
EOF
}

_gwt_conf_block_redis() {
  cat <<'EOF'

[redis]
  # Give each worktree its own Redis database index for the CACHE connection.
  # A key prefix alone does NOT isolate: Laravel's cache:clear ends in FLUSHDB,
  # and SCAN-based cache busting matches patterns the client never prefixes — so
  # worktrees sharing an index wipe each other's cache whatever prefix they use.
  # The index is allocated on add and released on remove. Set isolate = none off.
  isolate = cache-db
  host    = 127.0.0.1
  port    = 6379
  min     = 1
  max     = 15

  # Env keys that receive the allocated index and the prefix. Both already exist
  # in a stock Laravel config and default to today's values, so a developer who
  # never sets them sees no change at all.
  env-db     = REDIS_CACHE_DB
  env-prefix = CACHE_PREFIX
  prefix     = $GWT_IDENT:

  # never | force | always — when `gwt remove` may FLUSHDB and release the index.
  flush-on-remove = force
EOF
}

# The Laravel + Laravel Herd (macOS) template. Edit to taste after init.
_gwt_conf_body() {
  cat <<'EOF'

# Heavy dep dirs are installed REAL & independent in every worktree. Do NOT
# symlink vendor between worktrees: Composer's autoloader derives the app's base
# path from the real vendor location, so a shared vendor makes all worktrees load
# code from one place.
[deps]
  heavy = vendor
  heavy = node_modules

[install]
  cmd = "composer install && yarn install"   # runs in EACH new worktree

[env]
  # Gitignored env files. Copied from the reference worktree when present,
  # otherwise seeded from the matching *.example (.env ← .env.example, etc.).
  copy = .env
  copy = .env.testing

  # Per-worktree overrides written into every copied env file above (the KEY=
  # line is replaced, or appended if absent). Only $GWT_* tokens are expanded;
  # any other ${VAR} is kept verbatim, so it stays a real dotenv reference.
  # Point this branch at its own *.test host — this is the single source of truth
  # for the host; APP_URL and the Herd TLS cert paths reference ${APP_DOMAIN}:
  set = APP_DOMAIN=$GWT_DOMAIN.test
  # Keep APP_URL as a ${APP_DOMAIN} reference (matching .env.example) rather than a
  # flattened literal. gwt re-asserts every [env] set AFTER the dev server starts,
  # because `herd link` rewrites APP_URL on disk — dropping the reference and
  # downgrading https→http — and the re-assert restores this declared value:
  set = APP_URL=\"https://${APP_DOMAIN}\"
  # Per-worktree session cookie. Sessions are isolated today only by accident:
  # the file driver writes into this worktree's own storage/, and separate *.test
  # hosts get separate cookie jars. Switch SESSION_DRIVER to redis or database
  # and every worktree would share one store under one cookie name. Naming the
  # cookie per worktree makes the isolation deliberate instead of incidental.
  set = SESSION_COOKIE=${GWT_IDENT}_session

EOF
  _gwt_conf_block_envfiles
  _gwt_conf_block_ide
  _gwt_conf_block_db
  _gwt_conf_block_redis
  cat <<'EOF'

[copy]
  # A directory at the project root whose CONTENTS are copied into EACH new
  # worktree and the reference worktree at init, PRESERVING relative paths:
  #
  #   .gwt/.idea/workspace.xml            → .idea/workspace.xml
  #   .gwt/database/seeders/LocalSeeder.php  → database/seeders/LocalSeeder.php
  #   .gwt/phpunit.local.xml              → phpunit.local.xml
  #
  # So each personal file lands where the app expects it. The directory sits
  # beside the bare repo, so it is never inside a checkout. Repeatable; existing
  # files in the worktree are left untouched, and symlinks are skipped.
  #
  # Seeding .idea/workspace.xml with
  #   <component name="VcsManagerConfiguration">
  #     <option name="CHECK_CODE_SMELLS_BEFORE_PROJECT_COMMIT" value="false" />
  #   </component>
  # is how you stop PhpStorm re-checking "Analyze code" on every new worktree —
  # that setting is per-project workspace state with no global default.
  shared = .gwt

  # Base directory the shared items resolve against (default: the project root).
  # shared_root = $GWT_WORKTREE_PARENT

[server]
  url  = "https://$GWT_DOMAIN.test"
  up   = "herd link $GWT_DOMAIN && herd secure $GWT_DOMAIN"
  down = "herd unsecure $GWT_DOMAIN 2>/dev/null; herd unlink $GWT_DOMAIN 2>/dev/null"

[hooks]
  # Laravel needs bootstrap/cache to exist before artisan/composer scripts run.
  post-create = "mkdir -p bootstrap/cache"

  # post-install runs in the background AFTER [install] cmd finishes — the only
  # place a command needing vendor/ can go, which makes it where migrations
  # belong. Commented out because you should read this first:
  #
  # When [db] driver is set, this hook is GUARDED — gwt re-reads the env on disk
  # and refuses to run it unless [db] guard names a database gwt created for this
  # worktree, so a migrate:fresh cannot land on a shared database. When [db]
  # driver = none there is nothing to check against and the guard is INACTIVE, so
  # the command runs against whatever the env happens to name. Only enable a
  # destructive command here if [db] is managing your databases.
  #
  # post-install = "php artisan migrate:fresh --seed && php artisan migrate:fresh --env=testing --seed && php artisan optimize:clear"

  # pre-remove  =
EOF
}

# _gwt_scaffold_conf <dest> <ref_path>
_gwt_scaffold_conf() {
  local dest="$1"
  if [[ -f "$dest" ]]; then
    echo "  [ok] gwt.conf already present — keeping it"
    return 0
  fi
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] write starter gwt.conf (Laravel + Herd) → $dest"
    return 0
  fi
  { _gwt_conf_header; _gwt_conf_body; } > "$dest"
  echo "  [ok] Wrote starter gwt.conf (Laravel + Herd) → $dest"
}

# _gwt_conf_upgrade <conf>
# gwt.conf is written ONCE at init and never rewritten, so a project set up
# before a feature existed keeps running its old config forever — editing the
# scaffold above does nothing for it. `upgrade` appends only the sections a conf
# is missing, from the same block functions the scaffold uses, and leaves
# everything already there exactly as it is.
_gwt_conf_upgrade() {
  local conf="$1" added=0
  if [[ ! -f "$conf" ]]; then
    echo "  [info] No gwt.conf yet — scaffolding a full one instead."
    _gwt_scaffold_conf "$conf"
    return $?
  fi

  local has_envfiles has_db has_redis has_post has_cookie has_shared has_ide
  has_envfiles="$(git config --file "$conf" --get-regexp '^env\..+\.set$' 2>/dev/null)"
  has_db="$(git config --file "$conf" --get db.driver 2>/dev/null)"
  has_redis="$(git config --file "$conf" --get redis.isolate 2>/dev/null)"
  has_post="$(git config --file "$conf" --get hooks.post-install 2>/dev/null)"
  has_shared="$(git config --file "$conf" --get-all copy.shared 2>/dev/null)"
  has_ide="$(git config --file "$conf" --get ide.seed 2>/dev/null)"
  has_cookie="$(git config --file "$conf" --get-all env.set 2>/dev/null | grep -c '^SESSION_COOKIE=')"

  # [copy] shared now copies a directory's CONTENTS into the worktree, preserving
  # relative paths — it used to copy the directory itself to the worktree root.
  # An existing value therefore means something different than it did. Say so
  # rather than rewrite it: only you know what that directory holds.
  if [[ -n "$has_shared" ]] && ! print -r -- "$has_shared" | grep -qx '\.gwt'; then
    echo "  [!]  [copy] shared = ${has_shared//$'\n'/, }  — this key changed meaning."
    echo "       It now copies that directory's CONTENTS in, preserving relative"
    echo "       paths, instead of copying the directory itself to the worktree root."
    echo ""
  fi

  if [[ -n "$_GWT_DRY" ]]; then
    local pending=0
    [[ -z "$has_envfiles" ]] && { echo "  [dry] append per-file [env \".env\"] / [env \".env.testing\"] overrides"; pending=1 }
    [[ -z "$has_db" ]]       && { echo "  [dry] append [db] section";          pending=1 }
    [[ -z "$has_redis" ]]    && { echo "  [dry] append [redis] section";       pending=1 }
    [[ -z "$has_ide" ]]      && { echo "  [dry] append [ide] section";         pending=1 }
    [[ -z "$has_post" ]]     && { echo "  [dry] add hooks.post-install";       pending=1 }
    [[ -z "$has_shared" ]]   && { echo "  [dry] add copy.shared = .gwt";       pending=1 }
    (( has_cookie == 0 ))    && { echo "  [dry] add env.set = SESSION_COOKIE"; pending=1 }
    # Say so explicitly. Printing nothing at all reads as "this command is
    # broken" rather than "there is nothing left to add".
    (( pending )) || echo "  [ok] gwt.conf already has every section — nothing to add."
    echo ""
    return 0
  fi

  # Whole sections carry their own comments, so they are appended verbatim.
  if [[ -z "$has_envfiles" ]]; then
    { echo ""; _gwt_conf_block_envfiles; } >> "$conf"
    echo "  [ok] Added per-file [env] overrides"; added=1
  fi
  if [[ -z "$has_db" ]]; then
    _gwt_conf_block_db >> "$conf"
    echo "  [ok] Added [db] section"; added=1
  fi
  if [[ -z "$has_redis" ]]; then
    _gwt_conf_block_redis >> "$conf"
    echo "  [ok] Added [redis] section"; added=1
  fi
  if [[ -z "$has_ide" ]]; then
    _gwt_conf_block_ide >> "$conf"
    echo "  [ok] Added [ide] section"; added=1
  fi
  # Single keys go through git config, which places them inside the section they
  # belong to rather than at the end of the file.
  # Appended as a COMMENTED block, not written live: post-install is where
  # migrations go, and silently activating a destructive command in an existing
  # project during an upgrade would be the wrong kind of helpful.
  if [[ -z "$has_post" ]]; then
    _gwt_conf_block_hooks >> "$conf"
    echo "  [ok] Added a commented [hooks] post-install example — review and enable it"
    added=1
  fi
  if (( has_cookie == 0 )); then
    git config --file "$conf" --add env.set 'SESSION_COOKIE=${GWT_IDENT}_session'
    echo "  [ok] Added env.set = SESSION_COOKIE"; added=1
  fi
  if [[ -z "$has_shared" ]]; then
    git config --file "$conf" --add copy.shared '.gwt'
    echo "  [ok] Added copy.shared = .gwt"; added=1
  fi

  echo ""
  if (( added )); then
    echo "  Review the new sections before your next 'gwt add':"
    echo "    gwt config edit"
    echo ""
    echo "  Existing worktrees are NOT touched — they keep pointing at whatever"
    echo "  their env already names. Give one its own resources with:"
    echo "    gwt db create <branch>"
  else
    echo "  [ok] gwt.conf already has every section — nothing to add."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# gwt-init  (also callable as: gwt init)
# ---------------------------------------------------------------------------
gwt-init() {
  # No global state: these are local so init (or a --test preview) never leaks
  # into the surrounding shell.
  local GWT_BARE_ROOT GWT_WORKTREE_PARENT GWT_PROJECT GWT_REF_WORKTREE

  echo ""
  echo "  gwt init"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  [[ -n "$_GWT_DRY" ]] && echo "  [test mode] preview only — no clone, no files, no commands"
  echo ""

  # The project is created inside the CURRENT directory. Warn up front, show
  # where it will land, and let the user bail out before any questions.
  local cwd="$PWD"
  local cwd_disp="${cwd/#$HOME/~}"
  echo "  [!] This project will be created inside the current directory:"
  echo ""
  echo "      ${cwd_disp}/"
  echo "      ├── <project>.git/         ← bare repo (+ local gwt.conf)"
  echo "      └── <project>-<ref>/       ← reference worktree"
  echo ""
  if git rev-parse --git-dir >/dev/null 2>&1; then
    echo "  [warn] You appear to be INSIDE an existing git repo/worktree —"
    echo "         creating a project here would nest it. Check the path above."
    echo ""
  fi
  echo "      Wrong place? Abort, cd into the folder you want, then re-run."
  echo ""
  local go=""
  vared -p "  Create here? [Y/n]: " go
  case "${go:l}" in
    ""|y|yes) ;;
    *) echo "  Aborted. cd into your target folder and run 'gwt init' again."; return 1 ;;
  esac
  echo ""

  # Collect every setting, show a review, then confirm before touching
  # anything. Answering "no" starts the questions over.
  local remote project project_input ref_branch
  local bare_root wt_parent confirm

  while true; do
    # ── Remote URL ──
    remote=""
    if [[ -n "$_GWT_DRY" ]]; then
      remote="git@github.com:acme/demo.git"
      vared -p "  Remote URL [$remote]: " remote
      [[ -z "$remote" ]] && remote="git@github.com:acme/demo.git"
    else
      while true; do
        remote=""
        vared -p "  Remote URL: " remote
        if [[ "$remote" =~ ^git@.+:.+$ || "$remote" =~ ^https?://.+$ || "$remote" =~ ^(file://|/|\./|~).+ ]]; then
          break
        fi
        echo "  [error] Must be an SSH (git@…), HTTPS (https://…) or local (file:// / path) URL. Try again."
      done
    fi

    # ── Project name (derived from URL, overridable) ──
    project="${remote##*/}"   # last path segment
    project="${project%.git}" # strip .git suffix
    project="${project:l}"    # lowercase
    if [[ -z "$project" ]]; then
      echo "  [error] Could not extract project name from URL."
      return 1
    fi
    echo "  [info] Project name derived: $project"
    project_input=""
    vared -p "  Project name [$project]: " project_input
    [[ -n "$project_input" ]] && project="${project_input:l}"
    echo ""

    # ── Reference branch ──
    ref_branch=""
    vared -p "  Reference branch [main]: " ref_branch
    [[ -z "$ref_branch" ]] && ref_branch="main"

    # The current directory IS the project folder: the bare repo and the
    # worktrees are created directly inside it (no extra nesting).
    bare_root="$cwd/$project.git"
    wt_parent="$cwd"

    # ── Review + confirm ──
    echo ""
    echo "  Review:  [Laravel + Herd]"
    echo "    Project   : $project"
    echo "    Remote    : $remote"
    echo "    Reference : $ref_branch"
    echo ""
    echo "    ${cwd_disp}/"
    echo "    ├── ${project}.git/             ← bare repo (+ gwt.conf)"
    echo "    └── ${project}-${ref_branch}/   ← reference worktree"
    echo ""

    confirm=""
    vared -p "  Proceed? [Y/n]: " confirm
    case "${confirm:l}" in
      ""|y|yes) break ;;
      *) echo ""; echo "  ── starting over ──"; echo "" ;;
    esac
  done

  GWT_BARE_ROOT="$bare_root"
  GWT_WORKTREE_PARENT="$wt_parent"
  GWT_PROJECT="$project"
  GWT_REF_WORKTREE="$ref_branch"

  # ── Clone the bare repo + persist the reference branch into its git config ──
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] git clone --bare $remote $bare_root"
    echo "  [dry] git -C $bare_root config gwt.ref  $ref_branch"
  elif [[ -d "$bare_root" ]]; then
    echo "  [ok] Bare repo already present at $bare_root"
    git -C "$bare_root" config gwt.ref "$ref_branch"
  else
    mkdir -p "$wt_parent"
    echo "  [..] Cloning bare repo…"
    if ! git clone --bare "$remote" "$bare_root"; then
      echo "  [error] git clone failed."
      return 1
    fi

    # Fix fetch refspec so `git fetch` works properly on a bare clone.
    git -C "$bare_root" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git -C "$bare_root" fetch --all --quiet

    git -C "$bare_root" config gwt.ref "$ref_branch"
    echo "  [ok] Bare repo cloned"
  fi

  local ref_folder="${GWT_PROJECT}-${GWT_REF_WORKTREE}"
  local ref_path="$GWT_WORKTREE_PARENT/$ref_folder"

  # ── Reference worktree ──
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] git worktree add $ref_path $GWT_REF_WORKTREE"
  elif [[ -d "$ref_path" ]]; then
    echo "  [ok] Reference worktree found at $ref_path"
  else
    if ! _gwt_branch_exists "$GWT_REF_WORKTREE"; then
      echo "  [error] Branch '$GWT_REF_WORKTREE' does not exist in the bare repo."
      echo "          Push it to the remote first, then run gwt init again."
      return 1
    fi
    echo "  [..] Creating reference worktree ($GWT_REF_WORKTREE)…"
    git -C "$GWT_BARE_ROOT" worktree add "$ref_path" "$GWT_REF_WORKTREE"
  fi

  # ── Scaffold local config, then let the user tweak it before install ──
  _gwt_scaffold_conf "$GWT_BARE_ROOT/gwt.conf"
  if [[ -z "$_GWT_DRY" && -f "$GWT_BARE_ROOT/gwt.conf" ]]; then
    local edit=""
    vared -p "  Edit gwt.conf before installing deps? [y/N]: " edit
    [[ "${edit:l}" == y* ]] && ${EDITOR:-vi} "$GWT_BARE_ROOT/gwt.conf"
  fi

  # ── Reference worktree setup, entirely from gwt.conf ──
  _gwt_init_env "$ref_path"
  _gwt_apply_env  "$ref_path" "$GWT_REF_WORKTREE"
  _gwt_copy_shared "$ref_path"
  _gwt_db_create   "$GWT_REF_WORKTREE"
  _gwt_redis_apply "$GWT_REF_WORKTREE" "$ref_path"
  _gwt_run_install                     "$(_gwt_cfg install.cmd)"      "$ref_path" "$GWT_REF_WORKTREE"
  _gwt_run_cmd  "post-create hook"     "$(_gwt_cfg hooks.post-create)" "$ref_path" "$GWT_REF_WORKTREE"
  _gwt_run_cmd  "start dev server"     "$(_gwt_cfg server.up)"        "$ref_path" "$GWT_REF_WORKTREE"

  # Re-assert after the dev server, which can rewrite env on link (herd flattens
  # APP_URL). Leaves the worktree in the state gwt.conf declares.
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] re-assert [env] set after dev server (e.g. herd rewrites APP_URL on link)"
  else
    _gwt_apply_env "$ref_path" "$GWT_REF_WORKTREE"
  fi

  # ── Summary ──
  local ref_url raw
  raw="$(_gwt_cfg server.url)"
  [[ -n "$raw" ]] && ref_url="$(_gwt_expand "$raw" "$GWT_REF_WORKTREE")"
  echo ""
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "    gwt init complete"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "    Template   : Laravel + Herd"
  echo "    Bare repo  : $GWT_BARE_ROOT"
  echo "    Config     : $GWT_BARE_ROOT/gwt.conf"
  echo "    Reference  : $ref_path"
  [[ -n "$ref_url" ]] && echo "    URL        : $ref_url"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "    gwt add <existing-branch>               add an existing/remote branch"
  echo "    gwt add <existing-branch> <new-branch>  create new branch off base"
  echo "    gwt cd <branch>                   jump into a worktree"
  echo "    gwt config                        view/edit this project's gwt.conf"
  echo "    gwt list                          list all worktrees"
  echo "    gwt remove <branch>               remove a worktree"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ---------------------------------------------------------------------------
# gwt-help  (also: gwt -h | --help | help)
# ---------------------------------------------------------------------------
_gwt_help() {
  echo ""
  echo "  gwt — git worktree manager for Laravel (bare-clone pattern)"
  echo ""
  echo "  COMMANDS"
  echo "    gwt init                 First-time project setup, in the CURRENT folder:"
  echo "                             clone a bare repo, create the reference worktree,"
  echo "                             scaffold a local gwt.conf, then run its install"
  echo "                             step. Run once per project."
  echo ""
  echo "    gwt add <existing-branch>"
  echo "                             Add an existing branch as a new worktree, then"
  echo "                             install its own dependencies. The branch may be a"
  echo "                             local one or a branch that only exists on origin —"
  echo "                             a remote-only branch is checked out as-is."
  echo ""
  echo "    gwt add <existing-branch> <new-branch>"
  echo "                             Create <new-branch> off <existing-branch> (which"
  echo "                             may be a remote branch), then check it out as a"
  echo "                             new worktree under the new-branch name as-is."
  echo ""
  echo "    gwt cd <branch>          cd into a worktree (or the project folder)."
  echo "    gwt list                 List all worktrees of the current project."
  echo "    gwt config [show|edit|path|upgrade]"
  echo "                             Show or edit this project's gwt.conf. 'upgrade'"
  echo "                             appends the sections an older config is missing"
  echo "                             (gwt.conf is scaffolded once and never rewritten,"
  echo "                             so new features never reach an existing project"
  echo "                             on their own)."
  echo "    gwt ide sync             Push the IDE settings of the worktree you are IN"
  echo "                             to every other worktree, reference included — so"
  echo "                             the next 'gwt add' inherits them too. Detects"
  echo "                             PhpStorm (.idea) and VS Code (.vscode). Must be"
  echo "                             run inside a worktree. New worktrees are seeded"
  echo "                             from the reference automatically on 'gwt add'."
  echo "    gwt db [status|create|drop] [<branch>]"
  echo "                             Per-worktree databases and Redis index. 'status'"
  echo "                             shows what gwt recorded against each worktree and"
  echo "                             what its env files actually name — the two"
  echo "                             disagreeing is what you are looking for."
  echo "    gwt doctor               Check config, tools on PATH, dependency dirs, and"
  echo "                             whether each worktree really is isolated."
  echo "    gwt remove <branch>... | all"
  echo "                             Tear down one or MORE worktrees (hooks, dev"
  echo "                             server, folder). The local branch is kept unless"
  echo "                             you pass --force. 'all' opens an interactive"
  echo "                             picker over every worktree except the reference"
  echo "                             branch (numbered select, or 'a' for all-of-them);"
  echo "                             honours --force."
  echo "    gwt help | -h | --help   Show this help."
  echo ""
  echo "  FLAGS"
  echo "    --test, --dry            Preview any command without making changes."
  echo "    --force                  (remove only) Nuke it all: delete the worktree's"
  echo "                             dependency directories AND its LOCAL git branch"
  echo "                             (even if unmerged), and drop the databases gwt"
  echo "                             recorded for it plus its Redis index. Only ever"
  echo "                             drops what gwt itself created. Never touches the"
  echo "                             remote."
  echo ""
  echo "  CONFIG  (<project>.git/gwt.conf — local only, never committed)"
  echo "    [deps]   heavy = <dir>     heavy dep dirs (guarded on removal)"
  echo "    [install] cmd = <command>  install deps — run in EACH new worktree"
  echo "    [env]    copy  = <file>    gitignored files copied into new worktrees"
  echo "    [env]    set = KEY=VALUE   per-worktree override written into each copied env file"
  echo "    [env \"<file>\"] set = KEY=VALUE   same, but for that ONE file — this is how"
  echo "                             .env and .env.testing get different databases"
  echo "    [db]     driver/create/guard/drop-on-remove   per-worktree databases"
  echo "    [redis]  isolate/env-db/prefix/flush-on-remove   per-worktree cache index"
  echo "    [copy]   shared = <dir>    copy its CONTENTS into new worktrees, keeping"
  echo "                             relative paths (.gwt/.idea/workspace.xml → .idea/…)"
  echo "    [server] url/up/down       browse URL + dev-server start/stop commands"
  echo "    [hooks]  post-create / post-install / pre-remove   arbitrary shell. post-install"
  echo "                             runs after deps are installed (so it can use vendor/)"
  echo "                             and only once the database guard passes."
  echo "    Commands see: \$GWT_DIR \$GWT_PROJECT \$GWT_SLUG \$GWT_DOMAIN \$GWT_REF \$GWT_REF_DIR"
  echo "                  \$GWT_IDENT (<project>_<slug>) \$GWT_REF_IDENT"
  echo "    A ready-made template lives in the examples/ directory."
  echo ""
}

# ---------------------------------------------------------------------------
# gwt — top-level dispatcher. All work happens in subcommands:
#   gwt add <existing-branch>                 add an existing branch (local or a
#                                             remote branch on origin) as a worktree
#   gwt add <existing-branch> <new-branch>    create new branch off base, checkout
# ---------------------------------------------------------------------------
gwt() {
  # Pull --test/--dry and -h/--help out of the args. Declared local here so
  # that — via zsh's dynamic scoping — gwt-init, gwt-remove and every command
  # downstream see _GWT_DRY.
  local _GWT_DRY="" _show_help=""
  local -a _args=()
  local _a
  for _a in "$@"; do
    case "$_a" in
      --test|--dry) _GWT_DRY=1 ;;
      -h|--help)    _show_help=1 ;;
      *)            _args+=("$_a") ;;
    esac
  done
  [[ -n "$_show_help" ]] && { _gwt_help; return 0; }
  set -- "${_args[@]}"

  local cmd="$1"

  # ── No argument → help ──
  if [[ -z "$cmd" ]]; then
    _gwt_help
    return 0
  fi

  # ── Subcommand routing ──
  case "$cmd" in
    init)     gwt-init;              return $? ;;
    list)     gwt-list;             return $? ;;
    cd)       gwt-cd "$2";          return $? ;;
    config)   gwt-config "$2";      return $? ;;
    doctor)   gwt-doctor;          return $? ;;
    db)       gwt-db "$2" "$3";    return $? ;;
    ide)      gwt-ide "${@:2}";    return $? ;;
    remove)   gwt-remove "${@:2}"; return $? ;;
    add)      gwt-add "$2" "$3";   return $? ;;
    help)     _gwt_help;           return 0 ;;
    *)
      echo "Error: unknown command '$cmd'."
      echo "       Did you mean:  gwt add $cmd   (add an existing branch as a worktree)?"
      echo "       Run 'gwt help' for all commands."
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# gwt add <existing-branch>          add an existing branch (a local head, or a
#                                    remote branch on origin) as a worktree
# gwt add <existing-branch> <new-branch>
#                                    create <new-branch> off <existing-branch>
#                                    (which may be a remote branch), then check
#                                    it out as a worktree
# ---------------------------------------------------------------------------
gwt-add() {
  local base_branch="$1" new_branch="$2"
  if [[ -z "$base_branch" ]]; then
    echo "Usage: gwt add <existing-branch> [<new-branch>]"
    echo "       gwt add <existing-branch>              add an existing branch (local"
    echo "                                              or a remote branch on origin)."
    echo "       gwt add <existing-branch> <new-branch> create <new-branch> off it."
    return 1
  fi
  if [[ -z "$new_branch" ]]; then
    # One arg: add the existing branch itself (resolved locally or from origin).
    _gwt_create "$base_branch" ""
  else
    # Two args: create <new-branch> off <existing-branch>, then check it out.
    _gwt_create "$new_branch" "$base_branch"
  fi
}

# _gwt_create <branch> <base_branch>
# Adds a worktree for <branch>.
#   • <base_branch> empty  → <branch> must already exist, as a local head OR a
#     remote branch (origin/<branch>); a remote-only branch is materialised into
#     a local head first. This is the `gwt add <existing-branch>` path.
#   • <base_branch> given  → <branch> is created off <base_branch> first, where
#     <base_branch> may itself be local or a remote branch. This is the
#     `gwt add <existing-branch> <new-branch>` path.
# Relies on _GWT_DRY from the caller (zsh dynamic scoping).
_gwt_create() {
  local branch="$1" base_branch="$2"

  # ── Load project context from the current directory ──
  local GWT_BARE_ROOT GWT_WORKTREE_PARENT GWT_PROJECT GWT_REF_WORKTREE
  if ! _gwt_load_context; then
    echo "Error: not inside a gwt project."
    echo "       cd into a project worktree (or its parent folder) and retry,"
    echo "       or run 'gwt init' to set up a new project."
    return 1
  fi

  # ── Derive names ──
  local slug
  slug="$(_gwt_normalize "$branch")"
  local folder="${GWT_PROJECT}-${slug}"
  local worktree_path="$GWT_WORKTREE_PARENT/$folder"
  local ref_path="$GWT_WORKTREE_PARENT/${GWT_PROJECT}-${GWT_REF_WORKTREE}"

  # Whether this checkout is the reference branch (used only to pick the env
  # source below). Every worktree installs its own real deps regardless, so the
  # reference worktree no longer has to exist for others to be created.
  local is_ref=false
  [[ "$folder" == "${GWT_PROJECT}-${GWT_REF_WORKTREE}" ]] && is_ref=true

  # ── Guards ──
  if [[ -d "$worktree_path" ]]; then
    echo "Error: worktree already exists at $worktree_path"
    return 1
  fi

  # Resolve the existing branch (or base) to a git start-point. A local head is
  # used as-is; a remote-only branch resolves to origin/<name> and gets a fresh
  # local head. `create_local` decides whether we create a new local branch.
  local start_point="" create_local=false
  if [[ -z "$base_branch" ]]; then
    if _gwt_branch_exists "$branch"; then
      start_point="$branch"          # already a local head — check it out as-is
    elif _gwt_remote_branch_exists "$branch"; then
      start_point="origin/$branch"   # remote-only — materialise a local head
      create_local=true
    else
      echo "Error: branch '$branch' does not exist locally or on origin in the bare repo."
      echo "       If it was just pushed, fetch first: git -C \"$GWT_BARE_ROOT\" fetch origin"
      return 1
    fi
  else
    if _gwt_branch_exists "$base_branch"; then
      start_point="$base_branch"
    elif _gwt_remote_branch_exists "$base_branch"; then
      start_point="origin/$base_branch"
    else
      echo "Error: base branch '$base_branch' does not exist locally or on origin in the bare repo."
      echo "       If it was just pushed, fetch first: git -C \"$GWT_BARE_ROOT\" fetch origin"
      return 1
    fi
    if _gwt_branch_exists "$branch"; then
      echo "Error: branch '$branch' already exists."
      echo "       Add it directly with: gwt add $branch"
      return 1
    fi
    create_local=true
  fi

  # ── Preview ──
  local url raw
  raw="$(_gwt_cfg server.url)"
  [[ -n "$raw" ]] && url="$(_gwt_expand "$raw" "$slug")"
  echo ""
  if [[ -z "$base_branch" ]]; then
    if [[ "$create_local" == true ]]; then
      echo "  Branch  : $branch  (from $start_point)"
    else
      echo "  Branch  : $branch"
    fi
  else
    echo "  Branch  : $branch  (new, off $start_point)"
  fi
  echo "  Folder  : $worktree_path"
  [[ -n "$url" ]] && echo "  URL     : $url"
  echo ""

  # ── Create the local branch when needed ──
  # Two-arg add: new <branch> off the resolved base. One-arg add of a remote-only
  # branch: local <branch> off origin/<branch> (git sets origin as its upstream).
  if [[ "$create_local" == true ]]; then
    _gwt_run git -C "$GWT_BARE_ROOT" branch "$branch" "$start_point"
    if [[ -n "$base_branch" ]]; then
      echo "  [ok] Created branch '$branch' off '$start_point'"
    else
      echo "  [ok] Created local branch '$branch' tracking '$start_point'"
    fi
  fi

  # ── Add worktree ──
  _gwt_run git -C "$GWT_BARE_ROOT" worktree add "$worktree_path" "$branch"
  echo "  [ok] Worktree added"
  _gwt_log "add  $folder  ($branch)"

  # ── Config-driven setup — every worktree gets its OWN real dependencies ──
  # Env source: copy gitignored files from the reference worktree if it exists
  # (carries over local secrets/config), otherwise seed from *.example.
  if [[ "$is_ref" == false && -d "$ref_path" ]]; then
    _gwt_copy_env "$ref_path" "$worktree_path"
  else
    _gwt_init_env "$worktree_path"
  fi
  _gwt_apply_env  "$worktree_path" "$slug"
  _gwt_copy_shared "$worktree_path"

  # IDE settings, from the reference worktree — every worktree is a separate
  # project to PhpStorm/VS Code, and neither has a global default for most of
  # what lives in .idea / .vscode.
  if [[ "$is_ref" == false ]]; then
    _gwt_ide_seed "$ref_path" "$worktree_path"
  fi

  # Backing stores. These come AFTER the env is written (so [env] set has already
  # named the databases) and BEFORE the install, whose post-install hook is what
  # migrates into them.
  _gwt_db_create   "$slug"
  _gwt_redis_apply "$slug" "$worktree_path"

  _gwt_run_cmd "post-create hook"     "$(_gwt_cfg hooks.post-create)" "$worktree_path" "$slug"
  _gwt_run_install                    "$(_gwt_cfg install.cmd)"        "$worktree_path" "$slug"
  _gwt_run_cmd "start dev server"     "$(_gwt_cfg server.up)"          "$worktree_path" "$slug"

  # ── Re-assert [env] set as the LAST step ──
  # The dev server can rewrite env on link: `herd link` flattens APP_URL on disk
  # (drops the ${APP_DOMAIN} reference, downgrades https→http). Re-applying the
  # declared overrides here leaves the worktree in the state gwt.conf declares.
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] re-assert [env] set after dev server (e.g. herd rewrites APP_URL on link)"
  else
    _gwt_apply_env "$worktree_path" "$slug"
  fi

  # ── Summary ──
  echo ""
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "    Worktree ready"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "    Branch  : $branch"
  echo "    Path    : $worktree_path"
  [[ -n "$url" ]] && echo "    URL     : $url"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "    Dependencies are installing in the background — notification when ready."
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "    gwt cd $branch"
  echo ""
}

# ---------------------------------------------------------------------------
# gwt-remove <branch>... [--force]
#   (also callable as: gwt remove <branch> [<branch> …] …)
#
# Removes one or more worktrees (folder + any shared git-hook links). By default
# the git branch is KEPT, so your commits are never lost — re-add it any
# time with `gwt add <branch>` — and a worktree that still has real dep dirs
# (vendor/, node_modules/) is left untouched as a safety guard.
#
# --force is the all-in-one nuke: it skips the dependency guard AND deletes the
# LOCAL git branch too (force-deleting even unmerged commits). It NEVER touches
# the remote: gwt has no push/delete-remote code path.
# ---------------------------------------------------------------------------

# Forcefully delete a directory. Defeats the usual macOS hold-ups on a busy
# node_modules: read-only files, BSD immutable (uchg) flags, and a concurrent
# writer (a running `yarn dev` / Vite watcher, or Finder/Spotlight dropping a
# .DS_Store back) that makes a plain `rm -rf` lose the race and hit ENOTEMPTY.
# Returns non-zero only if the path still exists after every attempt.
_gwt_force_rmdir() {
  local dir="$1" i tmp
  [[ -e "$dir" ]] || return 0
  # Make everything deletable: clear immutable flags + add write permission.
  chflags -R nouchg "$dir" 2>/dev/null
  chmod -R u+w "$dir" 2>/dev/null
  # A few straight passes — handles transient writers (e.g. .DS_Store recreation).
  for i in 1 2 3; do
    rm -rf "$dir" 2>/dev/null
    [[ -e "$dir" ]] || return 0
    sleep 0.3
  done
  # Still there: a live process keeps repopulating it. Rename the whole tree
  # aside — that's atomic and frees the worktree path immediately even if the
  # writer keeps scribbling — then delete the moved copy best-effort.
  tmp="${dir}.gwt-trash.$$"
  if mv "$dir" "$tmp" 2>/dev/null; then
    rm -rf "$tmp" 2>/dev/null
    [[ -e "$dir" ]] || return 0
  fi
  return 1
}

# Remove a single worktree. Relies on the GWT_* context vars set by the caller
# (zsh dynamic scoping). Args: <branch> <force(true|false)>.
_gwt_remove_one() {
  local branch="$1" force="$2"

  # Strip project prefix if user passed the full folder name (myapp-staging → staging).
  branch="${branch#${GWT_PROJECT}-}"

  local slug folder worktree_path
  slug="$(_gwt_normalize "$branch")"
  folder="${GWT_PROJECT}-${slug}"
  worktree_path="$GWT_WORKTREE_PARENT/$folder"

  if [[ ! -d "$worktree_path" ]]; then
    echo "  [error] no worktree found at $worktree_path — skipping"
    return 1
  fi

  # Resolve the ACTUAL branch this worktree is on. The folder slug (e.g. "foo")
  # is not the branch ref (which may be "feature/foo"), so for --force we ask
  # git which branch the worktree has checked out.
  local real_branch=""
  real_branch="$(git -C "$worktree_path" symbolic-ref --short -q HEAD 2>/dev/null)"

  # ── Guard: real dependency directories block removal (unless --force) ──
  if [[ -z "$_GWT_DRY" && "$force" == false ]] && _gwt_check_real_deps "$worktree_path"; then
    echo "  [error] '$folder' still has dependency directories (e.g. $(_gwt_dep_list))."
    echo "          Left untouched. Nuke it all (deps + local branch): gwt remove $branch --force"
    return 1
  fi

  echo "  ── $folder ──"

  # ── Tear down: hooks → dev server ──
  _gwt_run_cmd   "pre-remove hook" "$(_gwt_cfg hooks.pre-remove)" "$worktree_path" "$slug"
  _gwt_run_cmd   "stop dev server" "$(_gwt_cfg server.down)"      "$worktree_path" "$slug"
  _gwt_unlink_worktree_hooks "$worktree_path"   # drop shared git-hook links into this wt

  # ── Remove worktree ──
  local rc=0
  _gwt_run git -C "$GWT_BARE_ROOT" worktree remove "$worktree_path" --force 2>/dev/null
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] delete directory: $worktree_path"
  elif [[ -e "$worktree_path" ]]; then
    if _gwt_force_rmdir "$worktree_path"; then
      echo "  [ok] Deleted directory: $worktree_path"
    else
      rc=1
      echo "  [error] Could not fully delete $worktree_path — something is still"
      echo "          writing into it (a running 'yarn dev' / Vite watcher?)."
      echo "          Stop it, then: rm -rf '$worktree_path'"
    fi
  fi
  _gwt_run git -C "$GWT_BARE_ROOT" worktree prune 2>/dev/null
  if [[ -z "$_GWT_DRY" && -e "$worktree_path" ]]; then
    echo "  [warn] Worktree folder still present: $folder"
  else
    echo "  [ok] Worktree removed: $folder"
  fi

  # ── Per-worktree resources (databases, Redis index) ──
  # Same posture as the dependency guard and the branch deletion above: nothing
  # holding data is destroyed unless you asked for it with --force.
  local db_policy redis_policy kept
  db_policy="$(_gwt_cfg db.drop-on-remove force)"
  redis_policy="$(_gwt_cfg redis.flush-on-remove force)"
  if [[ "$db_policy" == always || ( "$db_policy" == force && "$force" == true ) ]]; then
    _gwt_db_drop "$slug"
  elif [[ "$(_gwt_db_driver)" != none ]]; then
    kept="$(_gwt_res_get "$slug" db | tr '\n' ' ')"
    [[ -n "$kept" ]] && \
      echo "  [info] Database(s) kept: ${kept% } — drop them with: gwt remove $branch --force"
  fi
  if [[ "$redis_policy" == always || ( "$redis_policy" == force && "$force" == true ) ]]; then
    _gwt_redis_release "$slug"
  fi

  # ── --force also deletes the LOCAL branch (never the remote) ──
  if [[ "$force" == true ]]; then
    if [[ -z "$real_branch" ]]; then
      echo "  [info] Worktree was not on a branch (detached HEAD) — nothing to delete."
    elif [[ "$real_branch" == "$GWT_REF_WORKTREE" ]]; then
      echo "  [warn] Refusing to delete the reference branch '$real_branch'."
    elif [[ -n "$_GWT_DRY" ]]; then
      echo "  [dry] git branch -D $real_branch   (local only; remote untouched)"
    # Try a safe delete first; fall back to force-delete for unmerged commits.
    elif git -C "$GWT_BARE_ROOT" branch -d "$real_branch" 2>/dev/null; then
      echo "  [ok] Deleted local branch: $real_branch"
    elif git -C "$GWT_BARE_ROOT" branch -D "$real_branch" 2>/dev/null; then
      echo "  [ok] Force-deleted local branch (unmerged): $real_branch"
    else
      echo "  [warn] Could not delete local branch '$real_branch'."
    fi
  elif [[ -n "$real_branch" ]] && _gwt_branch_exists "$real_branch"; then
    echo "  [info] Branch '$real_branch' kept (commits safe). Re-add: gwt add $real_branch"
  fi

  (( rc == 0 )) && _gwt_log "remove  $folder${force:+  --force}"

  return $rc
}

# ---------------------------------------------------------------------------
# _gwt_remove_all <force(true|false)>
#
# Backs `gwt remove all`. Enumerates every worktree EXCEPT the bare repo and the
# reference worktree, shows an interactive picker (numbered list + 'a'=all), then
# feeds the chosen folders through _gwt_remove_one — so --force, the dependency
# guard, hooks and local-branch deletion all behave exactly as for a single
# remove. Relies on the GWT_* context vars set by the caller (zsh dynamic scope).
# ---------------------------------------------------------------------------
_gwt_remove_all() {
  local force="$1"
  local ref_path="$GWT_WORKTREE_PARENT/${GWT_PROJECT}-${GWT_REF_WORKTREE}"

  # ── Enumerate removable worktrees (path + branch/detached label) ──
  # NB: never name a local `path` — that's zsh's array tied to $PATH; shadowing
  # it would blank PATH inside this function and break git/awk lookups.
  local -a paths=() labels=()
  local rec wtpath branch
  for rec in ${(f)"$(git -C "$GWT_BARE_ROOT" worktree list --porcelain | awk '
      /^worktree /{wt=$2; br=""; bare=0; det=0}
      /^bare$/{bare=1}
      /^detached$/{det=1}
      /^branch /{br=$2}
      /^$/{ if (wt != "" && !bare) print wt"\t"(det ? "(detached)" : br); wt="" }
      END{ if (wt != "" && !bare) print wt"\t"(det ? "(detached)" : br) }
    ')"}; do
    wtpath="${rec%%$'\t'*}"
    branch="${rec#*$'\t'}"
    branch="${branch#refs/heads/}"
    # Never offer the reference worktree — matched by resolved path OR branch name.
    [[ "${wtpath:A}" == "${ref_path:A}" ]] && continue
    [[ "$branch" == "$GWT_REF_WORKTREE" ]] && continue
    paths+=("$wtpath"); labels+=("$branch")
  done

  if (( ${#paths} == 0 )); then
    echo "  No removable worktrees — only the reference ('$GWT_REF_WORKTREE') exists."
    echo ""
    return 0
  fi

  # ── Picker ──
  echo "  Worktrees in $GWT_PROJECT  (reference '$GWT_REF_WORKTREE' is protected):"
  echo ""
  local i
  for i in {1..${#paths}}; do
    printf "    %2d) %-30s [%s]\n" "$i" "${paths[$i]:t}" "${labels[$i]}"
  done
  echo ""
  if [[ "$force" == true ]]; then
    echo "  --force: deps AND local branches (even unmerged) will be deleted. Remote untouched."
    echo ""
  fi
  local sel=""
  vared -p "  Select to remove — 'a'=all, e.g. '1 3' or '1-3', blank=cancel: " sel

  # ── Parse the selection into a deduped, sorted index set ──
  local -a chosen=()
  local tok
  case "${sel:l}" in
    ""|q|cancel) echo "  Cancelled — nothing removed."; echo ""; return 0 ;;
    a|all)       chosen=({1..${#paths}}) ;;
    *)
      for tok in ${(s: :)${sel//,/ }}; do
        if [[ "$tok" == <->-<-> ]]; then            # range N-M
          local lo="${tok%%-*}" hi="${tok##*-}" n
          for n in {$lo..$hi}; do (( n >= 1 && n <= ${#paths} )) && chosen+=($n); done
        elif [[ "$tok" == <-> ]]; then              # single number
          (( tok >= 1 && tok <= ${#paths} )) && chosen+=($tok)
        else
          echo "  [warn] ignoring '$tok' — not a number or range."
        fi
      done
      ;;
  esac
  chosen=(${(onu)chosen})
  if (( ${#chosen} == 0 )); then
    echo "  Nothing valid selected — nothing removed."
    echo ""
    return 0
  fi

  # ── Remove each chosen worktree via the single-remove path ──
  echo ""
  local rc=0 idx
  for idx in $chosen; do
    _gwt_remove_one "${paths[$idx]:t}" "$force" || rc=1
    echo ""
  done
  echo "  Done. Processed ${#chosen} worktree(s)."
  echo ""
  return $rc
}

gwt-remove() {
  local force=false a
  local -a branches=()
  for a in "$@"; do
    case "$a" in
      --force) force=true ;;
      -*)      echo "Error: unknown flag '$a'"; return 1 ;;
      *)       branches+=("$a") ;;
    esac
  done

  if (( ${#branches} == 0 )); then
    echo "Usage: gwt remove <branch> [<branch> …] [--force]"
    echo "       gwt remove all [--force]   pick from every worktree except the"
    echo "                                  reference branch (interactive select)."
    echo "       --force  nuke it all: skip the dependency guard, delete the LOCAL"
    echo "                git branch (even if unmerged), and drop the databases +"
    echo "                Redis index gwt created for it. Never the remote."
    return 1
  fi

  # ── Load project context from the current directory ──
  local GWT_BARE_ROOT GWT_WORKTREE_PARENT GWT_PROJECT GWT_REF_WORKTREE
  if ! _gwt_load_context; then
    echo "Error: not inside a gwt project."
    echo "       cd into a project worktree (or its parent folder) and retry."
    return 1
  fi

  # ── Reserved target: "all" → interactive picker over every non-reference worktree ──
  if (( ${branches[(Ie)all]} )); then
    (( ${#branches} > 1 )) && echo "  [info] 'all' selected — other names ignored."
    echo ""
    _gwt_remove_all "$force"
    return $?
  fi

  echo ""
  local b rc=0
  for b in "${branches[@]}"; do
    _gwt_remove_one "$b" "$force" || rc=1
    echo ""
  done

  if (( ${#branches} == 1 )); then
    echo "  Done."
  else
    echo "  Done. Processed ${#branches} worktree(s)."
  fi
  echo ""
  return $rc
}

# ---------------------------------------------------------------------------
# gwt-list  (also callable as: gwt list)
# ---------------------------------------------------------------------------
gwt-list() {
  local GWT_BARE_ROOT GWT_WORKTREE_PARENT GWT_PROJECT GWT_REF_WORKTREE
  if ! _gwt_load_context; then
    echo "Error: not inside a gwt project."
    echo "       cd into a project worktree (or its parent folder) and retry."
    return 1
  fi
  echo "  Project: $GWT_PROJECT  [Laravel, ref: $GWT_REF_WORKTREE]"
  git -C "$GWT_BARE_ROOT" worktree list
}

# ---------------------------------------------------------------------------
# gwt-cd <branch>  (also callable as: gwt cd <branch>)
# cd into a worktree. With no argument, cd into the project (worktree-parent)
# folder. Works because gwt is a sourced shell function.
# ---------------------------------------------------------------------------
gwt-cd() {
  local branch="$1"
  local GWT_BARE_ROOT GWT_WORKTREE_PARENT GWT_PROJECT GWT_REF_WORKTREE
  if ! _gwt_load_context; then
    echo "Error: not inside a gwt project."
    echo "       cd into a project worktree (or its parent folder) and retry."
    return 1
  fi
  if [[ -z "$branch" ]]; then
    if [[ -n "$_GWT_DRY" ]]; then
      echo "  [dry] cd $GWT_WORKTREE_PARENT"
      return 0
    fi
    cd "$GWT_WORKTREE_PARENT"
    return $?
  fi
  # Accept both "staging" and "myapp-staging" (full folder name).
  branch="${branch#${GWT_PROJECT}-}"
  local slug
  slug="$(_gwt_normalize "$branch")"
  local dir="$GWT_WORKTREE_PARENT/${GWT_PROJECT}-${slug}"
  if [[ ! -d "$dir" ]]; then
    echo "Error: no worktree at $dir"
    echo "       Run 'gwt list' to see what exists."
    return 1
  fi
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] cd $dir"
    return 0
  fi
  cd "$dir"
}

# ---------------------------------------------------------------------------
# gwt-config [show|edit|path]  (also callable as: gwt config …)
# ---------------------------------------------------------------------------
gwt-config() {
  local sub="${1:-show}"
  local GWT_BARE_ROOT GWT_WORKTREE_PARENT GWT_PROJECT GWT_REF_WORKTREE
  if ! _gwt_load_context; then
    echo "Error: not inside a gwt project."
    echo "       cd into a project worktree (or its parent folder) and retry."
    return 1
  fi
  local conf="$GWT_BARE_ROOT/gwt.conf"
  case "$sub" in
    path)
      echo "$conf"
      ;;
    edit)
      if [[ ! -f "$conf" ]]; then
        echo "  [info] No gwt.conf yet — scaffolding a Laravel + Herd one."
        { _gwt_conf_header; _gwt_conf_body; } > "$conf"
      fi
      ${EDITOR:-vi} "$conf"
      ;;
    upgrade)
      echo ""
      echo "  gwt config upgrade — $GWT_PROJECT"
      echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      _gwt_conf_upgrade "$conf"
      ;;
    show|"")
      if [[ -f "$conf" ]]; then
        echo "  Config: $conf"
        echo ""
        git config --file "$conf" --list
      else
        echo "  No gwt.conf yet at:"
        echo "    $conf"
        echo "  Create one with:  gwt config edit"
      fi
      ;;
    *)
      echo "Usage: gwt config [show|edit|path|upgrade]"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# IDE settings — [ide] section, `gwt ide sync`, and seeding on `gwt add`.
#
# PhpStorm and VS Code keep most of their per-project configuration inside the
# project folder, and there is NO global default for it: every worktree is a
# separate project, so a fresh one starts blank and you reconfigure it by hand.
# That is the problem this solves — one worktree is the source of truth, and its
# settings are pushed to the others.
#
# What is safe to copy was determined by inspection, not assumption. Most of
# .idea is portable; three things need handling:
#
#   <name>.iml / modules.xml   portable CONTENTS, per-worktree NAME
#   commandlinetools/          absolute path to the source worktree's artisan
#   workspace.xml              mixes real settings with per-project state
#
# The module file is where Settings > Directories lives — the source and
# excluded folder marks — and every path inside it is $MODULE_DIR$-relative, so
# only its filename ties it to a worktree. It is copied under the target's own
# module name, with modules.xml repointed to match. commandlinetools is skipped
# outright. workspace.xml is merged component by component, see
# _gwt_ide_ws_merge.
# ---------------------------------------------------------------------------

# Files/dirs inside an IDE config dir that are never synced. Configurable via
# [ide] skip; these defaults are the ones verified non-portable.
_gwt_ide_skip_list() {
  local v
  v="$(_gwt_cfg_all ide.skip)"
  if [[ -n "$v" ]]; then
    print -r -- "$v"
  else
    print -rl -- 'commandlinetools' 'shelf' \
                 'dataSources' 'dataSources.xml' 'dataSources.local.xml' \
                 'httpRequests' 'sonarlint' '.DS_Store'
  fi
}

# workspace.xml components that are never synced. These hold per-project
# identity and state, not settings: cloning them would give every worktree the
# same ProjectId, and copy one worktree's run configs and open-file path to all.
_gwt_ide_ws_skip_list() {
  local v
  v="$(_gwt_cfg_all ide.workspace-skip)"
  if [[ -n "$v" ]]; then
    print -r -- "$v"
  else
    print -rl -- ProjectId RunManager ChangeListManager TaskManager PropertiesComponent
  fi
}

# True when <relpath> matches a skip pattern. Matched against the full relative
# path, its first segment (so a directory name skips the whole tree) and its
# basename (so '*.iml' catches one at any depth).
_gwt_ide_skipped() {
  local rel="$1" pat first="${1%%/*}"
  for pat in ${(f)"$(_gwt_ide_skip_list)"}; do
    [[ -z "$pat" ]] && continue
    [[ "$rel" == ${~pat} || "$first" == ${~pat} || "${rel:t}" == ${~pat} ]] && return 0
  done
  return 1
}

# The IDE config directories present in <dir>, one per line.
_gwt_ide_dirs() {
  local dir="$1" d
  for d in .idea .vscode; do
    [[ -d "$dir/$d" ]] && echo "$d"
  done
}

_gwt_ide_label() {
  case "$1" in
    .idea)   echo "PhpStorm" ;;
    .vscode) echo "VS Code" ;;
    *)       echo "$1" ;;
  esac
}

# _gwt_ide_ws_merge <src-workspace.xml> <dst-workspace.xml> <skip-names>
#
# Merge the source's components INTO the destination, printing the result on
# stdout. Each source component replaces the same-named one in the destination;
# every other destination component survives untouched. That is what lets a sync
# carry your settings without carrying the target's run configs away with them.
#
# Components come in two shapes and both are handled:
#   <component name="X"> … </component>      block
#   <component name="ProjectId" id="…" />    self-closing
#
# <MESSAGE> children are dropped: in VcsManagerConfiguration they are the local
# commit-message history, not a setting, and cloning them would put one
# worktree's commit messages in every other worktree's dropdown.
#
# Pure awk, so gwt stays dependency-free. A missing destination is synthesised.
_gwt_ide_ws_merge() {
  local src="$1" dst="$2" skip="$3"
  [[ -f "$src" ]] || return 1
  if [[ ! -f "$dst" ]]; then
    dst="/dev/null"
  fi
  awk -v skiplist="$skip" '
    function nameof(line,   n) {
      if (match(line, /<component name="[^"]*"/))
        return substr(line, RSTART + 17, RLENGTH - 18)
      return ""
    }
    BEGIN {
      split(skiplist, a, " ")
      for (i in a) if (a[i] != "") skip[a[i]] = 1
      selfclose = "/>[ \t]*$"
      # A component does NOT always close on a line of its own: PropertiesComponent
      # is written as <component name="…"><![CDATA[{ … }]]></component>, so the
      # closing tag trails real content. Anchor on the END of the line, not the
      # start, or everything after such a component is swallowed.
      closes = "</component>[ \t]*$"
    }
    # ── pass 1: collect the source components worth carrying ──
    FNR == NR {
      if (incomp) {
        if ($0 !~ /^[ \t]*<MESSAGE /) buf = buf "\n" $0
        if ($0 ~ closes) {
          if (!(cur in skip)) { src[cur] = buf; order[++no] = cur }
          incomp = 0
        }
        next
      }
      nm = nameof($0)
      if (nm != "") {
        if ($0 ~ selfclose || $0 ~ closes) {   # self-closing, or opens+closes here
          if (!(nm in skip)) { src[nm] = $0; order[++no] = nm }
        } else {
          incomp = 1; cur = nm; buf = $0
        }
      }
      next
    }
    # ── pass 2: rewrite the destination ──
    {
      sawdst = 1
      if (tin) {
        if ($0 ~ closes) tin = 0
        next                      # swallow the destination’s old copy
      }
      nm = nameof($0)
      if (nm != "" && (nm in src)) {
        print src[nm]
        done[nm] = 1
        if ($0 !~ selfclose && $0 !~ closes) { tin = 1 }
        next
      }
      if ($0 ~ /^[ \t]*<\/project>/) {
        for (i = 1; i <= no; i++)
          if (!(order[i] in done)) { print src[order[i]]; done[order[i]] = 1 }
        print
        emitted = 1
        next
      }
      print
    }
    END {
      # No </project> was reached. Either the destination did not exist (write a
      # whole file) or it is malformed (close it off after appending).
      if (!emitted) {
        if (!sawdst) {
          print "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
          print "<project version=\"4\">"
        }
        for (i = 1; i <= no; i++) if (!(order[i] in done)) print src[order[i]]
        print "</project>"
      }
    }
  ' "$src" "$dst"
}

# True when an IDE that would fight this sync is running.
#
# PhpStorm and VS Code keep their workspace state in memory and write it on their
# own schedule, which makes a workspace.xml sync unreliable in BOTH directions:
# a setting you just toggled is probably not on disk yet (so there is nothing to
# copy), and the IDE rewrites that file in every project it has open (undoing
# whatever gwt wrote). Observed directly: a sync completed, and the target's
# workspace.xml was rewritten by the IDE twenty-odd seconds later.
_gwt_ide_running() {
  case "$1" in
    .idea)   pgrep -qf 'PhpStorm.app/Contents/MacOS/phpstorm' 2>/dev/null ;;
    .vscode) pgrep -qf 'Visual Studio Code.app/Contents/MacOS' 2>/dev/null ;;
    *)       return 1 ;;
  esac
}

# The worktree the CWD is inside, or non-zero if there is none. Being somewhere
# under the project root is NOT enough — the project root and the bare dir are
# not worktrees, and syncing from them makes no sense.
_gwt_current_worktree() {
  local top wt
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -n "$top" ]] || return 1
  top="${top:A}"
  for wt in ${(f)"$(_gwt_worktree_paths)"}; do
    [[ "${wt:A}" == "$top" ]] && { echo "$top"; return 0 }
  done
  return 1
}

# Copy one IDE config dir from the <src> worktree into the <dst> worktree.
# Echoes the number of items handled. workspace.xml is merged, never copied.
_gwt_ide_sync_dir() {
  local src_wt="$1" dst_wt="$2" ide="$3"
  local src="$src_wt/$ide" dst="$dst_wt/$ide"
  local f rel skip tmp n=0
  [[ -d "$src" ]] || { echo 0; return 0 }

  for f in "$src"/**/*(D.N); do
    rel="${f#$src/}"
    # Handled specially, so never copied verbatim — and deliberately not
    # subject to [ide] skip, so a stale skip entry cannot disable them.
    if [[ "$ide" == ".idea" ]]; then
      [[ "$rel" == "workspace.xml" || "$rel" == "modules.xml" || "$rel" == *.iml ]] && continue
    fi
    _gwt_ide_skipped "$rel" && continue
    if [[ -z "$_GWT_DRY" ]]; then
      mkdir -p "$dst/${rel:h}"
      cp -p "$f" "$dst/$rel"
    fi
    (( n++ ))
  done

  # ── The module file: Settings ▸ Directories ──
  # <name>.iml is where source/excluded folder marks live, and its CONTENT is
  # fully portable — every path inside is $MODULE_DIR$-relative. Only its NAME is
  # worktree-specific. So copy the content under the TARGET's module name and
  # repoint modules.xml at it, rather than skipping it as "identity".
  if [[ "$ide" == ".idea" ]]; then
    local -a src_imls=( "$src"/*.iml(N) )
    if (( ${#src_imls} )); then
      local src_base="${${src_imls[1]:t}%.iml}" dst_base="${dst_wt:t}" old mod
      if [[ -z "$_GWT_DRY" ]]; then
        mkdir -p "$dst"
        # Drop any module file left under a different name, or the IDE sees two.
        for old in "$dst"/*.iml(N); do
          [[ "${old:t}" != "${dst_base}.iml" ]] && rm -f "$old"
        done
        cp -p "${src_imls[1]}" "$dst/${dst_base}.iml"
        if [[ -f "$src/modules.xml" ]]; then
          mod="$(<"$src/modules.xml")"
          mod="${mod//${src_base}.iml/${dst_base}.iml}"
          print -r -- "$mod" > "$dst/modules.xml"
        fi
      fi
      (( n += 2 ))
    fi
  fi

  # --force with the IDE open skips workspace.xml: it is the one part that
  # provably will not survive, so writing it would only be theatre.
  if [[ "$ide" == ".idea" && -f "$src/workspace.xml" && -z "$_gwt_ide_no_workspace" ]]; then
    skip="$(_gwt_ide_ws_skip_list | tr '\n' ' ')"
    if [[ -z "$_GWT_DRY" ]]; then
      mkdir -p "$dst"
      tmp="$dst/workspace.xml.gwt-tmp.$$"
      if _gwt_ide_ws_merge "$src/workspace.xml" "$dst/workspace.xml" "$skip" > "$tmp" \
         && [[ -s "$tmp" ]]; then
        mv -f "$tmp" "$dst/workspace.xml"
      else
        rm -f "$tmp"
      fi
    fi
    (( n++ ))
  fi
  echo "$n"
}

# List what a sync would touch, for --dry.
_gwt_ide_sync_preview() {
  # Split across two statements: within a single `local`, a later assignment
  # does not reliably see an earlier one from the same statement.
  local src_wt="$1" ide="$2" f rel
  local src="$src_wt/$ide"
  for f in "$src"/**/*(D.N); do
    rel="${f#$src/}"
    # Handled specially, so never copied verbatim — and deliberately not
    # subject to [ide] skip, so a stale skip entry cannot disable them.
    if [[ "$ide" == ".idea" ]]; then
      [[ "$rel" == "workspace.xml" || "$rel" == "modules.xml" || "$rel" == *.iml ]] && continue
    fi
    _gwt_ide_skipped "$rel" && continue
    echo "      $ide/$rel"
  done
  if [[ "$ide" == ".idea" ]]; then
    local -a imls=( "$src"/*.iml(N) )
    (( ${#imls} )) && \
      echo "      $ide/<worktree>.iml + modules.xml   (renamed per worktree — Settings > Directories)"
    [[ -f "$src/workspace.xml" ]] && \
      echo "      $ide/workspace.xml   (merged component-by-component, not copied)"
  fi
  return 0
}

# Seed a NEW worktree's IDE settings from the reference worktree, using the same
# manifest `gwt ide sync` uses. No-op when [ide] seed = false, or when the
# reference worktree has no IDE config of its own.
_gwt_ide_seed() {
  local ref="$1" dst="$2" ide n
  [[ "$(_gwt_cfg ide.seed true)" == "false" ]] && return 0
  [[ -d "$ref" ]] || return 0
  for ide in ${(f)"$(_gwt_ide_dirs "$ref")"}; do
    if [[ -n "$_GWT_DRY" ]]; then
      echo "  [dry] seed $(_gwt_ide_label "$ide") settings from $GWT_REF_WORKTREE"
      continue
    fi
    n="$(_gwt_ide_sync_dir "$ref" "$dst" "$ide")"
    echo "  [ok] Seeded $(_gwt_ide_label "$ide") settings from $GWT_REF_WORKTREE ($n item(s))"
  done
}

# ---------------------------------------------------------------------------
# gwt-ide sync   (also callable as: gwt ide sync)
#
# The worktree you are standing in is the source of truth; its IDE settings are
# pushed to every other worktree — including the reference, which is what makes
# the NEXT `gwt add` inherit the change too.
# ---------------------------------------------------------------------------
gwt-ide() {
  local sub="" _gi_force="" a
  for a in "$@"; do
    case "$a" in
      --force) _gi_force=1 ;;
      -*)      echo "Error: unknown flag '$a'"; return 1 ;;
      *)       [[ -z "$sub" ]] && sub="$a" ;;
    esac
  done
  [[ -z "$sub" ]] && sub="sync"
  local GWT_BARE_ROOT GWT_WORKTREE_PARENT GWT_PROJECT GWT_REF_WORKTREE
  if ! _gwt_load_context; then
    echo "Error: not inside a gwt project."
    echo "       cd into a project worktree and retry."
    return 1
  fi
  if [[ "$sub" != sync ]]; then
    echo "Usage: gwt ide sync"
    echo "       Run it INSIDE the worktree whose IDE settings are correct; they"
    echo "       are copied to every other worktree of this project."
    return 1
  fi

  # Must be run from inside a worktree: this command syncs FROM where you stand,
  # so the project root and the bare dir have nothing to offer.
  local src
  if ! src="$(_gwt_current_worktree)"; then
    # Lead with WHAT the command does, because that is what explains the
    # requirement. "Run it from inside a worktree" on its own reads like an
    # arbitrary rule; "the worktree you run it from is the one that gets copied
    # everywhere" makes the reason obvious.
    echo ""
    echo "  gwt ide sync copies ONE worktree's IDE settings to every other"
    echo "  worktree in this project — and the worktree you run it from is the"
    echo "  one being copied FROM."
    echo ""
    # This branch also fires from the bare repo or any other non-worktree dir,
    # so show where you actually are rather than assuming the project root. On
    # its own line, because these paths get long.
    echo "  Where you are now is not a worktree:"
    echo ""
    echo "      ${PWD/#$HOME/~}"
    echo ""
    echo "  so there is nothing to copy from, and no way for gwt to tell which"
    echo "  worktree's settings you mean."
    echo ""
    echo "  cd into the worktree whose IDE settings you want everywhere, then"
    echo "  run it again:"
    echo ""
    echo "      gwt cd <branch>     # 'gwt list' shows them all"
    echo "      gwt ide sync"
    echo ""
    return 1
  fi

  local -a ides=( ${(f)"$(_gwt_ide_dirs "$src")"} )
  if (( ${#ides} == 0 )); then
    echo "Error: no IDE settings found in ${src:t}."
    echo "       Looked for .idea (PhpStorm) and .vscode (VS Code). Open this"
    echo "       worktree in your IDE, configure it, then run this again."
    return 1
  fi

  local -a targets=()
  local wt
  for wt in ${(f)"$(_gwt_worktree_paths)"}; do
    [[ "${wt:A}" == "${src:A}" ]] && continue
    targets+=("$wt")
  done

  local labels=""
  local ide
  for ide in "${ides[@]}"; do labels="${labels:+$labels, }$(_gwt_ide_label "$ide")"; done

  echo ""
  echo "  gwt ide sync — $GWT_PROJECT"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Checked BEFORE anything else is printed. When the answer is "not now", the
  # reason is the only thing worth showing — a source/target summary underneath a
  # refusal just buries it.
  local running=""
  for ide in "${ides[@]}"; do
    _gwt_ide_running "$ide" && running="${running:+$running, }$(_gwt_ide_label "$ide")"
  done
  # Refuse outright rather than sync-and-warn. A sync done with the IDE open
  # looks like it worked and silently does not: the settings you just changed are
  # still in the IDE's memory, not on disk, and it rewrites the file again in
  # every project it has open. Stopping here is the only honest outcome.
  if [[ -n "$running" && -z "$_gi_force" ]]; then
    echo ""
    echo "  [!]  $running is RUNNING — refusing to sync."
    echo ""
    echo "       • It keeps .idea/workspace.xml in memory and writes it on its own"
    echo "         schedule, so the setting you just changed is probably not on disk"
    echo "         yet — there would be nothing for gwt to copy."
    echo "       • It also rewrites that file in every project it has open, undoing"
    echo "         whatever gwt puts there."
    echo ""
    echo "       Quit $running, then run this again."
    echo ""
    echo "       To sync anyway and skip workspace.xml:  gwt ide sync --force"
    echo ""
    return 1
  fi

  # Whether the reference is among the targets decides the wording: syncing FROM
  # the reference already updates what new worktrees get seeded with.
  local ref_dir="$GWT_WORKTREE_PARENT/${GWT_PROJECT}-${GWT_REF_WORKTREE}"
  echo "    Source  : ${src:t}  [$labels]"
  if [[ "${src:A}" == "${ref_dir:A}" ]]; then
    echo "    Targets : ${#targets} worktree(s). This IS the reference, so new"
    echo "              worktrees already inherit these settings."
  else
    echo "    Targets : ${#targets} worktree(s), reference included — so the next"
    echo "              'gwt add' inherits this too"
  fi
  echo ""

  if (( ${#targets} == 0 )); then
    echo "  No other worktrees — nothing to sync."
    echo ""
    return 0
  fi

  if [[ -n "$_GWT_DRY" ]]; then
    echo "  Would copy into each target:"
    for ide in "${ides[@]}"; do _gwt_ide_sync_preview "$src" "$ide"; done
    echo ""
    echo "  Targets:"
    for wt in "${targets[@]}"; do echo "      ${wt:t}"; done
    echo ""
    return 0
  fi

  # With --force while the IDE is open, everything except workspace.xml still
  # syncs cleanly — so sync that, and say plainly what was left out.
  local _gwt_ide_no_workspace=""
  if [[ -n "$running" ]]; then
    _gwt_ide_no_workspace=1
    echo "  [!]  $running is running — syncing everything EXCEPT workspace.xml."
    echo ""
  fi

  local n total=0
  for wt in "${targets[@]}"; do
    n=0
    for ide in "${ides[@]}"; do
      n=$(( n + $(_gwt_ide_sync_dir "$src" "$wt" "$ide") ))
    done
    echo "  [ok] ${wt:t}  ←  $n item(s)"
    (( total += n ))
  done
  _gwt_log "ide sync  ${src:t} → ${#targets} worktree(s)"

  echo ""
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "    Synced $total item(s) across ${#targets} worktree(s)."
  if [[ -n "$running" ]]; then
    echo "    $running was running — re-check that workspace.xml settings actually"
    echo "    landed, or quit it and run this again."
  else
    echo "    Reopen any worktree already open in your IDE to pick the changes up."
  fi
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ---------------------------------------------------------------------------
# gwt-db [status|create|drop] [<branch>]   (also callable as: gwt db …)
#
# On-demand access to the same resource plumbing `gwt add` runs — for adopting a
# worktree that predates [db] being configured, or re-creating a database you
# dropped by hand.
# ---------------------------------------------------------------------------

# One block per worktree: what gwt recorded against it, and what its env files
# actually name. The two disagreeing is the interesting case — that mismatch is
# the whole reason the post-install guard exists.
_gwt_db_status() {
  local gkey wt slug rec idx f val
  gkey="$(_gwt_cfg db.guard DB_DATABASE)"
  echo ""
  echo "  gwt db — $GWT_PROJECT"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$(_gwt_db_driver)" == none ]]; then
    echo "  [info] [db] driver is not set — gwt is not managing databases here."
    echo "         Add the section with:  gwt config upgrade"
  fi
  for wt in ${(f)"$(_gwt_worktree_paths)"}; do
    [[ -d "$wt" ]] || continue
    slug="$(_gwt_path_slug "$wt")"
    rec="$(_gwt_res_get "$slug" db | tr '\n' ' ')"
    idx="$(_gwt_res_get "$slug" redis-cache-db | head -1)"
    echo ""
    echo "  ${wt:t}"
    echo "      recorded  : ${rec:-—}"
    echo "      redis idx : ${idx:-—}"
    for f in $(_gwt_cfg_all env.copy); do
      [[ -f "$wt/$f" ]] || continue
      val="$(_gwt_env_get "$wt/$f" "$gkey")"
      echo "      $f → $gkey=${val:-—}"
    done
  done
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

gwt-db() {
  local sub="${1:-status}" branch="$2"
  local GWT_BARE_ROOT GWT_WORKTREE_PARENT GWT_PROJECT GWT_REF_WORKTREE
  if ! _gwt_load_context; then
    echo "Error: not inside a gwt project."
    echo "       cd into a project worktree (or its parent folder) and retry."
    return 1
  fi

  if [[ "$sub" == status ]]; then
    _gwt_db_status
    return 0
  fi

  if [[ "$(_gwt_db_driver)" == none ]]; then
    echo "  [info] [db] driver is not set — nothing to do."
    echo "         Add the section with:  gwt config upgrade"
    return 0
  fi

  # Default to the worktree we're standing in.
  [[ -z "$branch" ]] && branch="$(git symbolic-ref --short -q HEAD 2>/dev/null)"
  branch="${branch#${GWT_PROJECT}-}"
  local slug
  slug="$(_gwt_normalize "$branch")"
  if [[ -z "$slug" ]]; then
    echo "Usage: gwt db [status|create|drop] [<branch>]"
    return 1
  fi
  local dir="$GWT_WORKTREE_PARENT/${GWT_PROJECT}-${slug}"

  case "$sub" in
    create)
      echo ""
      echo "  ── ${GWT_PROJECT}-${slug} ──"
      _gwt_db_create   "$slug"
      _gwt_redis_apply "$slug" "$dir"
      if [[ -d "$dir" ]]; then
        _gwt_apply_env "$dir" "$slug"
      else
        echo "  [warn] no worktree at $dir — created the resources, but nothing to point at them."
      fi
      echo ""
      ;;
    drop)
      local names
      names="$(_gwt_res_get "$slug" db | tr '\n' ' ')"
      if [[ -z "$names" && -z "$(_gwt_res_get "$slug" redis-cache-db)" ]]; then
        echo "  [info] nothing recorded for '$slug' — nothing to drop."
        return 0
      fi
      echo ""
      echo "  This will DROP: ${names:-(no databases)}"
      echo "  and release Redis index: ${$(_gwt_res_get "$slug" redis-cache-db | head -1):-—}"
      echo ""
      if [[ -z "$_GWT_DRY" ]]; then
        local go=""
        vared -p "  Type the slug to confirm ($slug): " go
        if [[ "$go" != "$slug" ]]; then
          echo "  Cancelled — nothing dropped."
          echo ""
          return 0
        fi
      fi
      _gwt_db_drop       "$slug"
      _gwt_redis_release "$slug"
      echo ""
      ;;
    *)
      echo "Usage: gwt db [status|create|drop] [<branch>]"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# gwt-doctor  (also callable as: gwt doctor)
# Sanity checks: config present, referenced tools on PATH, dangling symlinks.
# ---------------------------------------------------------------------------
gwt-doctor() {
  local GWT_BARE_ROOT GWT_WORKTREE_PARENT GWT_PROJECT GWT_REF_WORKTREE
  if ! _gwt_load_context; then
    echo "Error: not inside a gwt project."
    echo "       cd into a project worktree (or its parent folder) and retry."
    return 1
  fi

  echo ""
  echo "  gwt doctor — $GWT_PROJECT"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local conf="$GWT_BARE_ROOT/gwt.conf"
  if [[ -f "$conf" ]]; then
    echo "  [ok] config: $conf"
  else
    echo "  [warn] no gwt.conf — run: gwt config edit"
  fi

  # Reference worktree present?
  local ref_path="$GWT_WORKTREE_PARENT/${GWT_PROJECT}-${GWT_REF_WORKTREE}"
  if [[ -d "$ref_path" ]]; then
    echo "  [ok] reference worktree: $ref_path"
  else
    echo "  [warn] reference worktree missing: $ref_path (run: gwt init)"
  fi

  # Commands referenced in config — is the first token on PATH?
  local key cmd first
  for key in install.cmd server.up server.down hooks.post-create hooks.pre-remove; do
    cmd="$(_gwt_cfg $key)"
    [[ -z "$cmd" ]] && continue
    first="${cmd%%[[:space:]]*}"
    if command -v "$first" >/dev/null 2>&1; then
      echo "  [ok] $key → '$first' found"
    else
      echo "  [warn] $key → '$first' not on PATH"
    fi
  done

  # Heavy dep dirs that are unexpectedly SYMLINKS (legacy from older gwt, or a
  # hand-made link) — these cause cross-worktree code bleed and should be real.
  local wt d found_link=false
  for wt in ${(f)"$(git -C "$GWT_BARE_ROOT" worktree list --porcelain | awk '/^worktree /{print $2}')"}; do
    for d in $(_gwt_cfg_all deps.heavy); do
      if [[ -L "$wt/$d" ]]; then
        echo "  [warn] $d is a SYMLINK in $wt"
        echo "         replace with real deps:  rm '$wt/$d' && (cd '$wt' && <install cmd>)"
        found_link=true
      fi
    done
  done
  [[ "$found_link" == false ]] && echo "  [ok] dependency dirs are real (not symlinked)"

  # Dangling symlinks in the SHARED git hooks dir (e.g. left by a hook installer
  # after its worktree was removed — these break the next hook-install run).
  local hl htgt found_hook=false
  if [[ -d "$GWT_BARE_ROOT/hooks" ]]; then
    for hl in "$GWT_BARE_ROOT"/hooks/*(N@); do
      if [[ ! -e "$hl" ]]; then
        htgt="$(readlink "$hl")"
        echo "  [warn] dangling hook symlink: ${hl:t} → $htgt"
        echo "         remove it:  rm '$hl'"
        found_hook=true
      fi
    done
  fi
  [[ "$found_hook" == false ]] && echo "  [ok] no dangling git-hook symlinks"

  # ── Databases ──
  local dwt f gkey val
  if [[ "$(_gwt_db_driver)" != none ]]; then
    local dbin
    dbin="$(_gwt_db_bin)"
    if ! command -v "$dbin" >/dev/null 2>&1; then
      echo "  [warn] [db] driver is '$(_gwt_db_driver)' but '$dbin' is not on PATH"
    elif _gwt_db_sql "SELECT 1" >/dev/null 2>&1; then
      echo "  [ok] database server reachable ($(_gwt_db_driver) @ $(_gwt_cfg db.host 127.0.0.1):$(_gwt_cfg db.port 3306))"
    else
      echo "  [warn] cannot reach the database server — check [db] host/port/user/password"
    fi

    # The bug the whole feature exists to prevent: two worktrees naming one
    # database, so a migration in one silently rewrites the other.
    gkey="$(_gwt_cfg db.guard DB_DATABASE)"
    local -A seen=()
    local dupe=false
    for dwt in ${(f)"$(_gwt_worktree_paths)"}; do
      for f in $(_gwt_cfg_all env.copy); do
        [[ -f "$dwt/$f" ]] || continue
        val="$(_gwt_env_get "$dwt/$f" "$gkey")"
        [[ -z "$val" ]] && continue
        if [[ -n "${seen[$f/$val]}" ]]; then
          echo "  [warn] $f: $gkey=$val is shared by ${seen[$f/$val]} and ${dwt:t}"
          dupe=true
        else
          seen[$f/$val]="${dwt:t}"
        fi
      done
    done
    [[ "$dupe" == false ]] && echo "  [ok] every worktree names its own $gkey"

    # Ledger entries whose worktree is gone (removed without --force).
    local line lslug orphan=false
    for line in ${(f)"$(git -C "$GWT_BARE_ROOT" config --get-regexp '^gwt\..*\.db$' 2>/dev/null)"}; do
      lslug="${${line%% *}#gwt.}"; lslug="${lslug%.db}"
      if [[ ! -d "$GWT_WORKTREE_PARENT/${GWT_PROJECT}-${lslug}" ]]; then
        echo "  [warn] '${line#* }' is still recorded for '$lslug', which has no worktree"
        echo "         drop it with:  gwt db drop $lslug"
        orphan=true
      fi
    done
    [[ "$orphan" == false ]] && echo "  [ok] no orphaned database records"
  fi

  # ── Redis ──
  if _gwt_redis_enabled; then
    local rhost rport
    rhost="$(_gwt_cfg redis.host 127.0.0.1)"
    rport="$(_gwt_cfg redis.port 6379)"
    if ! command -v redis-cli >/dev/null 2>&1; then
      echo "  [warn] [redis] isolate = cache-db but 'redis-cli' is not on PATH —"
      echo "         indexes still get allocated, but removal cannot flush them"
    elif redis-cli -h "$rhost" -p "$rport" PING >/dev/null 2>&1; then
      echo "  [ok] redis reachable ($rhost:$rport)"
    else
      echo "  [warn] cannot reach redis at $rhost:$rport"
    fi

    local -A ridx=()
    local rline rslug rval rclash=false
    for rline in ${(f)"$(git -C "$GWT_BARE_ROOT" config --get-regexp '^gwt\..*\.redis-cache-db$' 2>/dev/null)"}; do
      rslug="${${rline%% *}#gwt.}"; rslug="${rslug%.redis-cache-db}"
      rval="${rline#* }"
      if [[ -n "${ridx[$rval]}" ]]; then
        echo "  [warn] redis index $rval is recorded for both ${ridx[$rval]} and $rslug"
        rclash=true
      else
        ridx[$rval]="$rslug"
      fi
    done
    [[ "$rclash" == false ]] && echo "  [ok] redis indexes are unique per worktree"
  fi

  # ── Session isolation ──
  # A wildcard SESSION_DOMAIN (.myapp.test) makes one cookie valid on every
  # worktree host — the fastest way to undo session isolation.
  local sd wild=false
  for dwt in ${(f)"$(_gwt_worktree_paths)"}; do
    for f in $(_gwt_cfg_all env.copy); do
      [[ -f "$dwt/$f" ]] || continue
      sd="$(_gwt_env_get "$dwt/$f" SESSION_DOMAIN)"
      if [[ "$sd" == .* ]]; then
        echo "  [warn] ${dwt:t}/$f has SESSION_DOMAIN=$sd — that cookie is valid on every worktree host"
        wild=true
      fi
    done
  done
  [[ "$wild" == false ]] && echo "  [ok] no wildcard SESSION_DOMAIN"

  # ── Shared items ──
  # Everything [copy] shared copies IN has to be gitignored by the project, or it
  # shows up as untracked in every worktree gwt creates from here on. The source
  # directory itself sits outside the worktrees, so it needs nothing.
  local ovl obase osrc of orel notignored=false any_overlay=false
  obase="$(_gwt_shared_root)"
  for ovl in $(_gwt_cfg_all copy.shared); do
    any_overlay=true
    osrc="$obase/$ovl"
    if [[ ! -d "$osrc" ]]; then
      echo "  [warn] [copy] shared '$ovl' does not exist at ${obase/#$HOME/~}"
      continue
    fi
    for of in "$osrc"/**/*(D.N); do
      [[ "${of:t}" == ".DS_Store" ]] && continue   # never copied, so never checked
      orel="${of#$osrc/}"
      if ! git -C "$ref_path" check-ignore -q "$orel" 2>/dev/null; then
        echo "  [warn] shared '$orel' is not gitignored — it will show as untracked"
        echo "         in every worktree. Add it to .gitignore."
        notignored=true
      fi
    done
  done
  [[ "$any_overlay" == true && "$notignored" == false ]] && \
    echo "  [ok] every shared file is gitignored"

  # ── Dead env keys ──
  # Every key gwt writes should actually be read somewhere. A key nothing reads
  # is isolation that silently does not exist — REDIS_PREFIX in a config whose
  # redis block has no options.prefix, for example.
  if [[ -d "$ref_path/config" ]]; then
    local -a keys=()
    local dset k
    for dset in ${(f)"$(_gwt_cfg_all env.set)"}; do
      [[ "$dset" == *=* ]] && keys+=("${dset%%=*}")
    done
    for f in $(_gwt_cfg_all env.copy); do
      for dset in ${(f)"$(_gwt_cfg_all "env.$f.set")"}; do
        [[ "$dset" == *=* ]] && keys+=("${dset%%=*}")
      done
    done
    if _gwt_redis_enabled; then
      keys+=("$(_gwt_cfg redis.env-db REDIS_CACHE_DB)")
      [[ -n "$(_gwt_cfg redis.env-prefix)" ]] && keys+=("$(_gwt_cfg redis.env-prefix)")
    fi
    local unread=false
    for k in ${(u)keys}; do
      [[ -z "$k" ]] && continue
      # Read by the app's config/, or referenced as ${KEY} from another env line.
      grep -rq -- "['\"]${k}['\"]" "$ref_path/config" 2>/dev/null && continue
      local refd=false
      for f in $(_gwt_cfg_all env.copy); do
        [[ -f "$ref_path/$f" ]] || continue
        grep -q -- "\${${k}}" "$ref_path/$f" 2>/dev/null && { refd=true; break }
      done
      [[ "$refd" == true ]] && continue
      echo "  [warn] nothing reads '$k' — that override has no effect"
      unread=true
    done
    [[ "$unread" == false ]] && echo "  [ok] every declared env key is read by the app"
  fi

  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}
