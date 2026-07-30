#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

usage() {
    cat <<EOF
Usage: $(basename "$0") <base-ref> <branch-suffix> [--push]

Apply JetBrains GDB patches to all platform branches.

Resolves a versioned manifest from manifests/ to determine which
patches each platform gets. Creates one branch per platform:
  <platform>/<branch-suffix>

A platform whose manifest header declares multiple archs
(e.g. [mingw archs=x86_64,aarch64]) instead emits one branch per arch:
  <platform>-<arch>/<branch-suffix>

Options:
  -f        Delete and recreate branches that already exist
  --push    Push all branches to origin after applying patches

Examples:
  ./apply.sh gdb-16.3-release 16.3-patches-applied
  ./apply.sh -f gdb-17.1-release 17.1-patches-applied --push
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
        -h|--help) usage ;;
        -*)       echo "Unknown option: $arg" >&2; usage ;;
        *)        POSITIONAL+=("$arg") ;;
    esac
done
# Interactive mode when no positional args given
if [[ ${#POSITIONAL[@]} -eq 0 ]]; then
    mapfile -t tags < <(git -C "$REPO_ROOT" tag -l 'gdb-*-release' | sort -V)
    if [[ ${#tags[@]} -eq 0 ]]; then
        echo "No gdb-*-release tags found. Run bootstrap.sh first." >&2
        exit 1
    fi

    echo "Available GDB release tags:"
    echo
    for i in "${!tags[@]}"; do
        printf "  %2d) %s\n" $((i + 1)) "${tags[$i]}"
    done
    echo
    read -rp "Select tag [1-${#tags[@]}]: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#tags[@]} )); then
        echo "Invalid selection." >&2
        exit 1
    fi

    BASE_REF="${tags[$((choice - 1))]}"
    # gdb-17.1-release -> 17.1-patched
    version="${BASE_REF#gdb-}"
    version="${version%-release}"
    BRANCH_SUFFIX="${version}-patches-applied"

    echo
    flags=""
    $FORCE && flags+=" -f"
    $PUSH && flags+=" --push"
    echo "Will run: apply.sh${flags} $BASE_REF $BRANCH_SUFFIX"
    read -rp "Proceed? [Y/n] " confirm
    [[ "${confirm:-y}" =~ ^[Yy]?$ ]] || exit 0

elif [[ ${#POSITIONAL[@]} -lt 2 ]]; then
    usage
else
    BASE_REF="${POSITIONAL[0]}"
    BRANCH_SUFFIX="${POSITIONAL[1]}"
fi

# Verify base ref exists
if ! git -C "$REPO_ROOT" rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    echo "Error: base ref '$BASE_REF' does not exist." >&2
    exit 1
fi

# Extract GDB version from base ref (e.g. gdb-17.1-release -> 17.1)
if [[ "$BASE_REF" =~ gdb-([0-9]+(\.[0-9]+)*)-release ]]; then
    GDB_VERSION="${BASH_REMATCH[1]}"
else
    echo "Error: cannot extract GDB version from '$BASE_REF' (expected gdb-X.Y-release)" >&2
    exit 1
fi

# Resolve versioned manifest file.
# Lookup order: manifests/<major>.<minor>.manifest, manifests/<major>.manifest
MANIFEST_FILE=""
candidate="$SCRIPT_DIR/manifests/${GDB_VERSION}.manifest"
if [[ -f "$candidate" ]]; then
    MANIFEST_FILE="$candidate"
else
    major="${GDB_VERSION%%.*}"
    candidate="$SCRIPT_DIR/manifests/${major}.manifest"
    if [[ -f "$candidate" ]]; then
        MANIFEST_FILE="$candidate"
    fi
fi

if [[ -z "$MANIFEST_FILE" ]]; then
    echo "Error: no manifest found for GDB $GDB_VERSION" >&2
    echo "  looked for: manifests/${GDB_VERSION}.manifest, manifests/${major}.manifest" >&2
    exit 1
fi

# Discover platforms from [platform] section headers.
# A header may carry an arch universe: [mingw archs=x86_64,aarch64].
# No archs= = single/unspecified arch (current behavior).
PLATFORMS=()
declare -A PLATFORM_ARCHS
while IFS= read -r line; do
    if [[ "$line" =~ ^\[([a-z]+)([[:space:]]+archs=([A-Za-z0-9_,]+))?\] ]]; then
        PLATFORMS+=("${BASH_REMATCH[1]}")
        PLATFORM_ARCHS["${BASH_REMATCH[1]}"]="${BASH_REMATCH[3]}"
    fi
done < "$MANIFEST_FILE"
echo "Manifest: $MANIFEST_FILE"

if [[ ${#PLATFORMS[@]} -eq 0 ]]; then
    echo "Error: no [platform] sections found in $MANIFEST_FILE" >&2
    exit 1
fi

# Read patch list for a platform from the manifest's [platform] section.
# Optional 3rd arg filter_arch: when non-empty, emit only untagged patches
# plus those tagged with that arch (per-arch branch). Empty = include all
# (bare branch for a no-archs / single-arch platform).
# An inline "@arch=<tok>" whose tok is not in the section's archs= list is a
# hard error (fail fast).
resolve_patches() {
    local platform="$1"
    local -n _patches=$2
    local filter_arch="${3:-}"
    _patches=()

    local declared_archs="${PLATFORM_ARCHS[$platform]:-}"

    local in_section=false
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^\[([a-z]+) ]]; then
            [[ "${BASH_REMATCH[1]}" == "$platform" ]] && in_section=true || in_section=false
            continue
        fi
        if $in_section; then
            # Split "path [@arch=tok]": first token is the path, optional selector follows.
            local path_rel rest sel_arch=""
            read -r path_rel rest <<< "$line"
            if [[ -n "$rest" ]]; then
                if [[ "$rest" =~ ^@arch=([A-Za-z0-9_]+)[[:space:]]*$ ]]; then
                    sel_arch="${BASH_REMATCH[1]}"
                else
                    echo "Error: malformed selector '$rest' on patch line '$line' in [$platform]" >&2
                    return 1
                fi
            fi
            if [[ -n "$sel_arch" ]]; then
                # Selector must name an arch the section declared.
                if [[ ",$declared_archs," != *",$sel_arch,"* ]]; then
                    echo "Error: @arch=$sel_arch on '$path_rel' is not in [$platform] archs='$declared_archs'" >&2
                    return 1
                fi
                # Per-arch branch: drop patches tagged for a different arch.
                if [[ -n "$filter_arch" && "$sel_arch" != "$filter_arch" ]]; then
                    continue
                fi
            fi
            local path="$SCRIPT_DIR/$path_rel"
            if [[ ! -f "$path" ]]; then
                echo "Error: patch '$path_rel' from manifest not found" >&2
                return 1
            fi
            _patches+=("$path")
        fi
    done < "$MANIFEST_FILE"
}

# Apply patches to one branch of a platform.
# filter_arch empty  -> bare branch, all patches (no-archs / single-arch platform)
# filter_arch set    -> per-arch branch, untagged + that-arch patches only
apply_branch() {
    local platform="$1"
    local filter_arch="$2"
    local branch_name="$3"

    local patches
    # Bail before touching git if the manifest is bad (missing patch file,
    # unknown @arch token). apply_branch runs under `if !`, which suppresses
    # set -e, so resolve_patches's non-zero return must be checked explicitly.
    if ! resolve_patches "$platform" patches "$filter_arch"; then
        return 1
    fi

    echo "=== $platform${filter_arch:+ ($filter_arch)} === ($branch_name, ${#patches[@]} patches)"

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
    worktree_dir=$(mktemp -d "${TMPDIR:-/tmp}/gdb-patches-${platform}${filter_arch:+-$filter_arch}-XXXXXX")

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

    commit_marker "$platform" "$filter_arch" "${patches[@]}"
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
    local platform="$1" arch="$2"; shift 2
    local all_patches=("$@")
    {
        echo "platform: $platform"
        [[ -n "$arch" ]] && echo "arch: $arch"
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

# Generate top-level resume.sh in the scripts branch
generate_top_resume() {
    local all_branches_str="$1" failed_str="$2"

    cat > "$SCRIPT_DIR/finalize.sh" <<'HEADER'
#!/usr/bin/env bash
set -euo pipefail
HEADER

    cat >> "$SCRIPT_DIR/finalize.sh" <<VARS
REPO_ROOT="$REPO_ROOT"
PUSH_SCRIPT="$SCRIPT_DIR/push_${BRANCH_SUFFIX}.sh"
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

# Generate push script
cat > "$PUSH_SCRIPT" <<PUSH_HEADER
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$REPO_ROOT"
ALL_BRANCHES=(${ALL_BRANCHES[*]})
PUSH_HEADER

cat >> "$PUSH_SCRIPT" <<'PUSH_BODY'

for branch in "${ALL_BRANCHES[@]}"; do
    echo "Pushing $branch..."
    git -C "$REPO_ROOT" push origin "$branch"
done

echo
echo "All branches pushed."
rm -f "$0"
PUSH_BODY

chmod +x "$PUSH_SCRIPT"

echo
echo "To push all branches:"
echo "  $PUSH_SCRIPT"

rm -f "$0"
BODY

    chmod +x "$SCRIPT_DIR/finalize.sh"
}

# Generate claudefix.sh that launches Claude Code to resolve rejects
generate_claudefix() {
    local all_branches_str="$1"

    cat > "$SCRIPT_DIR/claudefix.sh" <<'HEADER'
#!/usr/bin/env bash
set -euo pipefail
HEADER

    cat >> "$SCRIPT_DIR/claudefix.sh" <<VARS
REPO_ROOT="$REPO_ROOT"
FINALIZE_SCRIPT="$SCRIPT_DIR/finalize.sh"
CLAUDEFIX_SCRIPT="$SCRIPT_DIR/claudefix.sh"
PUSH_SCRIPT="$SCRIPT_DIR/push_${BRANCH_SUFFIX}.sh"
ALL_BRANCHES=($all_branches_str)
VARS

    cat >> "$SCRIPT_DIR/claudefix.sh" <<'BODY'

find_worktree() {
    git -C "$REPO_ROOT" worktree list --porcelain \
        | grep -B2 "branch refs/heads/$1" \
        | grep '^worktree ' | sed 's/^worktree //' || true
}

tasks=()
for branch in "${ALL_BRANCHES[@]}"; do
    if git -C "$REPO_ROOT" show "$branch:.jetbrains-patches-applied" >/dev/null 2>&1; then
        continue
    fi
    wt=$(find_worktree "$branch")
    if [[ -z "$wt" ]]; then
        echo "Warning: $branch unresolved but no worktree found — skipping" >&2
        continue
    fi
    tasks+=("$wt:$branch")
done

if [[ ${#tasks[@]} -eq 0 ]]; then
    echo "Nothing to fix — all branches have .jetbrains-patches-applied marker."
    exit 0
fi

prompt="You are fixing failed GDB patch applications across platform branches.
Each worktree below has .rej files from patches that didn't apply cleanly.
"

for entry in "${tasks[@]}"; do
    wt="${entry%%:*}"
    branch="${entry#*:}"

    rejects=$(find "$wt" -name '*.rej' 2>/dev/null || true)
    if [[ -z "$rejects" ]]; then
        prompt+="
## Worktree: $wt (branch: $branch)

No .rej files found — check if this worktree needs manual inspection.
"
        continue
    fi

    reject_list=""
    while IFS= read -r rej; do
        reject_list+="  $rej
"
    done <<< "$rejects"

    prompt+="
## Worktree: $wt (branch: $branch)

Reject files:
$reject_list
Instructions:
1. Read each .rej file to understand the intended change
2. Read the corresponding source file (same path without .rej)
3. Apply the intended change to the source file using the Edit tool
4. Delete the .rej file
5. After all rejects in this worktree are resolved, run: cd $wt && ./resume.sh
   resume.sh will commit the fix and apply remaining patches
"
done

prompt+="
After ALL worktrees are resolved, run:
  $FINALIZE_SCRIPT
This should show all branches as ✅ and generate $PUSH_SCRIPT.

Then suggest the user run these cleanup/next steps:
  rm $CLAUDEFIX_SCRIPT
  $PUSH_SCRIPT

IMPORTANT: Do NOT run \`git push\` or push any branches yourself. Only fix rejects and verify locally."

exec claude "$prompt"
BODY

    chmod +x "$SCRIPT_DIR/claudefix.sh"
}

echo "Base: $BASE_REF ($(git -C "$REPO_ROOT" rev-parse --short "$BASE_REF"))"
echo "Platforms: ${PLATFORMS[*]}"
echo

failed=0
failed_platforms=()
all_branches=()
for platform in "${PLATFORMS[@]}"; do
    # Split the declared arch universe. 0 or 1 arch -> one bare branch
    # (exact current behavior); 2+ archs -> one branch per arch.
    IFS=',' read -ra archs <<< "${PLATFORM_ARCHS[$platform]:-}"
    if [[ ${#archs[@]} -le 1 ]]; then
        branch="${platform}/${BRANCH_SUFFIX}"
        all_branches+=("$branch")
        if ! apply_branch "$platform" "" "$branch"; then
            echo "🔴 $platform FAILED"
            echo
            failed_platforms+=("$platform")
            ((failed++)) || true
        fi
    else
        for arch in "${archs[@]}"; do
            branch="${platform}-${arch}/${BRANCH_SUFFIX}"
            all_branches+=("$branch")
            if ! apply_branch "$platform" "$arch" "$branch"; then
                echo "🔴 ${platform}-${arch} FAILED"
                echo
                failed_platforms+=("${platform}-${arch}")
                ((failed++)) || true
            fi
        done
    fi
done

if [[ $failed -gt 0 ]]; then
    generate_top_resume "${all_branches[*]}" "${failed_platforms[*]}"
    generate_claudefix "${all_branches[*]}"
    echo "$failed platform(s) failed."
    echo "After resolving all platforms, come back here and run:"
    echo "  $SCRIPT_DIR/claudefix.sh    # launch Claude to fix rejects"
    echo "  $SCRIPT_DIR/finalize.sh     # verify all branches & generate push script"
    exit 1
fi

echo "All platforms done."
if ! $PUSH; then
    # Generate a convenience push script (same as finalize.sh would)
    push_script="$SCRIPT_DIR/push_${BRANCH_SUFFIX}.sh"
    cat > "$push_script" <<PUSH_EOF
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$REPO_ROOT"
ALL_BRANCHES=(${all_branches[*]})

for branch in "\${ALL_BRANCHES[@]}"; do
    echo "Pushing \$branch..."
    git -C "\$REPO_ROOT" push origin "\$branch"
done

echo
echo "All branches pushed."
rm -f "\$0"
PUSH_EOF
    chmod +x "$push_script"
    echo "To push all branches:"
    echo "  $push_script"
fi
