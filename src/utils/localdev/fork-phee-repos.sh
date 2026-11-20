#!/usr/bin/env bash
# fork-phee-repos.sh - fork the openMF paymenthub-ee-* repos into your own GitHub
# account (or an org), keep each fork's default branch in sync with openMF, and set up
# local clones with:
#   origin   = your fork        (push here, then raise PRs against openMF)
#   upstream = openMF original  (fetch only; pushing to it is disabled)
#
# Needed because openMF branch protection no longer allows new branches in the
# upstream repos. Safe to re-run: existing forks are synced, existing clones only get
# their remotes adjusted - working trees, branches and uncommitted changes are never
# touched, and nothing is ever pushed.
#
# Requires: gh (logged in: gh auth login), git.

set -u

UPSTREAM_ORG="openMF"
PREFIX="paymenthub-ee-"
OWNER=""
CLONE_DIR="$HOME"
PROTOCOL=""
ONLY_REPOS=""
DO_SYNC=true
DO_CLONE=true
DRY_RUN=false
ASSUME_YES=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Fork the ${UPSTREAM_ORG}/${PREFIX}* repos and prepare local clones (origin = fork,
upstream = ${UPSTREAM_ORG}).

Options:
  -o, --owner NAME      GitHub account or org to fork into (prompted if omitted;
                        default is the account gh is logged in as)
  -d, --dir PATH        directory for local clones (default: \$HOME)
  -r, --repos "A B"     only these repos, with or without the "${PREFIX}" prefix
  -p, --protocol P      ssh or https for the origin remote (default: gh's git_protocol)
  -u, --upstream ORG    upstream GitHub org (default: ${UPSTREAM_ORG})
      --prefix STR      repo name prefix to select (default: ${PREFIX})
      --no-sync         don't sync existing forks with upstream
      --no-clone        only fork/sync on GitHub; don't touch local clones
  -n, --dry-run         show what would be done, change nothing
  -y, --yes             don't ask for confirmation (requires --owner)
  -h, --help            show this help

Examples:
  $(basename "$0") --dry-run
  $(basename "$0") -o myuser -d ~/src -r "bulk-processor connector-bulk"
EOF
}

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

# run a command that changes something; in dry-run mode just print it
run() {
  if $DRY_RUN; then
    echo "    [dry-run] $*"
    return 0
  fi
  "$@"
}

# "git@github.com:Owner/Repo.git" or "https://github.com/Owner/Repo(.git)" -> "owner/repo"
slug_of() {
  echo "$1" | sed -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##; s#\.git$##; s#/$##' \
    | tr '[:upper:]' '[:lower:]'
}

fork_url() {
  if [ "$PROTOCOL" = "ssh" ]; then
    echo "git@github.com:$OWNER/$1.git"
  else
    echo "https://github.com/$OWNER/$1.git"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--owner)    OWNER="$2"; shift 2 ;;
    -d|--dir)      CLONE_DIR="$2"; shift 2 ;;
    -r|--repos)    ONLY_REPOS="$2"; shift 2 ;;
    -p|--protocol) PROTOCOL="$2"; shift 2 ;;
    -u|--upstream) UPSTREAM_ORG="$2"; shift 2 ;;
    --prefix)      PREFIX="$2"; shift 2 ;;
    --no-sync)     DO_SYNC=false; shift ;;
    --no-clone)    DO_CLONE=false; shift ;;
    -n|--dry-run)  DRY_RUN=true; shift ;;
    -y|--yes)      ASSUME_YES=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done

command -v gh  >/dev/null 2>&1 || die "gh (GitHub CLI) is not installed: https://cli.github.com"
command -v git >/dev/null 2>&1 || die "git is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not logged in; run: gh auth login"

LOGIN=$(gh api user --jq .login 2>/dev/null) || die "could not read your GitHub login from gh"

if [ -z "$OWNER" ]; then
  $ASSUME_YES && die "--yes requires --owner"
  printf "Fork into which GitHub account or org? [%s]: " "$LOGIN"
  read -r OWNER
  OWNER=${OWNER:-$LOGIN}
fi

if [ -z "$PROTOCOL" ]; then
  PROTOCOL=$(gh config get git_protocol -h github.com 2>/dev/null)
  PROTOCOL=${PROTOCOL:-https}
fi
case "$PROTOCOL" in ssh|https) ;; *) die "--protocol must be ssh or https" ;; esac

# forking into an org needs --org; forking into your own account doesn't
ORG_FLAG=""
if [ "$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')" != "$(echo "$LOGIN" | tr '[:upper:]' '[:lower:]')" ]; then
  ORG_FLAG="--org $OWNER"
fi

info "Listing ${UPSTREAM_ORG}/${PREFIX}* repos"
REPO_LINES=$(gh repo list "$UPSTREAM_ORG" --limit 1000 --no-archived \
  --json name,defaultBranchRef \
  --jq ".[] | select(.name | startswith(\"$PREFIX\")) | \"\(.name) \(.defaultBranchRef.name)\"" | sort) \
  || die "could not list repos in $UPSTREAM_ORG"
[ -n "$REPO_LINES" ] || die "no repos matching ${PREFIX}* in $UPSTREAM_ORG"

if [ -n "$ONLY_REPOS" ]; then
  FILTERED=""
  for r in $ONLY_REPOS; do
    case "$r" in "$PREFIX"*) ;; *) r="$PREFIX$r" ;; esac
    line=$(echo "$REPO_LINES" | awk -v n="$r" '$1 == n')
    [ -n "$line" ] || die "$r is not an active repo in $UPSTREAM_ORG"
    FILTERED="$FILTERED$line"$'\n'
  done
  REPO_LINES=$(echo "$FILTERED" | sed '/^$/d')
fi

COUNT=$(echo "$REPO_LINES" | wc -l | tr -d ' ')
echo
echo "  Upstream : $UPSTREAM_ORG ($COUNT repos)"
echo "  Fork into: $OWNER${ORG_FLAG:+ (organisation)}"
echo "  Clones in: $CLONE_DIR  (origin via $PROTOCOL, upstream via https, fetch only)"
echo "  Sync     : $DO_SYNC   Clone/remotes: $DO_CLONE   Dry run: $DRY_RUN"
echo
if ! $ASSUME_YES && ! $DRY_RUN; then
  printf "Proceed? [y/N]: "
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1 ;; esac
fi

SUMMARY=""
NEED_WORKFLOW_SCOPE=false
add_summary() { SUMMARY="$SUMMARY$(printf '%-38s %-10s %-12s %-26s %-28s %s' "$@")"$'\n'; }

while read -r REPO DEFAULT_BRANCH; do
  [ -n "$REPO" ] || continue
  echo
  info "$REPO (default branch: $DEFAULT_BRANCH)"
  fork_state="-"; sync_state="-"; local_state="-"; branch="-"; dirty="-"

  # --- fork ---------------------------------------------------------------
  parent=$(gh repo view "$OWNER/$REPO" --json isFork,parent \
    --jq 'if .isFork then "\(.parent.owner.login)/\(.parent.name)" else "NOT-A-FORK" end' 2>/dev/null)
  if [ -z "$parent" ]; then
    echo "    creating fork $OWNER/$REPO"
    # shellcheck disable=SC2086
    if run gh repo fork "$UPSTREAM_ORG/$REPO" --clone=false --default-branch-only $ORG_FLAG; then
      fork_state="created"
    else
      fork_state="FAILED"
    fi
  elif [ "$parent" = "NOT-A-FORK" ] || [ "$(echo "$parent" | tr '[:upper:]' '[:lower:]')" != "$(echo "$UPSTREAM_ORG/$REPO" | tr '[:upper:]' '[:lower:]')" ]; then
    warn "$OWNER/$REPO exists but is not a fork of $UPSTREAM_ORG/$REPO (parent: $parent); skipping"
    add_summary "$REPO" "CONFLICT" "-" "-" "-" "-"
    continue
  else
    fork_state="exists"
  fi

  # --- sync the fork's default branch with upstream --------------------------
  if [ "$fork_state" = "exists" ] && $DO_SYNC; then
    if $DRY_RUN; then
      echo "    [dry-run] gh repo sync $OWNER/$REPO --branch $DEFAULT_BRANCH"
      sync_state="(dry-run)"
    elif out=$(gh repo sync "$OWNER/$REPO" --branch "$DEFAULT_BRANCH" 2>&1); then
      sync_state="synced"
    elif echo "$out" | grep -qi "workflow"; then
      # upstream commits touch .github/workflows, which GitHub only lets a token
      # with the "workflow" scope write
      warn "sync of $OWNER/$REPO needs the gh 'workflow' scope: gh auth refresh -h github.com -s workflow"
      sync_state="NEEDS-SCOPE"
      NEED_WORKFLOW_SCOPE=true
    else
      # diverged forks are reported, never force-synced
      warn "sync failed for $OWNER/$REPO: $out"
      sync_state="NOT-SYNCED"
    fi
  elif [ "$fork_state" = "created" ]; then
    sync_state="new"
  fi

  # --- local clone ----------------------------------------------------------
  if $DO_CLONE && [ "$fork_state" != "FAILED" ]; then
    path="$CLONE_DIR/$REPO"
    furl=$(fork_url "$REPO")
    uurl="https://github.com/$UPSTREAM_ORG/$REPO.git"
    fslug=$(slug_of "$furl"); uslug=$(slug_of "$uurl")

    if [ -d "$path" ] && ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
      warn "$path exists but is not a git repository; leaving it alone"
      local_state="NOT-GIT"
    elif [ -d "$path" ]; then
      local_state="existing"
      origin=$(git -C "$path" remote get-url origin 2>/dev/null || true)
      oslug=$(slug_of "$origin")
      if [ -z "$origin" ]; then
        echo "    adding origin -> $furl"
        run git -C "$path" remote add origin "$furl"
      elif [ "$oslug" = "$uslug" ]; then
        echo "    origin was $UPSTREAM_ORG; repointing origin -> $furl"
        run git -C "$path" remote set-url origin "$furl"
        local_state="repointed"
      elif [ "$oslug" != "$fslug" ]; then
        warn "$path: origin is $origin (neither the fork nor $UPSTREAM_ORG); leaving origin alone"
        local_state="OTHER-ORIGIN"
      fi
      current_up=$(git -C "$path" remote get-url upstream 2>/dev/null || true)
      if [ -z "$current_up" ]; then
        echo "    adding upstream -> $uurl"
        run git -C "$path" remote add upstream "$uurl"
      elif [ "$(slug_of "$current_up")" != "$uslug" ]; then
        warn "$path: upstream is $current_up, expected $uurl; leaving it alone"
      fi
    else
      echo "    cloning $furl -> $path"
      if run git clone -q "$furl" "$path"; then
        run git -C "$path" remote add upstream "$uurl"
        local_state="cloned"
      else
        local_state="CLONE-FAILED"
      fi
    fi

    if [ -d "$path/.git" ] || git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
      # never push to upstream from this clone
      run git -C "$path" remote set-url --push upstream DISABLED
      run git -C "$path" fetch -q upstream
      run git -C "$path" fetch -q origin
      branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")
      [ "$branch" = "HEAD" ] && branch="(detached $(git -C "$path" rev-parse --short HEAD))"
      if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then dirty="UNCOMMITTED"; else dirty="clean"; fi
    fi
  fi

  add_summary "$REPO" "$fork_state" "$sync_state" "$local_state" "$branch" "$dirty"
done <<< "$REPO_LINES"

echo
echo "Summary"
printf '%-38s %-10s %-12s %-26s %-28s %s\n' REPO FORK SYNC LOCAL BRANCH WORKTREE
printf '%s' "$SUMMARY"
echo
if $NEED_WORKFLOW_SCOPE; then
  echo "Some forks could not be synced because the upstream commits change GitHub workflow files."
  echo "Grant gh the workflow scope and re-run with --no-clone:"
  echo "  gh auth refresh -h github.com -s workflow"
  echo "  $(basename "$0") -o $OWNER --no-clone"
  echo
fi
echo "Nothing was pushed. Work on branches cut from upstream/<default branch>, push them to"
echo "origin (your fork) and open PRs against $UPSTREAM_ORG."
