# JetBrains GDB Patches

This branch contains patches applied to GDB for JetBrains IDE builds (CLion, etc.).

## Structure

```
(patches/gdb-jetbrains branch root)
├── bootstrap.sh       # Set up upstream remote and fetch release tags
├── apply.sh           # Applies patches to all platforms at once
├── linux.patches      # Manifest: which patches linux gets
├── darwin.patches     # Manifest: which patches darwin gets
├── mingw.patches      # Manifest: which patches mingw gets
├── shared/            # Patch files used by multiple platforms
├── darwin/            # Darwin-only patch files
└── mingw/             # MinGW-only patch files
```

## Platform → Patch mapping

Each `<platform>.patches` manifest lists the exact patches applied to that platform, one per line. Open the file to see what each platform gets.

## Usage

### First-time setup

After cloning, check out this branch and run `bootstrap.sh` to add the sourceware upstream remote and fetch GDB release tags (used as base refs by `apply.sh`):

```bash
git checkout utils/patches
./bootstrap.sh
```

### Apply patches to all platforms

```bash
./apply.sh
```

This lists available GDB release tags, lets you pick one, and applies all platform patches. See `./apply.sh --help` for advanced usage.

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
