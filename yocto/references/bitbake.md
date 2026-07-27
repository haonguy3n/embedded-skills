# BitBake semantics (beyond the SKILL.md core)

Operators, OVERRIDES precedence, inspection and execution flags are in `SKILL.md`.

## Python in metadata

```bitbake
# Inline — runs at variable-expansion time
FOO = "${@d.getVar('BAR', True).upper()}"
PACKAGECONFIG = "${@bb.utils.contains('DISTRO_FEATURES', 'systemd', 'systemd', '', d)}"
PACKAGECONFIG = "${@bb.utils.filter('DISTRO_FEATURES', 'wayland x11', d)}"

# Anonymous python — runs at the END of parsing this recipe, after all overrides
python __anonymous() {
    if d.getVar('MACHINE') == 'myboard':
        d.appendVar('DEPENDS', ' boot-container')
}

python do_mytask() { bb.note("hello") }
addtask mytask after do_compile before do_install
```

| Call | Note |
|---|---|
| `d.getVar('X')` | expands by default in modern BitBake; pass `True` on old trees |
| `d.getVar('X', False)` | unexpanded |
| `d.setVar` / `appendVar` / `prependVar` | |
| `d.getVarFlag('do_x','flag')` | flags: `dirs`, `cleandirs`, `noexec`, `depends`, `rdepends`, `vardeps`, `vardepsexclude`, `network` |
| `d.expand('${X}/y')` | |
| `bb.utils.contains(var, checkvals, true, false, d)` | **all** of checkvals must be present |
| `bb.utils.contains_any(...)` | |
| `oe.utils.conditional(var, value, true, false, d)` | |

**Never** call `os.system`/`subprocess` at parse time, and never read a file at parse time
without adding it to the parse dependencies — it silently breaks signature correctness.

## Dependency kinds

| Variable | Meaning |
|---|---|
| `DEPENDS` | build-time; stages recipes' `do_populate_sysroot` output into `recipe-sysroot` |
| `RDEPENDS:${PN}` | runtime; must name **packages**, not recipes |
| `RRECOMMENDS:${PN}` | installed if available, not fatal if missing |
| `RSUGGESTS` / `RPROVIDES` / `RCONFLICTS` / `RREPLACES` | feed-level relations |
| `PROVIDES` | virtual names (`virtual/kernel`, `virtual/bootloader`, `virtual/dtb`) |
| `do_x[depends] = "recipe:do_y"` | precise inter-task edge — the sharp tool |
| `do_x[rdepends]` | runtime dep of a specific task |
| `EXTRA_IMAGEDEPENDS` | built for the image but not installed into it (bootloaders, ATF) |
| `DEPENDS:append = " foo-native"` | host tool |

Resolve virtuals with `PREFERRED_PROVIDER_virtual/kernel = "linux-vendor"` in the machine
conf. Check what actually got picked:
```bash
bitbake -e virtual/kernel | grep '^PN='
bitbake-getvar -r virtual/kernel PREFERRED_PROVIDER_virtual/kernel
```

## Task signatures — "why did it rebuild?"

Every task hashes: its own code, every variable it references (transitively), and its
dependencies' hashes. Change any one → rebuild + sstate miss.

```bash
bitbake-dumpsig tmp/stamps/<arch>/<pn>/<pv>.do_compile.sigdata.<hash>
bitbake -S printdiff <recipe>          # compares against sstate
bitbake-diffsigs sigdata_A sigdata_B
```
```bitbake
do_compile[vardeps] += "MY_TUNABLE"        # force a dependency (var used only in a helper)
do_compile[vardepsexclude] = "DATETIME"    # break a spurious one
do_deploy[vardepvalue] = "fixed"           # pin the hash outright (last resort)
BB_BASEHASH_IGNORE_VARS                    # global excludes (was BB_HASHBASE_WHITELIST pre-4.0)
BB_SIGNATURE_HANDLER = "OEEquivHash"       # hash equivalence, with BB_HASHSERVE
```

Classic causes of "everything rebuilds":
* `DISTRO_FEATURES` / `MACHINE_FEATURES` / `TUNE_*` changed → world rebuild, expected.
* A timestamp/hostname/build path leaked into a task → `vardepsexclude`.
* `SRCPV`/`AUTOREV` in `PV` → rebuilds on every upstream commit, by design.
* A layer added/removed shifts `BBPATH`/`FILESPATH`, so file lookups move.

## Task chain and task manipulation

```
do_fetch → do_unpack → do_patch → do_prepare_recipe_sysroot → do_configure
  → do_compile → do_install → do_populate_sysroot
                            → do_package → do_packagedata → do_package_write_{ipk,deb,rpm}
  → do_populate_lic → do_deploy (deploy class) → do_build
```
```bitbake
do_mytask() { … }
addtask mytask after do_compile before do_install
do_mytask[dirs]      = "${B}"          # create & cd into
do_mytask[cleandirs] = "${WORKDIR}/x"  # wipe & create
do_mytask[noexec]    = "1"             # disable a task
do_mytask[depends]  += "openssl-native:do_populate_sysroot"
deltask do_package_qa                  # nuclear; almost always wrong
```
Prefer `do_install:append()` / `:prepend()` over redefining a whole task.

## Layer and file lookup order

* Recipes: highest `BBFILE_PRIORITY_<collection>` wins when two layers ship the same `PN`.
* `.bbappend`: **all** matching appends apply, ordered low → high priority (highest last).
* `SRC_URI = "file://..."`: found via `FILESPATH`, built from `FILESOVERRIDES` (machine,
  distro, arch). `<recipe-dir>/<PN>/<MACHINE>/f` beats `<recipe-dir>/<PN>/f`.

## Anti-patterns

* Editing files under `tmp/work/` — wiped by `do_unpack`/`rm_work`. Use `devtool modify`.
* `RDEPENDS` naming a recipe when the package is named differently (`${PN}-dev`, `libfoo1`).
  Check with `oe-pkgdata-util list-pkgs`.
* Machine-specific logic in a distro conf, or vice versa.
* `INHERIT +=` in a recipe — that is `inherit`; `INHERIT` is for conf files only.
