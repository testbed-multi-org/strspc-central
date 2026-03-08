#!/usr/bin/env bash
# SteerSpec Sync MVP — bash implementation
# Syncs templates from central repo to target repos via PRs.
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
CONFIG_FILE="${INPUT_CONFIG_PATH:-steerspec-sync.yml}"
DRY_RUN="${INPUT_DRY_RUN:-false}"
FORCE="${INPUT_FORCE:-false}"
TARGET_FILTER="${INPUT_TARGET_FILTER:-}"

# Counters
PRS_CREATED=0
PRS_UPDATED=0
REPOS_SKIPPED=0
ERRORS=0

# ── Helpers ─────────────────────────────────────────────────────────────────
log()  { echo "[steerspec-sync] $*"; }
warn() { echo "[steerspec-sync] WARNING: $*" >&2; }
err()  { echo "[steerspec-sync] ERROR: $*" >&2; }

die() { err "$*"; exit 1; }

# ── Parse config ────────────────────────────────────────────────────────────
[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"

log "Reading config from $CONFIG_FILE"

PR_LABEL=$(yq '.sync.pr-label // "steerspec-sync"' "$CONFIG_FILE")
INCLUDE_PATTERNS=$(yq '.targets.include[]' "$CONFIG_FILE")
EXCLUDE_PATTERNS=$(yq '.targets.exclude // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true)

# Read template definitions
TEMPLATE_COUNT=$(yq '.templates | length' "$CONFIG_FILE")
log "Found $TEMPLATE_COUNT template(s), PR label: $PR_LABEL"

# ── Resolve target repos ───────────────────────────────────────────────────
resolve_targets() {
  local targets=()

  for pattern in $INCLUDE_PATTERNS; do
    local org repo_glob
    org=$(echo "$pattern" | cut -d/ -f1)
    repo_glob=$(echo "$pattern" | cut -d/ -f2)

    log "Resolving repos matching $org/$repo_glob"

    local repos
    repos=$(gh api --paginate "/orgs/$org/repos" --jq '.[].full_name' 2>/dev/null || true)

    for repo in $repos; do
      local repo_name
      repo_name=$(echo "$repo" | cut -d/ -f2)

      # Match against glob pattern
      # shellcheck disable=SC2254
      case "$repo_name" in
        $repo_glob)
          # Check exclude patterns
          local excluded=false
          for exc in $EXCLUDE_PATTERNS; do
            local exc_repo
            exc_repo=$(echo "$exc" | cut -d/ -f2)
            # shellcheck disable=SC2254
            case "$repo_name" in
              $exc_repo) excluded=true; break ;;
            esac
          done

          if [[ "$excluded" == "false" ]]; then
            if [[ -n "$TARGET_FILTER" ]]; then
              # shellcheck disable=SC2254
              case "$repo_name" in
                $TARGET_FILTER) targets+=("$repo") ;;
              esac
            else
              targets+=("$repo")
            fi
          fi
          ;;
      esac
    done
  done

  # Exclude the central repo itself
  local central_repo="${GITHUB_REPOSITORY:-}"
  if [[ -z "$central_repo" ]]; then
    # Try to detect from git remote
    central_repo=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "")
  fi

  local filtered=()
  for t in "${targets[@]}"; do
    if [[ "$t" != "$central_repo" ]]; then
      filtered+=("$t")
    fi
  done

  echo "${filtered[@]}"
}

# ── Render template ────────────────────────────────────────────────────────
render_template() {
  local template_idx=$1
  local target_repo=$2

  local source destination strategy
  source=$(yq ".templates[$template_idx].source" "$CONFIG_FILE")
  destination=$(yq ".templates[$template_idx].destination" "$CONFIG_FILE")
  strategy=$(yq ".templates[$template_idx].strategy" "$CONFIG_FILE")

  [[ -f "$source" ]] || { err "Template source not found: $source"; return 1; }

  local template_id
  template_id=$(yq ".templates[$template_idx].id" "$CONFIG_FILE")

  local template_version
  template_version=$(python3 -c "
import json, sys
with open('.steerspec/versions.json') as f:
    d = json.load(f)
print(d.get('templates', {}).get('$template_id', {}).get('version', 'unknown'))
" 2>/dev/null || echo "unknown")

  local sync_timestamp
  sync_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  case "$strategy" in
    mustache|full-replace)
      # Simple variable substitution (MVP: sed-based, not full mustache)
      local rendered
      rendered=$(cat "$source")

      # Substitute global variables from config
      local var_count
      var_count=$(yq '.variables | keys | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
      for ((i=0; i<var_count; i++)); do
        local key val
        key=$(yq ".variables | keys | .[$i]" "$CONFIG_FILE")
        val=$(yq ".variables.$key" "$CONFIG_FILE")
        rendered=$(echo "$rendered" | sed "s|{{${key}}}|${val}|g")
      done

      # Substitute built-in variables
      rendered=$(echo "$rendered" | sed "s|{{template_version}}|${template_version}|g")
      rendered=$(echo "$rendered" | sed "s|{{sync_timestamp}}|${sync_timestamp}|g")
      rendered=$(echo "$rendered" | sed "s|{{repo_name}}|${target_repo}|g")

      echo "$rendered"
      ;;
    marker)
      warn "Marker strategy not fully implemented in MVP, using full-replace"
      render_template "$template_idx" "$target_repo"
      ;;
    *)
      err "Unknown strategy: $strategy"
      return 1
      ;;
  esac
}

# ── Remote file helpers ────────────────────────────────────────────────────
get_remote_file_content() {
  local repo=$1
  local path=$2
  local ref=${3:-}
  local ref_param=""
  [[ -n "$ref" ]] && ref_param="?ref=$ref"
  gh api "/repos/$repo/contents/${path}${ref_param}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || echo ""
}

get_remote_file_sha() {
  local repo=$1
  local path=$2
  local ref=${3:-}
  local ref_param=""
  [[ -n "$ref" ]] && ref_param="?ref=$ref"
  gh api "/repos/$repo/contents/${path}${ref_param}" --jq '.sha' 2>/dev/null || echo ""
}

# ── Sync one repo ──────────────────────────────────────────────────────────
sync_repo() {
  local target_repo=$1
  log "────────────────────────────────────────"
  log "Syncing: $target_repo"

  local repo_had_changes=false

  for ((t=0; t<TEMPLATE_COUNT; t++)); do
    local template_id destination
    template_id=$(yq ".templates[$t].id" "$CONFIG_FILE")
    destination=$(yq ".templates[$t].destination" "$CONFIG_FILE")

    local template_version
    template_version=$(python3 -c "
import json
with open('.steerspec/versions.json') as f:
    d = json.load(f)
print(d.get('templates', {}).get('$template_id', {}).get('version', '1.0.0'))
" 2>/dev/null || echo "1.0.0")

    # Branch naming per SYNCPR-002: steerspec-sync/<template-id>/<version>
    local branch_name="steerspec-sync/${template_id}/v${template_version}"

    log "  Template: $template_id -> $destination (branch: $branch_name)"

    # Render template
    local rendered
    rendered=$(render_template "$t" "$target_repo") || { ((ERRORS++)) || true; continue; }

    # Get current content from default branch
    local current_content
    current_content=$(get_remote_file_content "$target_repo" "$destination")

    # Compare rendered vs current (SHA-256 for MVP, not Blake3)
    local rendered_hash current_hash
    rendered_hash=$(printf '%s' "$rendered" | shasum -a 256 | cut -d' ' -f1)
    current_hash=$(printf '%s' "$current_content" | shasum -a 256 | cut -d' ' -f1)

    if [[ "$rendered_hash" == "$current_hash" ]] && [[ "$FORCE" != "true" ]]; then
      log "  Already up to date, skipping"
      continue
    fi

    repo_had_changes=true

    # Check for existing open PR (SYNCPR-005: update existing, don't duplicate)
    local existing_pr
    existing_pr=$(gh pr list --repo "$target_repo" --label "$PR_LABEL" \
      --head "$branch_name" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")

    if [[ "$DRY_RUN" == "true" ]]; then
      if [[ -n "$existing_pr" ]]; then
        log "  [DRY RUN] Would update PR #$existing_pr"
      else
        log "  [DRY RUN] Would create new PR"
      fi
      continue
    fi

    # Get default branch
    local default_branch
    default_branch=$(gh api "/repos/$target_repo" --jq '.default_branch' 2>/dev/null || echo "main")

    # Get base SHA for branch creation
    local base_sha
    base_sha=$(gh api "/repos/$target_repo/git/ref/heads/$default_branch" --jq '.object.sha' 2>/dev/null)

    # Check if sync branch exists
    local branch_exists
    branch_exists=$(gh api "/repos/$target_repo/git/ref/heads/$branch_name" --jq '.object.sha' 2>/dev/null || echo "")

    if [[ -z "$branch_exists" ]]; then
      gh api --method POST "/repos/$target_repo/git/refs" \
        -f ref="refs/heads/$branch_name" \
        -f sha="$base_sha" >/dev/null 2>&1
      log "  Created branch: $branch_name"
    else
      # Update branch to latest default branch to avoid conflicts
      gh api --method PATCH "/repos/$target_repo/git/refs/heads/$branch_name" \
        -f sha="$base_sha" -F force=true >/dev/null 2>&1
      log "  Reset branch to latest $default_branch"
    fi

    # Check if file exists on the branch (need SHA for update)
    local file_sha
    file_sha=$(get_remote_file_sha "$target_repo" "$destination" "$branch_name")

    # Push rendered content to branch
    local encoded_content
    encoded_content=$(printf '%s' "$rendered" | base64)

    if [[ -n "$file_sha" ]]; then
      gh api --method PUT "/repos/$target_repo/contents/$destination" \
        -f message="chore(steerspec): sync $template_id v$template_version" \
        -f content="$encoded_content" \
        -f branch="$branch_name" \
        -f sha="$file_sha" >/dev/null 2>&1
    else
      gh api --method PUT "/repos/$target_repo/contents/$destination" \
        -f message="chore(steerspec): sync $template_id v$template_version" \
        -f content="$encoded_content" \
        -f branch="$branch_name" >/dev/null 2>&1
    fi
    log "  Pushed rendered template to branch"

    # Create or update PR
    if [[ -n "$existing_pr" ]]; then
      log "  Updated existing PR #$existing_pr (branch was force-updated)"
      ((PRS_UPDATED++)) || true
    else
      # Create new PR
      local pr_title="chore(steerspec): sync $template_id v$template_version"
      local pr_body
      pr_body=$(cat <<PRBODY
## SteerSpec Sync

**Template:** \`$template_id\`
**Version:** \`$template_version\`
**Strategy:** \`$(yq ".templates[$t].strategy" "$CONFIG_FILE")\`

This PR was automatically created by [SteerSpec Sync](https://github.com/testbed-multi-org/strspc-central).

### Changes

Updates \`$destination\` to match the centrally managed template.

---
*Auto-generated by SteerSpec Sync*
PRBODY
)

      # Ensure label exists (SYNCPR-004)
      gh api --method POST "/repos/$target_repo/labels" \
        -f name="$PR_LABEL" -f color="6f42c1" \
        -f description="SteerSpec managed sync PR" >/dev/null 2>&1 || true

      local new_pr
      new_pr=$(gh pr create --repo "$target_repo" \
        --head "$branch_name" \
        --base "$default_branch" \
        --title "$pr_title" \
        --body "$pr_body" \
        --label "$PR_LABEL" 2>&1) || {
          err "Failed to create PR for $target_repo: $new_pr"
          ((ERRORS++)) || true
          continue
      }
      log "  Created PR: $new_pr"
      ((PRS_CREATED++)) || true
    fi
  done

  if [[ "$repo_had_changes" == "false" ]]; then
    ((REPOS_SKIPPED++)) || true
  fi
}

# ── Main ───────────────────────────────────────────────────────────────────
log "SteerSpec Sync MVP"
log "Config: $CONFIG_FILE | Dry run: $DRY_RUN | Force: $FORCE"

# Resolve targets
TARGETS=$(resolve_targets)
TARGET_COUNT=$(echo "$TARGETS" | wc -w | tr -d ' ')

if [[ "$TARGET_COUNT" -eq 0 ]]; then
  log "No target repos found"
  exit 0
fi

log "Resolved $TARGET_COUNT target repo(s): $TARGETS"

# Sync each target (SYNCACT-008: isolate errors per repo)
for target in $TARGETS; do
  sync_repo "$target" || {
    err "Failed to sync $target"
    ((ERRORS++)) || true
  }
done

# ── Summary (SYNCACT-016..020) ─────────────────────────────────────────────
log "========================================"
log "Sync complete!"
log "  PRs created:   $PRS_CREATED"
log "  PRs updated:   $PRS_UPDATED"
log "  Repos skipped: $REPOS_SKIPPED"
log "  Errors:        $ERRORS"
log "========================================"

# GitHub Actions outputs
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "prs-created=$PRS_CREATED"
    echo "prs-updated=$PRS_UPDATED"
    echo "repos-skipped=$REPOS_SKIPPED"
    echo "errors=$ERRORS"
  } >> "$GITHUB_OUTPUT"
fi

[[ "$ERRORS" -eq 0 ]] || exit 1
