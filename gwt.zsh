# ---------------------------------------------------------------------------
# gwt — git worktree manager (bare-clone pattern)
#
# Project-type aware. Each supported type (laravel, node, python, dotnet,
# generic) provides a set of driver functions named _gwt_<type>_<action>.
# The core flow calls them via _gwt_driver <action>, falling back to the
# generic (no-op) implementation when a type doesn't override an action.
#
# Adding a new language = add a block of _gwt_<newtype>_* functions and a
# menu entry in _gwt_prompt_project_type. Nothing in the core flow changes.
# ---------------------------------------------------------------------------

# oh-my-zsh git plugin aliases gwt → "git worktree"; remove it so our
# function definition below is not blocked.
unalias gwt 2>/dev/null

# gwt holds NO global state. There is no config file. The active project is
# derived from the current directory (see _gwt_load_context), and the two
# per-project settings (type + reference branch) live in the bare repo's own
# git config (gwt.type / gwt.ref), written at init time. This makes gwt work
# across any number of projects with zero shared configuration.

# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------

# Normalise a branch name to a URL/folder-safe slug.
# feature/PROJ-5031 → proj-5031
# hotfix/PROJ-99    → proj-99
# staging              → staging
_gwt_normalize() {
  local branch="$1"
  branch="${branch##*/}"   # strip prefix up to and including last /
  branch="${branch:l}"     # lowercase
  branch="${branch//_/-}"  # underscores → dashes
  echo "$branch"
}

# True if the bare repo has the given branch.
_gwt_branch_exists() {
  git -C "$GWT_BARE_ROOT" show-ref --verify --quiet "refs/heads/$1" 2>/dev/null
}

# Best-effort project type from files in the current worktree. Only used as a
# fallback when the bare repo has no stored gwt.type (e.g. a repo not created
# by this version of gwt).
_gwt_autodetect_type() {
  if [[ -f composer.json ]]; then
    echo laravel
  elif [[ -f package.json ]]; then
    echo node
  elif [[ -f pyproject.toml || -f requirements.txt || -f setup.py ]]; then
    echo python
  elif [[ -n "$(print -l *.sln *.csproj(N) 2>/dev/null)" ]]; then
    echo dotnet
  else
    echo generic
  fi
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
  GWT_PROJECT_TYPE="$(git -C "$GWT_BARE_ROOT" config gwt.type 2>/dev/null)"
  GWT_REF_WORKTREE="$(git -C "$GWT_BARE_ROOT" config gwt.ref 2>/dev/null)"
  [[ -n "$GWT_PROJECT_TYPE" ]] || GWT_PROJECT_TYPE="$(_gwt_autodetect_type)"
  [[ -n "$GWT_REF_WORKTREE" ]] || GWT_REF_WORKTREE="main"
  return 0
}

# ---------------------------------------------------------------------------
# Driver dispatch
#
# _gwt_driver <action> [args…] calls _gwt_<type>_<action> if it exists,
# otherwise _gwt_generic_<action>. So a type only overrides what differs
# from generic.
# ---------------------------------------------------------------------------
_gwt_driver() {
  local action="$1"; shift
  local fn="_gwt_${GWT_PROJECT_TYPE}_${action}"
  (( $+functions[$fn] )) || fn="_gwt_generic_${action}"
  if [[ -n "$_GWT_DRY" ]]; then
    case "$action" in
      # Pure actions return values the caller needs — always run them.
      ref_default|dep_dirs|url) "$fn" "$@" ;;
      # Everything else has side effects — preview only.
      *) echo "  [dry] ${GWT_PROJECT_TYPE}:${action} $*" ;;
    esac
  else
    "$fn" "$@"
  fi
}

# Run a command, or just print it when in --test/--dry mode.
_gwt_run() {
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] $*"
  else
    "$@"
  fi
}

# Dependency symlink helpers — driven entirely by each type's dep_dirs list,
# so the symlink/unlink/check logic stays generic.

# Symlink each declared dep dir from the reference worktree.
_gwt_link_deps() {
  local ref_path="$1" dir="$2" d
  for d in $(_gwt_driver dep_dirs); do
    if [[ -n "$_GWT_DRY" ]]; then
      echo "  [dry] symlink $d ← $GWT_REF_WORKTREE"
      continue
    fi
    if [[ -d "$dir/$d" && ! -L "$dir/$d" ]]; then
      echo "  [warn] $d is a real directory — skipping symlink"
    elif [[ -e "$ref_path/$d" || -L "$ref_path/$d" ]]; then
      ln -s "$ref_path/$d" "$dir/$d"
      echo "  [ok] Symlinked $d from $GWT_REF_WORKTREE"
    else
      echo "  [warn] $ref_path/$d not found — skipping $d symlink"
    fi
  done
}

# Remove dep-dir symlinks (leaves real directories untouched).
_gwt_unlink_deps() {
  local dir="$1" d
  for d in $(_gwt_driver dep_dirs); do
    if [[ -n "$_GWT_DRY" ]]; then
      echo "  [dry] remove $d symlink (if present)"
      continue
    fi
    if [[ -L "$dir/$d" ]]; then
      rm "$dir/$d"
      echo "  [ok] Removed $d symlink"
    fi
  done
}

# Return 0 (true) if any dep dir is a real directory (not a symlink).
_gwt_check_real_deps() {
  local dir="$1" d
  for d in $(_gwt_driver dep_dirs); do
    [[ -d "$dir/$d" && ! -L "$dir/$d" ]] && return 0
  done
  return 1
}

# Human-readable list of dep dirs for warning messages ("vendor, node_modules").
_gwt_dep_list() {
  local d out=""
  for d in $(_gwt_driver dep_dirs); do
    out="${out:+$out, }$d"
  done
  echo "$out"
}

# Project-type selection menu (sets GWT_PROJECT_TYPE).
_gwt_prompt_project_type() {
  echo "  Project type:"
  echo "    1) laravel   (composer + node, Herd .test domain + TLS)"
  echo "    2) node      (npm / yarn / pnpm, auto-detected)"
  echo "    3) python    (venv + pip, or poetry)"
  echo "    4) dotnet    (dotnet restore)"
  echo "    5) generic   (git worktrees only, no dep/env handling)"
  local choice=""
  vared -p "  Select [1]: " choice
  case "$choice" in
    2) GWT_PROJECT_TYPE=node ;;
    3) GWT_PROJECT_TYPE=python ;;
    4) GWT_PROJECT_TYPE=dotnet ;;
    5) GWT_PROJECT_TYPE=generic ;;
    *) GWT_PROJECT_TYPE=laravel ;;
  esac
  echo "  [info] Project type: $GWT_PROJECT_TYPE"
}

# ===========================================================================
# Drivers
#
# Interface (every action falls back to generic if not overridden):
#   ref_default                 → echo default reference branch name
#   dep_dirs                    → echo space-separated dirs to share via symlink
#   install_deps <path>         → install real dependencies in <path>
#   init_env <domain> <path>    → set up env file from example (reference wt)
#   copy_env <domain> <ref> <path> → copy env from reference into new worktree
#   make_dirs <path>            → create any required (gitignored) dirs
#   server_up <domain> <path>   → wire up local dev server (+ TLS) for <domain>
#   server_down <domain> <path> → tear down local dev server for <domain>
#   url <domain>                → echo the browsable URL, or nothing
# ===========================================================================

# --- driver: generic (defaults / no-ops) -----------------------------------
_gwt_generic_ref_default()    { echo "main"; }
_gwt_generic_dep_dirs()       { :; }
_gwt_generic_install_deps()   { echo "  [info] No dependency install step for this project type"; }
_gwt_generic_init_env()       { :; }
_gwt_generic_copy_env()       { :; }
_gwt_generic_make_dirs()      { :; }
_gwt_generic_server_up()      { :; }
_gwt_generic_server_down()    { :; }
_gwt_generic_url()            { :; }

# Shared env helpers for plain ".env" projects (node, python).
_gwt_plain_init_env() {
  local dir="$2"
  if [[ -f "$dir/.env" ]]; then
    echo "  [ok] .env found"
  elif [[ -f "$dir/.env.example" ]]; then
    cp "$dir/.env.example" "$dir/.env"
    echo "  [ok] Copied .env.example → .env"
    echo "  [!]  Review .env for environment-specific values"
  else
    echo "  [info] No .env/.env.example — skipping env setup"
  fi
}
_gwt_plain_copy_env() {
  local ref_path="$2" dir="$3"
  if [[ -f "$dir/.env" ]]; then
    echo "  [warn] .env already exists — skipping copy"
  elif [[ -f "$ref_path/.env" ]]; then
    cp "$ref_path/.env" "$dir/.env"
    echo "  [ok] Copied .env from reference worktree"
  else
    echo "  [info] No .env in reference worktree — skipping"
  fi
}

# --- driver: laravel -------------------------------------------------------
_gwt_laravel_ref_default()    { echo "staging"; }
_gwt_laravel_dep_dirs()       { echo "vendor node_modules"; }
_gwt_laravel_url()            { echo "https://${1}.test"; }

_gwt_laravel_make_dirs() {
  local dir="$1"
  mkdir -p "$dir/bootstrap/cache"
  echo "  [ok] Created bootstrap/cache/"
}

_gwt_laravel_install_deps() {
  local dir="$1"
  if [[ -d "$dir/vendor" ]]; then
    echo "  [ok] vendor/ found"
  else
    echo "  [..] Running composer install…"
    if ( cd "$dir" && composer install ); then
      echo "  [ok] composer install complete"
    else
      echo "  [error] composer install failed — run it manually inside $dir"
    fi
  fi
  if [[ -d "$dir/node_modules" ]]; then
    echo "  [ok] node_modules/ found"
  else
    echo "  [..] Running yarn install…"
    if ( cd "$dir" && yarn install ); then
      echo "  [ok] yarn install complete"
    else
      echo "  [error] yarn install failed — run it manually inside $dir"
    fi
  fi
}

_gwt_laravel_init_env() {
  local domain="$1" dir="$2"
  if [[ -f "$dir/.env" ]]; then
    echo "  [ok] .env found"
  elif [[ -f "$dir/.env.example" ]]; then
    cp "$dir/.env.example" "$dir/.env"
    sed -i '' "s|^APP_URL=.*|APP_URL=https://${domain}.test|" "$dir/.env"
    echo "  [ok] Copied .env.example → .env"
    echo "  [!]  Configure APP_KEY, DB_HOST, DB_DATABASE, DB_USERNAME, DB_PASSWORD in .env"
  else
    echo "  [warn] No .env or .env.example found — create .env manually"
  fi
}

_gwt_laravel_copy_env() {
  local domain="$1" ref_path="$2" dir="$3"
  if [[ -f "$dir/.env" ]]; then
    echo "  [warn] .env already exists — skipping copy"
  elif [[ -f "$ref_path/.env" ]]; then
    cp "$ref_path/.env" "$dir/.env"
    sed -i '' "s|^APP_URL=.*|APP_URL=https://${domain}.test|" "$dir/.env"
    echo "  [ok] Copied .env — APP_URL set to https://${domain}.test"
  else
    echo "  [warn] No .env in reference worktree — skipping"
  fi
}

_gwt_laravel_server_up() {
  local domain="$1" dir="$2"
  local herd_sites="$HOME/Library/Application Support/Herd/config/valet/Sites"
  local herd_certs="$HOME/Library/Application Support/Herd/config/valet/Certificates"

  if [[ -L "$herd_sites/$domain" ]]; then
    echo "  [ok] Herd site already linked: ${domain}.test"
  else
    ln -s "$dir" "$herd_sites/$domain"
    echo "  [ok] Herd site linked: ${domain} → $dir"
  fi

  if herd secure "$domain"; then
    echo "  [ok] herd secure ${domain}"
  else
    echo "  [warn] herd secure failed — run manually: herd secure ${domain}"
  fi

  # Point Vite at the per-domain Herd cert (Herd appends .test to the cert name).
  if [[ -f "$dir/.env" ]]; then
    sed -i '' "s|^VITE_HTTPS_KEY_PATH=.*|VITE_HTTPS_KEY_PATH=\"${herd_certs}/${domain}.test.key\"|"  "$dir/.env"
    sed -i '' "s|^VITE_HTTPS_CERT_PATH=.*|VITE_HTTPS_CERT_PATH=\"${herd_certs}/${domain}.test.crt\"|" "$dir/.env"
    echo "  [ok] Updated Vite cert paths in .env"
  fi
}

_gwt_laravel_server_down() {
  local domain="$1" dir="$2"
  local herd_sites="$HOME/Library/Application Support/Herd/config/valet/Sites"
  herd unsecure "$domain" 2>/dev/null && echo "  [ok] herd unsecure ${domain}"
  if [[ -L "$herd_sites/$domain" ]]; then
    rm "$herd_sites/$domain"
    echo "  [ok] Herd site unlinked: ${domain}"
  fi
}

# --- driver: node ----------------------------------------------------------
_gwt_node_dep_dirs()       { echo "node_modules"; }
_gwt_node_init_env()       { _gwt_plain_init_env "$@"; }
_gwt_node_copy_env()       { _gwt_plain_copy_env "$@"; }

_gwt_node_install_deps() {
  local dir="$1"
  if [[ -d "$dir/node_modules" ]]; then
    echo "  [ok] node_modules/ found"
    return
  fi
  local pm="npm"
  [[ -f "$dir/yarn.lock" ]]      && pm="yarn"
  [[ -f "$dir/pnpm-lock.yaml" ]] && pm="pnpm"
  echo "  [..] Running $pm install…"
  if ( cd "$dir" && $pm install ); then
    echo "  [ok] $pm install complete"
  else
    echo "  [error] $pm install failed — run it manually inside $dir"
  fi
}

# --- driver: python --------------------------------------------------------
_gwt_python_dep_dirs()       { echo ".venv"; }
_gwt_python_init_env()       { _gwt_plain_init_env "$@"; }
_gwt_python_copy_env()       { _gwt_plain_copy_env "$@"; }

_gwt_python_install_deps() {
  local dir="$1"
  if [[ -d "$dir/.venv" ]]; then
    echo "  [ok] .venv/ found"
    return
  fi
  if [[ -f "$dir/pyproject.toml" ]] && command -v poetry >/dev/null 2>&1; then
    echo "  [..] Running poetry install…"
    if ( cd "$dir" && poetry install ); then
      echo "  [ok] poetry install complete"
    else
      echo "  [error] poetry install failed — run it manually inside $dir"
    fi
  else
    echo "  [..] Creating .venv…"
    if ( cd "$dir" && python3 -m venv .venv \
         && { [[ -f requirements.txt ]] && .venv/bin/pip install -r requirements.txt || true; } ); then
      echo "  [ok] .venv ready"
      [[ -f "$dir/requirements.txt" ]] || echo "  [info] No requirements.txt — empty venv created"
    else
      echo "  [error] venv setup failed — run it manually inside $dir"
    fi
  fi
}

# --- driver: dotnet --------------------------------------------------------
# NuGet packages live in the global ~/.nuget cache, so nothing to symlink.
_gwt_dotnet_dep_dirs()       { :; }

_gwt_dotnet_install_deps() {
  local dir="$1"
  echo "  [..] Running dotnet restore…"
  if ( cd "$dir" && dotnet restore ); then
    echo "  [ok] dotnet restore complete"
  else
    echo "  [error] dotnet restore failed — run it manually inside $dir"
  fi
}

# Copy gitignored local settings from the reference worktree, if present.
_gwt_dotnet_copy_env() {
  local ref_path="$2" dir="$3"
  local f="appsettings.Development.json"
  if [[ -f "$ref_path/$f" && ! -f "$dir/$f" ]]; then
    cp "$ref_path/$f" "$dir/$f"
    echo "  [ok] Copied $f from reference worktree"
  fi
}

# ---------------------------------------------------------------------------
# gwt-init  (also callable as: gwt init)
# ---------------------------------------------------------------------------
gwt-init() {
  # No global state: these are local so init (or a --test preview) never leaks
  # into the surrounding shell. Per-project settings are persisted into the
  # bare repo's own git config at the end.
  local GWT_BARE_ROOT GWT_WORKTREE_PARENT GWT_PROJECT GWT_PROJECT_TYPE GWT_REF_WORKTREE
  GWT_PROJECT_TYPE=laravel

  echo ""
  echo "  gwt init"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  [[ -n "$_GWT_DRY" ]] && echo "  [test mode] preview only — no clone, no files, no Herd changes"
  echo ""

  # The project is created inside the CURRENT directory. Warn up front, show
  # where it will land, and let the user bail out to cd elsewhere before any
  # questions are asked.
  local cwd="$PWD"
  local cwd_disp="${cwd/#$HOME/~}"
  echo "  [!] This project will be created inside the current directory:"
  echo ""
  echo "      ${cwd_disp}/"
  echo "      ├── <project>.git/         ← bare repo"
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

  # Collect every setting, show a review with the directory tree, then confirm
  # before touching anything. Answering "no" starts the questions over.
  local remote project project_input default_ref ref_branch
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
        if [[ "$remote" =~ ^git@.+:.+$ || "$remote" =~ ^https?://.+$ ]]; then
          break
        fi
        echo "  [error] Must be an SSH (git@…) or HTTPS (https://…) URL. Try again."
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

    # ── Project type ──
    _gwt_prompt_project_type
    echo ""

    # ── Reference branch ──
    default_ref="$(_gwt_driver ref_default)"
    ref_branch=""
    vared -p "  Reference branch [$default_ref]: " ref_branch
    [[ -z "$ref_branch" ]] && ref_branch="$default_ref"

    # The current directory IS the project folder: the bare repo and the
    # worktrees are created directly inside it (no extra nesting).
    bare_root="$cwd/$project.git"
    wt_parent="$cwd"

    # ── Review + confirm ──
    echo ""
    echo "  Review:  [type: $GWT_PROJECT_TYPE]"
    echo "    Project   : $project"
    echo "    Remote    : $remote"
    echo "    Reference : $ref_branch"
    echo ""
    echo "    ${cwd_disp}/"
    echo "    ├── ${project}.git/          ← bare repo"
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

  # ── Clone the bare repo + persist per-project settings into its git config ─
  if [[ -n "$_GWT_DRY" ]]; then
    echo "  [dry] git clone --bare $remote $bare_root"
    echo "  [dry] git -C $bare_root config gwt.type $GWT_PROJECT_TYPE"
    echo "  [dry] git -C $bare_root config gwt.ref  $ref_branch"
  elif [[ -d "$bare_root" ]]; then
    echo "  [ok] Bare repo already present at $bare_root"
    git -C "$bare_root" config gwt.type "$GWT_PROJECT_TYPE"
    git -C "$bare_root" config gwt.ref  "$ref_branch"
  else
    mkdir -p "$wt_parent"
    echo "  [..] Cloning bare repo…"
    if ! git clone --bare "$remote" "$bare_root"; then
      echo "  [error] git clone failed."
      return 1
    fi

    # Fix fetch refspec so git fetch works properly on a bare clone
    git -C "$bare_root" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git -C "$bare_root" fetch --all --quiet

    # Persist per-project settings inside the repo itself (no global config).
    git -C "$bare_root" config gwt.type "$GWT_PROJECT_TYPE"
    git -C "$bare_root" config gwt.ref  "$ref_branch"
    echo "  [ok] Bare repo cloned; settings saved to its git config"
  fi

  local ref_folder="${GWT_PROJECT}-${GWT_REF_WORKTREE}"
  local ref_path="$GWT_WORKTREE_PARENT/$ref_folder"
  local ref_domain="${GWT_REF_WORKTREE}.${GWT_PROJECT}"

  # ── Step 2: Reference worktree ──────────────────────────────────────────
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

  # ── Step 3: type-specific setup ─────────────────────────────────────────
  _gwt_driver make_dirs    "$ref_path"
  _gwt_driver init_env     "$ref_domain" "$ref_path"
  _gwt_driver server_up    "$ref_domain" "$ref_path"
  _gwt_driver install_deps "$ref_path"

  # ── Summary ─────────────────────────────────────────────────────────────
  local ref_url
  ref_url="$(_gwt_driver url "$ref_domain")"
  echo ""
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "    gwt init complete"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "    Type       : $GWT_PROJECT_TYPE"
  echo "    Bare repo  : $GWT_BARE_ROOT"
  echo "    Reference  : $ref_path"
  [[ -n "$ref_url" ]] && echo "    URL        : $ref_url"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "    gwt <branch>             checkout an existing branch"
  echo "    gwt <branch> <base>      create new branch off <base>"
  echo "    gwt list                 list all worktrees"
  echo "    gwt remove <branch>      remove a worktree"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ---------------------------------------------------------------------------
# gwt-help  (also: gwt -h | --help | help)
# ---------------------------------------------------------------------------
_gwt_help() {
  echo ""
  echo "  gwt — git worktree manager (bare-clone pattern)"
  echo ""
  echo "  COMMANDS"
  echo "    gwt init                 First-time project setup, in the CURRENT folder:"
  echo "                             clone a bare repo, create the reference worktree,"
  echo "                             set up .env, link the dev server, and install"
  echo "                             dependencies. Run once per project."
  echo ""
  echo "    gwt <branch>             Check out an existing branch as a new worktree,"
  echo "                             sharing vendor/ + node_modules/ (symlinked) from"
  echo "                             the reference worktree."
  echo ""
  echo "    gwt <branch> <base>      Create <branch> off <base>, then check it out as"
  echo "                             a new worktree."
  echo ""
  echo "    gwt list                 List all worktrees of the current project."
  echo ""
  echo "    gwt remove <branch>      Remove a worktree: tear down its dev-server link"
  echo "                             and dependency symlinks, then delete it."
  echo ""
  echo "    gwt help | -h | --help   Show this help."
  echo ""
  echo "  FLAGS"
  echo "    --test, --dry            Preview any command without making changes."
  echo "    --force                  (remove only) Also delete real, non-symlinked"
  echo "                             dependency directories."
  echo ""
  echo "  NOTES"
  echo "    • Run 'gwt init' from the folder you want the project created in."
  echo "    • All other commands run from inside the project (a worktree, or the"
  echo "      project folder) — the active project is derived from your location."
  echo "    • Per-project settings (type + reference branch) live in the bare repo's"
  echo "      git config (gwt.type / gwt.ref). There is no global config file."
  echo ""
}

# ---------------------------------------------------------------------------
# gwt <branch> [base-branch]
# ---------------------------------------------------------------------------
gwt() {
  # Pull --test/--dry and -h/--help out of the args. Declared local here so
  # that — via zsh's dynamic scoping — gwt-init, gwt-remove and every driver
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

  local branch="$1"
  local base_branch="$2"

  # ── No argument → help ────────────────────────────────────────────────────
  if [[ -z "$branch" ]]; then
    _gwt_help
    return 0
  fi

  # ── Subcommand routing ───────────────────────────────────────────────────
  case "$branch" in
    init)   gwt-init;             return $? ;;
    list)   gwt-list;             return $? ;;
    remove) gwt-remove "$2" "$3"; return $? ;;
    help)   _gwt_help;            return 0 ;;
  esac

  # ── Load project context from the current directory ──────────────────────
  local GWT_BARE_ROOT GWT_WORKTREE_PARENT GWT_PROJECT GWT_PROJECT_TYPE GWT_REF_WORKTREE
  if ! _gwt_load_context; then
    echo "Error: not inside a gwt project."
    echo "       cd into a project worktree (or its parent folder) and retry,"
    echo "       or run 'gwt init' to set up a new project."
    return 1
  fi

  # ── Derive names ─────────────────────────────────────────────────────────
  local slug
  slug="$(_gwt_normalize "$branch")"
  local folder="${GWT_PROJECT}-${slug}"
  local domain="${slug}.${GWT_PROJECT}"
  local worktree_path="$GWT_WORKTREE_PARENT/$folder"
  local ref_path="$GWT_WORKTREE_PARENT/${GWT_PROJECT}-${GWT_REF_WORKTREE}"

  # ── Guards ───────────────────────────────────────────────────────────────
  if [[ ! -d "$ref_path" ]]; then
    echo "Error: reference worktree not found at $ref_path"
    echo "       Run: gwt init"
    return 1
  fi

  if [[ -d "$worktree_path" ]]; then
    echo "Error: worktree already exists at $worktree_path"
    return 1
  fi

  if [[ -z "$base_branch" ]]; then
    if ! _gwt_branch_exists "$branch"; then
      echo "Error: branch '$branch' does not exist in the bare repo."
      echo "       To create it: gwt $branch <base-branch>"
      return 1
    fi
  else
    if ! _gwt_branch_exists "$base_branch"; then
      echo "Error: base branch '$base_branch' does not exist in the bare repo."
      return 1
    fi
    if _gwt_branch_exists "$branch"; then
      echo "Error: branch '$branch' already exists."
      echo "       Check it out directly with: gwt $branch"
      return 1
    fi
  fi

  # ── Preview ──────────────────────────────────────────────────────────────
  local url
  url="$(_gwt_driver url "$domain")"
  echo ""
  if [[ -z "$base_branch" ]]; then
    echo "  Branch  : $branch"
  else
    echo "  Branch  : $branch  (new, off $base_branch)"
  fi
  echo "  Folder  : $worktree_path"
  [[ -n "$url" ]] && echo "  URL     : $url"
  echo ""

  # ── Mode 2: create branch in bare repo ───────────────────────────────────
  if [[ -n "$base_branch" ]]; then
    _gwt_run git -C "$GWT_BARE_ROOT" branch "$branch" "$base_branch"
    echo "  [ok] Created branch '$branch' off '$base_branch'"
  fi

  # ── Add worktree ─────────────────────────────────────────────────────────
  _gwt_run git -C "$GWT_BARE_ROOT" worktree add "$worktree_path" "$branch"
  echo "  [ok] Worktree added"

  # ── Type-specific setup ──────────────────────────────────────────────────
  _gwt_link_deps "$ref_path" "$worktree_path"
  _gwt_driver copy_env  "$domain" "$ref_path" "$worktree_path"
  _gwt_driver make_dirs "$worktree_path"
  _gwt_driver server_up "$domain" "$worktree_path"

  # ── Summary ──────────────────────────────────────────────────────────────
  local dep_list
  dep_list="$(_gwt_dep_list)"
  echo ""
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "    Worktree ready"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "    Branch  : $branch"
  echo "    Path    : $worktree_path"
  [[ -n "$url" ]] && echo "    URL     : $url"
  echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ -n "$dep_list" ]]; then
    echo "    $dep_list symlinked from $GWT_REF_WORKTREE"
    echo "    Re-run the install step manually if this branch"
    echo "    has dependency changes."
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# gwt-remove <branch>  (also callable as: gwt remove <branch>)
# ---------------------------------------------------------------------------
gwt-remove() {
  local branch="$1"
  local force=false
  [[ "$2" == "--force" ]] && force=true

  if [[ -z "$branch" ]]; then
    echo "Usage: gwt remove <branch> [--force]"
    return 1
  fi

  # ── Load project context from the current directory ──────────────────────
  local GWT_BARE_ROOT GWT_WORKTREE_PARENT GWT_PROJECT GWT_PROJECT_TYPE GWT_REF_WORKTREE
  if ! _gwt_load_context; then
    echo "Error: not inside a gwt project."
    echo "       cd into a project worktree (or its parent folder) and retry."
    return 1
  fi

  # Strip project prefix if user passed the full folder name (e.g. myapp-staging → staging)
  branch="${branch#${GWT_PROJECT}-}"

  local slug
  slug="$(_gwt_normalize "$branch")"
  local folder="${GWT_PROJECT}-${slug}"
  local domain="${slug}.${GWT_PROJECT}"
  local worktree_path="$GWT_WORKTREE_PARENT/$folder"

  if [[ ! -d "$worktree_path" ]]; then
    echo "Error: no worktree found at $worktree_path"
    return 1
  fi

  # ── Guard: warn if removing the reference worktree ───────────────────────
  if [[ "$folder" == "${GWT_PROJECT}-${GWT_REF_WORKTREE}" ]]; then
    local other_wts
    other_wts=$(git -C "$GWT_BARE_ROOT" worktree list --porcelain \
      | grep '^worktree ' \
      | grep -v "^worktree $GWT_BARE_ROOT$" \
      | grep -v "^worktree $worktree_path$" \
      | wc -l | tr -d ' ')
    local dep_list
    dep_list="$(_gwt_dep_list)"
    if [[ "$other_wts" -gt 0 && -n "$dep_list" ]]; then
      echo "  [warn] '$GWT_REF_WORKTREE' is the reference worktree."
      echo "         $other_wts other worktree(s) have symlinks pointing to it."
      echo "         Removing it will break their $dep_list symlinks."
      if [[ -z "$_GWT_DRY" ]]; then
        local confirm=""
        vared -p "  Proceed? [y/N]: " confirm
        [[ "${confirm:l}" != "y" ]] && echo "  Aborted." && return 1
      fi
    fi
  fi

  # ── Guard: real dep directories block removal (unless --force) ───────────
  if [[ -z "$_GWT_DRY" && "$force" == false ]] && _gwt_check_real_deps "$worktree_path"; then
    echo "  [error] Real dependency directories exist in this worktree."
    echo "          Nothing has been changed."
    echo ""
    echo "          To delete everything: gwt remove $branch --force"
    return 1
  fi

  # ── Remove dep symlinks ──────────────────────────────────────────────────
  _gwt_unlink_deps "$worktree_path"

  # ── Tear down local dev server ───────────────────────────────────────────
  _gwt_driver server_down "$domain" "$worktree_path"

  # ── Remove worktree ──────────────────────────────────────────────────────
  _gwt_run git -C "$GWT_BARE_ROOT" worktree remove "$worktree_path" --force 2>/dev/null
  if [[ -z "$_GWT_DRY" && -d "$worktree_path" ]]; then
    rm -rf "$worktree_path"
    echo "  [ok] Deleted directory: $worktree_path"
  fi
  _gwt_run git -C "$GWT_BARE_ROOT" worktree prune 2>/dev/null
  echo "  [ok] Worktree removed: $folder"
  echo ""
  echo "  Done. '$folder' has been removed."
  echo ""
}

# ---------------------------------------------------------------------------
# gwt-list  (also callable as: gwt list)
# ---------------------------------------------------------------------------
gwt-list() {
  local GWT_BARE_ROOT GWT_WORKTREE_PARENT GWT_PROJECT GWT_PROJECT_TYPE GWT_REF_WORKTREE
  if ! _gwt_load_context; then
    echo "Error: not inside a gwt project."
    echo "       cd into a project worktree (or its parent folder) and retry."
    return 1
  fi
  echo "  Project: $GWT_PROJECT  [type: $GWT_PROJECT_TYPE, ref: $GWT_REF_WORKTREE]"
  git -C "$GWT_BARE_ROOT" worktree list
}
