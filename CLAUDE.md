# Patches Branch — AI Assistant Instructions

This is the `patches/gdb-jetbrains` branch of `binutils-gdb`. It contains JetBrains-specific patches for GDB, organized by platform.

## Applying patches to a new platform branch

When asked to apply patches to a new GDB branch (e.g., after a GDB version bump):

```bash
# 1. Check out this branch in a worktree
git worktree add /tmp/patches patches/gdb-jetbrains

# 2. Run apply.sh with the base ref and branch suffix
# This creates linux/<suffix>, darwin/<suffix>, mingw/<suffix>
/tmp/patches/apply.sh <base-ref> <branch-suffix>

# Example: apply to vanilla 16.3
/tmp/patches/apply.sh gdb-16.3-release 16.3-patched --push
```

## Adding a new patch

1. Create the `.patch` file (use `git diff` or `git format-patch` against vanilla GDB)
2. Place it in the appropriate directory (`shared/`, `darwin/`, `mingw/`)
3. Add it to each relevant `<platform>.patches` manifest
4. Commit to this branch
5. Update `clion-bundle-buildenv` PKGBUILDs if the patch also needs to be in the `source=()` array (for tarball-based builds)

## Removing a patch

1. Remove the line from `<platform>.patches` manifests
2. Delete the `.patch` file if no manifest references it
3. Commit to this branch
4. Remove from `clion-bundle-buildenv` PKGBUILD `source=()` arrays
5. Re-apply patches to platform branches (create fresh branches from vanilla base)

## Platform mapping

Each `<platform>.patches` file explicitly lists which patches that platform gets. No implicit rules — open the file to see.

## Relationship to clion-bundle-buildenv

The PKGBUILDs in `clion-bundle-buildenv` check for `.jetbrains-patches-applied` in the GDB source tree. If present, patch application in `prepare()` is skipped. This allows building from either:
- A vanilla GDB tarball (patches applied at build time by PKGBUILD)
- A pre-patched branch (patches already committed, marker file present)
