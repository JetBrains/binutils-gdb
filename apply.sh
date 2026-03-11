#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

usage() {
    cat <<EOF
Usage: $(basename "$0") <base-ref> <branch-suffix> [--push]

Apply JetBrains GDB patches to all platform branches.

Reads <platform>.patches manifests to determine which patches each
platform gets. Creates one branch per manifest:
  <platform>/<branch-suffix>

Options:
  -f        Delete and recreate branches that already exist
  --push    Push all branches to origin after applying patches

Examples:
  ./apply.sh gdb-16.3-release 16.3-patched
  ./apply.sh -f 140ba01 16.3-patches-applied --push
EOF
    exit 1
}

# Parse arguments
FORCE=false
PUSH=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        -f)       FORCE=true ;;
        --push)   PUSH=true ;;
        -*)       echo "Unknown option: $arg" >&2; usage ;;
        *)        POSITIONAL+=("$arg") ;;
    esac
done
[[ ${#POSITIONAL[@]} -lt 2 ]] && usage
BASE_REF="${POSITIONAL[0]}"
BRANCH_SUFFIX="${POSITIONAL[1]}"

# Verify base ref exists
if ! git -C "$REPO_ROOT" rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    echo "Error: base ref '$BASE_REF' does not exist." >&2
    exit 1
fi

# Discover platforms from *.patches manifests
PLATFORMS=()
for manifest in "$SCRIPT_DIR"/*.patches; do
    [[ -f "$manifest" ]] || continue
    PLATFORMS+=("$(basename "$manifest" .patches)")
done

if [[ ${#PLATFORMS[@]} -eq 0 ]]; then
    echo "Error: no *.patches manifests found in $SCRIPT_DIR" >&2
    exit 1
fi

# Read patch list from a manifest
resolve_patches() {
    local platform="$1"
    local -n _patches=$2
    local manifest="$SCRIPT_DIR/${platform}.patches"
    _patches=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        local path="$SCRIPT_DIR/$line"
        if [[ ! -f "$path" ]]; then
            echo "Error: patch '$line' listed in ${platform}.patches not found" >&2
            return 1
        fi
        _patches+=("$path")
    done < "$manifest"
}

# Apply patches to one platform
apply_platform() {
    local platform="$1"
    local branch_name="${platform}/${BRANCH_SUFFIX}"

    local patches
    resolve_patches "$platform" patches

    echo "=== $platform === ($branch_name, ${#patches[@]} patches)"

    # Create branch from base ref
    if git -C "$REPO_ROOT" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
        if $FORCE; then
            # Remove any worktree attached to this branch first
            local old_wt
            old_wt=$(git -C "$REPO_ROOT" worktree list --porcelain \
                | grep -B2 "branch refs/heads/$branch_name" \
                | grep '^worktree ' | sed 's/^worktree //' || true)
            if [[ -n "$old_wt" ]]; then
                git -C "$REPO_ROOT" worktree remove --force "$old_wt" 2>/dev/null || true
            fi
            git -C "$REPO_ROOT" branch -D "$branch_name" >/dev/null
        else
            echo "Error: branch '$branch_name' already exists (use -f to recreate)." >&2
            return 1
        fi
    fi
    git -C "$REPO_ROOT" branch "$branch_name" "$BASE_REF"

    # Create temporary worktree
    local worktree_dir
    worktree_dir=$(mktemp -d "${TMPDIR:-/tmp}/gdb-patches-${platform}-XXXXXX")

    git -C "$REPO_ROOT" worktree add "$worktree_dir" "$branch_name" >/dev/null 2>&1

    # Apply patches one by one
    pushd "$worktree_dir" >/dev/null
    local i
    for ((i = 0; i < ${#patches[@]}; i++)); do
        local patch_file="${patches[$i]}"
        local patch_name
        patch_name="$(basename "$patch_file")"
        local patch_output
        if patch_output=$(patch -p1 < "$patch_file" 2>&1); then
            echo "  ✅ $patch_name"
        else
            echo "  ❌ $patch_name"
            echo "$patch_output" | sed 's/^/     /'
            # Collect remaining patches (after the failed one)
            local remaining=()
            for ((j = i + 1; j < ${#patches[@]}; j++)); do
                remaining+=("${patches[$j]}")
            done
            for ((j = i + 1; j < ${#patches[@]}; j++)); do
                echo "  ⬜ $(basename "${patches[$j]}")"
            done
            generate_resume "$worktree_dir" "$platform" "$patch_name" \
                "${patches[*]}" "${remaining[*]}"
            echo
            echo "  To resolve:"
            echo "    cd $worktree_dir"
            echo "    # fix rejects, delete .rej files, then run:"
            echo "    ./resume.sh"
            popd >/dev/null
            return 1
        fi
        git add -A
        git commit -q -m "Apply $patch_name"
    done

    commit_marker "$platform" "${patches[@]}"
    popd >/dev/null
    finish_platform "$worktree_dir" "$branch_name"
}

# Generate resume.sh in worktree for manual conflict resolution
generate_resume() {
    local worktree_dir="$1" platform="$2" failed_patch="$3"
    local all_patches_str="$4" remaining_str="$5"

    cat > "$worktree_dir/resume.sh" <<'RESUME_HEADER'
#!/usr/bin/env bash
set -euo pipefail

# Auto-generated by apply.sh — resumes after a failed patch.
# Fix the rejects, delete .rej files, then run this script.

RESUME_HEADER

    cat >> "$worktree_dir/resume.sh" <<RESUME_VARS
PLATFORM="$platform"
FAILED_PATCH="$failed_patch"
ALL_PATCHES=($all_patches_str)
REMAINING=($remaining_str)
RESUME_VARS

    cat >> "$worktree_dir/resume.sh" <<'RESUME_BODY'

# Step 1: Check rejects are resolved
rejects=$(find . -name '*.rej' 2>/dev/null || true)
if [[ -n "$rejects" ]]; then
    echo "Unresolved rejects — fix these first:"
    echo "$rejects"
    exit 1
fi

# Step 2: Commit the fixed patch
echo "Committing resolved patch: $FAILED_PATCH"
git add -A
git commit -m "Apply $FAILED_PATCH"

# Step 3: Apply remaining patches
for patch_file in "${REMAINING[@]}"; do
    patch_name="$(basename "$patch_file")"
    echo "Applying $patch_name..."
    if ! patch -p1 < "$patch_file"; then
        echo
        echo "FAILED to apply $patch_name"
        echo "Fix rejects, delete .rej files, then:"
        echo "  git add -A && git commit -m 'Apply $patch_name'"
        echo "  # apply remaining patches manually"
        exit 1
    fi
    git add -A
    git commit -m "Apply $patch_name"
done

# Step 4: Create marker
{
    echo "platform: $PLATFORM"
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "patches:"
    for p in "${ALL_PATCHES[@]}"; do
        echo "  - $(basename "$p")"
    done
} > .jetbrains-patches-applied
git add .jetbrains-patches-applied
git commit -m "Add .jetbrains-patches-applied marker"

# Step 5: Clean up
rm -f resume.sh
git add -A
git diff --cached --quiet || git commit -m "Remove resume.sh"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo
echo "All patches applied to $BRANCH."
echo "  git push origin $BRANCH"
echo "  cd .. && git worktree remove $(pwd)"
RESUME_BODY

    chmod +x "$worktree_dir/resume.sh"
}

# Create .jetbrains-patches-applied marker and commit it
commit_marker() {
    local platform="$1"; shift
    local all_patches=("$@")
    {
        echo "platform: $platform"
        echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "patches:"
        for p in "${all_patches[@]}"; do
            echo "  - $(basename "$p")"
        done
    } > .jetbrains-patches-applied
    git add .jetbrains-patches-applied
    git commit -q -m "Add .jetbrains-patches-applied marker"
}

# Clean up worktree and optionally push
finish_platform() {
    local worktree_dir="$1" branch_name="$2"

    local commit_count
    commit_count=$(git -C "$worktree_dir" rev-list --count "$BASE_REF"..HEAD)

    git -C "$REPO_ROOT" worktree remove "$worktree_dir" 2>/dev/null

    if $PUSH; then
        git -C "$REPO_ROOT" push origin "$branch_name"
    fi

    echo "🟢 $branch_name done ($commit_count commits)"
    echo
}

# Suggest pushing all branches
suggest_push() {
    local branches=("$@")
    echo
    echo "To push all branches:"
    for b in "${branches[@]}"; do
        echo "  git push origin $b"
    done
}

# Generate top-level resume.sh in the scripts branch
generate_top_resume() {
    local all_branches_str="$1" failed_str="$2"

    cat > "$SCRIPT_DIR/finalize.sh" <<'HEADER'
#!/usr/bin/env bash
set -euo pipefail
HEADER

    cat >> "$SCRIPT_DIR/finalize.sh" <<VARS
REPO_ROOT="$REPO_ROOT"
ALL_BRANCHES=($all_branches_str)
VARS

    cat >> "$SCRIPT_DIR/finalize.sh" <<'BODY'

# Find worktree path for a branch (empty if none)
find_worktree() {
    git -C "$REPO_ROOT" worktree list --porcelain \
        | grep -B2 "branch refs/heads/$1" \
        | grep '^worktree ' | sed 's/^worktree //' || true
}

ready=()
not_ready=()
for branch in "${ALL_BRANCHES[@]}"; do
    if git -C "$REPO_ROOT" show "$branch:.jetbrains-patches-applied" >/dev/null 2>&1; then
        echo "✅ $branch"
        ready+=("$branch")
    else
        wt=$(find_worktree "$branch")
        if [[ -n "$wt" ]]; then
            echo "❌ $branch — resolve in: $wt"
        else
            echo "❌ $branch — missing .jetbrains-patches-applied (no worktree found)"
        fi
        not_ready+=("$branch")
    fi
done

echo
if [[ ${#not_ready[@]} -gt 0 ]]; then
    echo "${#not_ready[@]} branch(es) still need patches resolved."
    exit 1
fi

echo "All branches ready."
echo
echo "To push:"
for b in "${ready[@]}"; do
    echo "  git push origin $b"
done

rm -f "$0"
BODY

    chmod +x "$SCRIPT_DIR/finalize.sh"
}

echo "Base: $BASE_REF ($(git -C "$REPO_ROOT" rev-parse --short "$BASE_REF"))"
echo "Platforms: ${PLATFORMS[*]}"
echo

failed=0
failed_platforms=()
all_branches=()
for platform in "${PLATFORMS[@]}"; do
    all_branches+=("${platform}/${BRANCH_SUFFIX}")
    if ! apply_platform "$platform"; then
        echo "🔴 $platform FAILED"
        echo
        failed_platforms+=("$platform")
        ((failed++)) || true
    fi
done

if [[ $failed -gt 0 ]]; then
    generate_top_resume "${all_branches[*]}" "${failed_platforms[*]}"
    echo "$failed platform(s) failed."
    echo "After resolving all platforms, come back here and run:"
    echo "  $SCRIPT_DIR/finalize.sh"
    exit 1
fi

echo "All platforms done."
suggest_push "${all_branches[@]}"
