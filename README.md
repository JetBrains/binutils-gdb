# JetBrains GDB Patches

This branch contains patches applied to GDB for JetBrains IDE builds (CLion, etc.).

## Structure

```
(utils/patches branch root)
├── bootstrap.sh       # Set up upstream remote and fetch release tags
├── apply.sh           # Applies patches to all platforms at once
├── manifests/         # Versioned manifests
│   ├── 16.manifest    # Patch list for GDB 16.x
│   └── 17.manifest    # Patch list for GDB 17.x
├── shared/            # Patch files used by multiple platforms
├── darwin/            # Darwin-only patch files
└── mingw/             # MinGW-only patch files
```

## Versioned manifests

Each GDB major version has a manifest file (`manifests/<major>.manifest`) with `[platform]` sections listing all patches for that platform in application order. A minor version can override with `manifests/<major>.<minor>.manifest`.

Resolution order for GDB 17.1:
1. `manifests/17.1.manifest` — exact minor version
2. `manifests/17.manifest` — major version fallback

### Adding a new GDB version

When GDB 18 arrives and no `18.manifest` exists:
1. Copy `17.manifest` → `18.manifest`
2. Test each patch, create version-specific variants where needed
3. If 18.2 later diverges, add `18.2.manifest` (overrides `18.manifest` for that minor)

## Patch file locations

- `shared/` — patches that touch generic GDB code (may be listed by any platform)
- `darwin/` — darwin-only patches
- `mingw/` — mingw-only patches

A patch in `shared/` is not automatically applied everywhere — only platforms that list it in their manifest section get it.

## Usage

### First-time setup

After cloning, check out this branch and run `bootstrap.sh` to add the sourceware upstream remote and fetch GDB release tags (used as base refs by `apply.sh`):

```bash
git checkout utils/patches
./bootstrap.sh
```

### Apply patches to all platforms

```bash
./apply.sh gdb-17.1-release 17.1-patches-applied
```

Or interactively (pick from available tags):

```bash
./apply.sh
```

On success, `apply.sh` generates `push_<suffix>.sh` — run it to push all platform branches to origin.

### When patches fail

If a patch doesn't apply cleanly (context drift between GDB versions), `apply.sh` leaves the worktree with `.rej` files and generates helper scripts:

- **`resume.sh`** (in each worktree) — run after manually fixing rejects to commit and continue
- **`finalize.sh`** — verifies all branches are resolved, then generates `push_<suffix>.sh`
- **`claudefix.sh`** — launches Claude Code interactively to fix all rejects automatically

Typical recovery flow:

```bash
# Option A: fix manually
cd /tmp/gdb-patches-linux-XXXXXX
# fix rejects, delete .rej files
./resume.sh
# repeat for other platforms, then:
./finalize.sh

# Option B: let Claude fix it
./claudefix.sh
```

Once everything is resolved, push:

```bash
./push_<suffix>.sh
```

### Marker file

After all patches are applied to a platform branch (e.g. `linux/17.1-patches-applied`), a `.jetbrains-patches-applied` marker is committed there with the platform name, date, and list of applied patches.

The PKGBUILD `prepare()` functions check for this file to skip patch application when building from a pre-patched branch.
