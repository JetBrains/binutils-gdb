# JetBrains GDB Patches

This branch contains patches applied to GDB for JetBrains IDE builds (CLion, etc.).

## Structure

```
(patches/gdb-jetbrains branch root)
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

### Apply patches to all platforms

```bash
# Check out this branch in a worktree
git worktree add /tmp/patches patches/gdb-jetbrains

# Apply to all platforms from a base ref
# Creates: linux/16.3-patched, darwin/16.3-patched, mingw/16.3-patched
/tmp/patches/apply.sh gdb-16.3-release 16.3-patched

# Apply and push
/tmp/patches/apply.sh 140ba01 16.3-patches-applied --push
```

### What apply.sh does

For each `<platform>.patches` manifest found:
1. Creates `{platform}/{branch-suffix}` from the base ref
2. Creates a temporary worktree on that branch
3. Applies each patch as a separate commit (`patch -p1` + `git commit`)
4. Creates a `.jetbrains-patches-applied` marker file with metadata
5. Cleans up the temporary worktree
6. Optionally pushes with `--push`

### Marker file

After patches are applied, `.jetbrains-patches-applied` is created in the repo root containing:
- Platform name
- Application date
- List of applied patches

The PKGBUILD `prepare()` functions check for this file to skip patch application when building from a pre-patched branch.

## Patch descriptions

### shared/

- **gdb-fix-using-gnu-print.patch** — Fix printf format specifiers for MinGW ANSI stdio
- **gdb-7.12-dynamic-libs.patch** — Disable static libstdc++/libgcc linking
- **gdbserver-Output-PID-right-after-create_inferior-call.patch** — Print PID consistently across platforms
- **CPP-10461-gdb-limit-cp_print_value_fields-recursion.patch** — Prevent stack overflow on deep object trees
- **0005-W32-Always-check-USERPROFILE-if-HOME-is-not-set.patch** — Check $USERPROFILE when $HOME is unset on Windows

### darwin/

- **configure.patch** — Allow GDB to build on Darwin targets
- **python.patch** — Fix Python initialization on Darwin
- **disable-native.patch** — Disable native target for cross-compilation (aarch64)

### mingw/

- **aarch64.patch** — Add aarch64-mingw32 target support
- **clang14.patch** — Add missing `<unordered_map>` includes for Clang 14
