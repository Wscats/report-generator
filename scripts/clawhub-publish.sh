#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# clawhub-publish.sh
#
# Usage:
#   ./scripts/clawhub-publish.sh <project_dir> --version=<semver> [--dry-run]
#
# Example:
#   ./scripts/clawhub-publish.sh /Users/reky/Documents/GitHub/report-generator --version=1.0.1
#
# Or (recommended) as a clawhub wrapper:
#   clawhub publish /Users/reky/Documents/GitHub/report-generator --version=1.0.1
#
# Responsibilities:
#   1. Validate semver (x.y.z[-prerelease][+build]).
#   2. Ensure target dir is a clean git worktree (skippable via --no-git-check).
#   3. Ensure new version > current version in VERSION file.
#   4. Bump VERSION file, sync SKILL.md header, prepend CHANGELOG.md entry.
#   5. Call `clawhub publish` with .clawhubignore honoured, so this script and
#      other non-skill files are NOT shipped.
# -----------------------------------------------------------------------------

set -euo pipefail

# ---------- helpers ----------
log()  { printf '\033[1;34m[publish]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[publish]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[publish]\033[0m %s\n' "$*" >&2; exit 1; }

semver_re='^([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

semver_gt() {
  # returns 0 if $1 > $2 (strict greater), 1 otherwise
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 1
  local highest
  highest=$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)
  [[ "$highest" == "$a" ]]
}

# ---------- parse args ----------
PROJECT_DIR=""
NEW_VERSION=""
DRY_RUN=0
SKIP_GIT_CHECK=0

for arg in "$@"; do
  case "$arg" in
    --version=*)       NEW_VERSION="${arg#--version=}" ;;
    --dry-run)         DRY_RUN=1 ;;
    --no-git-check)    SKIP_GIT_CHECK=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    -*)
      die "unknown flag: $arg" ;;
    *)
      [[ -z "$PROJECT_DIR" ]] && PROJECT_DIR="$arg" || die "unexpected positional arg: $arg"
      ;;
  esac
done

[[ -n "$PROJECT_DIR"  ]] || die "project_dir is required"
[[ -n "$NEW_VERSION"  ]] || die "--version=<semver> is required"
[[ -d "$PROJECT_DIR"  ]] || die "project_dir not found: $PROJECT_DIR"
[[ "$NEW_VERSION" =~ $semver_re ]] || die "invalid semver: $NEW_VERSION (expected x.y.z)"

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
log "project  : $PROJECT_DIR"
log "version  : $NEW_VERSION"
[[ $DRY_RUN -eq 1 ]] && log "mode     : dry-run (no files written, no publish)"

# ---------- git cleanliness ----------
if [[ $SKIP_GIT_CHECK -eq 0 && -d "$PROJECT_DIR/.git" ]]; then
  if ! git -C "$PROJECT_DIR" diff --quiet || ! git -C "$PROJECT_DIR" diff --cached --quiet; then
    die "git worktree is dirty; commit or stash first (use --no-git-check to bypass)"
  fi
fi

# ---------- current version ----------
VERSION_FILE="$PROJECT_DIR/VERSION"
CUR_VERSION="0.0.0"
if [[ -f "$VERSION_FILE" ]]; then
  CUR_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
  [[ -z "$CUR_VERSION" ]] && CUR_VERSION="0.0.0"
fi
log "current  : $CUR_VERSION"

if [[ "$CUR_VERSION" == "$NEW_VERSION" ]]; then
  die "version $NEW_VERSION is already published (VERSION file matches)"
fi
if ! semver_gt "$NEW_VERSION" "$CUR_VERSION"; then
  die "new version $NEW_VERSION must be greater than current $CUR_VERSION"
fi

# ---------- ignore file ----------
IGNORE_FILE="$PROJECT_DIR/.clawhubignore"
if [[ ! -f "$IGNORE_FILE" ]]; then
  warn ".clawhubignore not found, will create a default one"
  if [[ $DRY_RUN -eq 0 ]]; then
    cat > "$IGNORE_FILE" <<'EOF'
# clawhub publish ignore rules
# paths listed here are NOT shipped to clawhub
scripts/
.git/
.github/
.gitattributes
.gitignore
.clawhubignore
.DS_Store
node_modules/
*.log
*.tmp
EOF
  fi
fi

# Make sure scripts/ is ignored (defensive; guarantees this script itself
# never appears in the published artefact).
if ! grep -qE '^[[:space:]]*scripts/?[[:space:]]*$' "$IGNORE_FILE" 2>/dev/null; then
  warn ".clawhubignore is missing 'scripts/' rule, appending it"
  [[ $DRY_RUN -eq 0 ]] && printf '\nscripts/\n' >> "$IGNORE_FILE"
fi

# ---------- bump files ----------
TS="$(date +%Y-%m-%d)"

bump_files() {
  # 1) VERSION
  printf '%s\n' "$NEW_VERSION" > "$VERSION_FILE"

  # 2) SKILL.md header ("version:" metadata line, insert or replace)
  local skill="$PROJECT_DIR/SKILL.md"
  if [[ -f "$skill" ]]; then
    if grep -qE '^<!-- version: .* -->$' "$skill"; then
      # portable in-place replace (macOS + GNU)
      sed -i.bak -E "s|^<!-- version: .* -->$|<!-- version: ${NEW_VERSION} (${TS}) -->|" "$skill"
      rm -f "${skill}.bak"
    else
      local tmp="${skill}.tmp"
      { printf '<!-- version: %s (%s) -->\n' "$NEW_VERSION" "$TS"; cat "$skill"; } > "$tmp"
      mv "$tmp" "$skill"
    fi
  fi

  # 3) CHANGELOG.md (prepend new entry; keep existing content)
  local changelog="$PROJECT_DIR/CHANGELOG.md"
  local header="# Changelog"
  local entry
  entry="$(printf '## %s - %s\n\n- Release %s.\n' "$NEW_VERSION" "$TS" "$NEW_VERSION")"
  if [[ -f "$changelog" ]]; then
    local tmp="${changelog}.tmp"
    if head -n1 "$changelog" | grep -q '^# Changelog'; then
      { printf '%s\n\n%s\n\n' "$header" "$entry"; tail -n +2 "$changelog" | sed '1{/^$/d;}'; } > "$tmp"
    else
      { printf '%s\n\n%s\n\n' "$header" "$entry"; cat "$changelog"; } > "$tmp"
    fi
    mv "$tmp" "$changelog"
  else
    printf '%s\n\n%s\n' "$header" "$entry" > "$changelog"
  fi
}

if [[ $DRY_RUN -eq 0 ]]; then
  bump_files
  log "bumped VERSION, SKILL.md header, CHANGELOG.md"
else
  log "[dry-run] skipped file writes"
fi

# ---------- invoke clawhub ----------
if command -v clawhub >/dev/null 2>&1; then
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] would run: clawhub publish \"$PROJECT_DIR\" --version=$NEW_VERSION"
  else
    log "running: clawhub publish \"$PROJECT_DIR\" --version=$NEW_VERSION"
    # clawhub honours .clawhubignore -> scripts/ (including this file) excluded
    clawhub publish "$PROJECT_DIR" --version="$NEW_VERSION"
  fi
else
  warn "clawhub CLI not found in PATH; file bump done, skip remote publish"
  warn "install clawhub then run: clawhub publish \"$PROJECT_DIR\" --version=$NEW_VERSION"
fi

log "done ✅  $CUR_VERSION -> $NEW_VERSION"
