# Patches Branch — AI Assistant Instructions

This is the `utils/patches` branch of `binutils-gdb`. It contains JetBrains-specific patches for GDB, organized by platform.

## Applying patches to platform branches

```bash
# Apply patches for a GDB release (resolves manifest automatically)
./apply.sh gdb-17.1-release 17.1-patches-applied

# Recreate existing branches
./apply.sh -f gdb-17.1-release 17.1-patches-applied

# Apply and push
./apply.sh -f gdb-17.1-release 17.1-patches-applied --push
```

`apply.sh` extracts the GDB version from the tag, resolves the manifest from `manifests/`, and applies patches per `[platform]` section.

## Versioned manifests

Manifests live in `manifests/` with `[platform]` sections listing patches in application order.

Resolution for GDB 17.1: `manifests/17.1.manifest` → `manifests/17.manifest`.

**Patch file locations:**
- `shared/` — patches that touch generic GDB code (may be referenced by any platform)
- `darwin/` — darwin-only patches
- `mingw/` — mingw-only patches

A patch in `shared/` is not automatically applied everywhere — only platforms that list it in their manifest section get it.

## Adding a new patch

1. Create the `.patch` file (`git diff` against vanilla GDB, bare diff format)
2. Place it in `shared/`, `darwin/`, or `mingw/`
3. Add it to the relevant `[platform]` sections in the version's manifest
4. Commit to this branch
5. Mirror the patch file to `clion-bundle-buildenv/patches/gdb/` (or platform dir) and update its manifest

## Adding a new GDB version

1. Copy the latest manifest → `manifests/<new-major>.manifest`
2. Test each patch against the new GDB source
3. Create version-specific patch variants where needed (e.g. `-17.patch`)
4. If a minor version diverges later, add `manifests/<major>.<minor>.manifest`

## Removing a patch

1. Remove from manifest `[platform]` sections
2. Delete the `.patch` file if no manifest references it
3. Commit to this branch
4. Remove from `clion-bundle-buildenv` counterparts

## Relationship to clion-bundle-buildenv

The PKGBUILDs in `clion-bundle-buildenv` check for `.jetbrains-patches-applied` in the GDB source tree. If present, patch application in `prepare()` is skipped. This allows building from either:
- A vanilla GDB tarball (patches applied at build time by PKGBUILD)
- A pre-patched branch (patches already committed, marker file present)

`clion-bundle-buildenv` has its own copy of manifests (`manifests/`) and patch files. Keep them in sync.
