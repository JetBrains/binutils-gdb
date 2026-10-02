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

# Base on a GDB development branch instead of a release tag
./apply.sh upstream/gdb-18-branch 18-patches-applied

# Throwaway run — branches get a randomized "tmp-<token>/" prefix
./apply.sh --random-prefix upstream/gdb-18-branch 18-patches-applied

# Fixed prefix instead of a random one
./apply.sh --prefix try/gdb18 upstream/gdb-18-branch 18-patches-applied
```

`apply.sh` extracts the GDB version from the base ref, resolves the manifest from `manifests/`, and applies patches per `[platform]` section.

**Base refs:** either a release tag (`gdb-17.1-release`) or a development branch (`gdb-18-branch`, `upstream/gdb-18-branch`). The version comes from the ref name — `gdb-17.1-release` → `17.1`, `upstream/gdb-18-branch` → `18` — and a remote prefix is stripped before parsing. Created branches never track the base ref (`branch --no-track`), so a branch-based run can't push back to upstream.

**Branch prefix:** `--prefix <p>` inserts `<p>/` between the platform component and the suffix of every generated branch name — `<platform>[-<arch>]/<p>/<suffix>`; `--random-prefix[=<base>]` inserts `<base>-<random token>/` the same way (base defaults to `tmp`). The platform must stay first: the downstream TeamCity config is handed an os-less branch and prepends the os-arch itself, so a prefix before the platform would be untriggerable — the os-less branch to hand it is `<prefix>/<suffix>`. The prefix also lands in the generated `push_*.sh` name, so prefixed runs don't clobber each other. Use it for test runs that must not collide with the real `<platform>/<suffix>` branches TeamCity consumes.

**Worktree location:** by default each platform's worktree is a random `mktemp` dir under system temp, removed once its branch is done. `--worktree-dir <dir>` makes it deterministic instead — `<dir>/<platform>[-<arch>]` — so a process external to this run (e.g. a later repair step) can re-derive the same path from `(dir, platform, arch)` alone and find the `.rej` files and `resume.sh` a failed run left behind. If that path already exists from a prior run, `apply.sh` refuses and leaves it untouched; pass `-f` to wipe and redo it.

## Versioned manifests

Manifests live in `manifests/` with `[platform]` sections listing patches in application order.

Resolution for GDB 17.1: `manifests/17.1.manifest` → `manifests/17.manifest`.

**Patch file locations:**
- `shared/` — patches that touch generic GDB code (may be referenced by any platform)
- `darwin/` — darwin-only patches
- `mingw/` — mingw-only patches

A patch in `shared/` is not automatically applied everywhere — only platforms that list it in their manifest section get it.

### Manifest syntax

```
[platform]                       # single/unspecified arch — one bare branch
patch/path.patch                 # applies to the platform's only branch
# comment lines and blank lines are ignored

[mingw archs=x86_64,aarch64]     # multi-arch platform — one branch per arch
shared/some-common.patch         # untagged: goes to EVERY arch branch
mingw/aarch64.patch @arch=aarch64  # tagged: only the aarch64 branch
```

- **Section header** — `[platform]` optionally followed by `archs=<a,b,...>` declaring the platform's arch universe. No `archs=` means single/unspecified arch (the historical behavior).
- **Patch line** — a repo-root-relative path, optionally followed by a whitespace-separated `@arch=<tok>` selector. Untagged lines apply to all archs the platform declares; a tagged line applies only to that arch. Arch tokens are the GDB host-triple stems: `x86_64`, `aarch64`.
- An `@arch=<tok>` whose `<tok>` is not in the section's `archs=` list is a hard error (apply.sh fails fast).
- Comments (`#…`) and blank lines are ignored.

### Branch emission

- A platform with **no `archs=` (or a single arch)** emits one bare branch `<platform>/<suffix>` — exactly as before. `linux` and `darwin` stay bare, unchanged.
- A platform declaring **multiple archs** emits one branch per arch, `<platform>-<arch>/<suffix>` (e.g. `mingw-x86_64/17.1-patches-applied`, `mingw-aarch64/17.1-patches-applied`). Each arch branch gets the untagged patches plus the patches tagged for that arch, in manifest order.
- `<suffix>` must still start with `<major>.<minor>` (downstream TeamCity deploy parses it).

## Adding a new patch

1. Create the `.patch` file (`git diff` against vanilla GDB, bare diff format)
2. Place it in `shared/`, `darwin/`, or `mingw/`
3. Add it to the relevant `[platform]` sections in the version's manifest
4. Commit to this branch

## Adding a new GDB version

1. Copy the latest manifest → `manifests/<new-major>.manifest`
   (`apply.sh` does step 1 for you automatically when run non-interactively
   against a version with no manifest yet — it copies the latest manifest,
   marks the file as machine-generated/unreviewed, and prints a warning.
   Interactive runs still error out and require this step by hand.)
2. Test each patch against the new GDB source
3. Create version-specific patch variants where needed (e.g. `-17.patch`)
4. If a minor version diverges later, add `manifests/<major>.<minor>.manifest`

## Removing a patch

1. Remove from manifest `[platform]` sections
2. Delete the `.patch` file if no manifest references it
3. Commit to this branch

## Relationship to clion-bundle-buildenv

The PKGBUILDs in `clion-bundle-buildenv` check for `.jetbrains-patches-applied` in the GDB source tree. If present, patch application in `prepare()` is skipped. This allows building from either:
- A vanilla GDB tarball (patches applied at build time by PKGBUILD)
- A pre-patched branch (patches already committed, marker file present)

This branch is the only source of truth for patches. `clion-bundle-buildenv/patches/gdb/` holds a flat, unversioned set (listed in its `PKGBUILD.inc`) kept only for the vanilla-tarball fallback used by older GDB versions; it has no manifests and new patches are not added there.
