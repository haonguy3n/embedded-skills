---
name: yocto-bitbake-core
description: BitBake language and execution model — variable expansion order, override syntax and OVERRIDES precedence, :append/:prepend/:remove, anonymous Python, the datastore API, task graph and dependency types (DEPENDS/RDEPENDS/DEPENDS-at-task-level), task signatures/checksums and why a task rebuilt. Use whenever reasoning about "why did this variable end up like that", "why did that override not apply", "why is everything rebuilding", or before writing any non-trivial .bb/.bbclass/.conf metadata.
---

# BitBake core semantics

The single most common source of Yocto bugs is assuming BitBake metadata behaves like a
shell script or Make. It does not. It is a **declarative datastore** that is fully parsed,
then flattened by overrides, then executed as a task graph.

## 0. First: which syntax does this tree use?

```bash
grep -r LAYERSERIES_COMPAT */conf/layer.conf   # zeus|dunfell|... vs honister|kirkstone|...
bitbake-getvar DISTRO_VERSION 2>/dev/null || bitbake -e | grep '^DISTRO_VERSION'
```

* **≤ 3.3 (…zeus, dunfell, gatesgarth, hardknott)**: `VAR_append`, `VAR_remove`, `FILES_${PN}`, `SRC_URI_soc-family`
* **≥ 3.4 (honister →)**: `VAR:append`, `VAR:remove`, `FILES:${PN}`, `SRC_URI:soc-family`

Never mix them in one tree. Examples below use `:`; translate mentally for older trees.

## 1. Assignment operators — expansion timing is the whole game

| Operator | Meaning | Expanded when |
|---|---|---|
| `=` | plain assign | lazily, at use |
| `:=` | immediate assign | **at parse time**, right now |
| `?=` | default; first one parsed wins | lazily |
| `??=` | weak default; loses to `?=` and `=` | lazily |
| `+=` / `=+` | append/prepend **with a space** | lazily |
| `.=` / `=.` | append/prepend **without a space** | lazily |
| `:append` / `:prepend` | append/prepend, applied **after all parsing** | at override-application time |
| `:remove` | remove whitespace-delimited items, applied last of all | at override-application time |

Rules that bite people:

* `+=` inside a `.bbappend` races with `+=` in the recipe — parse order decides. `:append`
  does not race: **all** `:append`s are applied after the base value is final. In
  `.bbappend` files, prefer `:append`.
* `:remove` wins over every `:append`, always. You cannot `:append` something back that a
  `:remove` deleted in the same expansion.
* `?=` in a `.conf` parsed *later* has no effect if the variable was already `=`-assigned.
  This is why `local.conf` (parsed last but with plain `=`) beats machine/distro `?=`.
* Use `:=` when you must capture something that will change later — the canonical case:

```bitbake
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
```
`THISDIR` differs per file being parsed, so it *must* be captured immediately.

## 2. OVERRIDES — the conditional mechanism

`OVERRIDES` is a colon-separated list. Anything matching `VAR:<something-in-OVERRIDES>`
replaces `VAR`. Right-most entry in `OVERRIDES` has **highest** precedence.

```bash
bitbake-getvar OVERRIDES               # modern
bitbake -e | grep '^OVERRIDES='        # any release
```

Typical expansion on an ARM SoC build:
```
OVERRIDES = "${TARGET_OS}:${TRANSLATED_TARGET_ARCH}:build-${BUILD_OS}:pn-${PN}:${MACHINEOVERRIDES}:${DISTROOVERRIDES}:${CLASSOVERRIDE}:forcevariable"
MACHINEOVERRIDES = "soc-family:soc-variant:myboard"
```

Consequences:

* `forcevariable` is last → `VAR:forcevariable = "x"` beats everything. Escape hatch only.
* `CLASSOVERRIDE` is `class-target` / `class-native` / `class-nativesdk` / `class-cross`.
  `DEPENDS:class-native = "..."` is how you differ per BBCLASSEXTEND variant.
* `pn-${PN}` lets a *config file* target one recipe: `EXTRA_OECONF:pn-busybox = "..."` in
  `local.conf`.
* Combined forms are ordered: `VAR:append:soc-family`, **not** `VAR:soc-family:append`. The override
  filter comes after the operator keyword... actually both parse, but only
  `VAR:append:<override>` is idiomatic and unambiguous — use it.

### MACHINEOVERRIDES chaining (vendor idiom)

meta-<soc-vendor> groups SoCs by extending `MACHINEOVERRIDES` so one line covers a family:

```bitbake
# conf/machine/include/<soc-family>.inc
INHERIT += "machine-overrides-extender"
MACHINEOVERRIDES_EXTENDER_soc-variant-a = "has-fbdev:has-vpu:has-gpu2d:has-gpu3d"
MACHINEOVERRIDES_EXTENDER_soc-variant-b = "..."
```
So a recipe can say `DEPENDS:append:has-gpu2d = " vendor-gl-userspace"` and it applies to every SoC
in that family. When adding a board, set the family override in the machine `.conf`, do
not fork the recipe.

## 3. Python in metadata

```bitbake
# Inline expansion — runs at variable-expansion time
FOO = "${@d.getVar('BAR', True).upper()}"
PACKAGECONFIG = "${@bb.utils.contains('DISTRO_FEATURES', 'systemd', 'systemd', '', d)}"
PACKAGECONFIG = "${@bb.utils.filter('DISTRO_FEATURES', 'wayland x11', d)}"

# Anonymous python — runs at the END of parsing this recipe, after all overrides
python __anonymous() {
    if d.getVar('MACHINE') == 'myboard':
        d.appendVar('DEPENDS', ' boot-container')
}

# Task written in python
python do_mytask() {
    bb.note("hello")
}
addtask mytask after do_compile before do_install
```

Datastore API you actually need:

| Call | Note |
|---|---|
| `d.getVar('X')` | expands by default in modern BitBake; pass `True` explicitly on old trees |
| `d.getVar('X', False)` | unexpanded |
| `d.setVar/appendVar/prependVar` | |
| `d.getVarFlag('do_x','flagname')` | task flags: `dirs`, `cleandirs`, `noexec`, `depends`, `rdepends`, `vardeps`, `vardepsexclude`, `network` |
| `d.expand('${X}/y')` | |
| `bb.utils.contains(var, checkvals, true, false, d)` | all of checkvals must be present |
| `bb.utils.contains_any(...)` | |
| `oe.utils.conditional(var, value, true, false, d)` | |

**Never** use `os.system`/`subprocess` at parse time, and never read files at parse time
without adding them to the parse dependencies — it silently breaks signature correctness.

## 4. Dependency kinds

| Variable | Meaning |
|---|---|
| `DEPENDS` | build-time; brings recipes' `do_populate_sysroot` output into `recipe-sysroot` |
| `RDEPENDS:${PN}` | runtime package dependency; must name **packages**, not recipes |
| `RRECOMMENDS:${PN}` | installed if available, not fatal if missing |
| `RSUGGESTS` / `RPROVIDES` / `RCONFLICTS` / `RREPLACES` | feed-level relations |
| `PROVIDES` | virtual names (`virtual/kernel`, `virtual/bootloader`) |
| `do_x[depends] = "recipe:do_y"` | precise inter-task edge — the sharp tool |
| `do_x[rdepends]` | runtime dep of a specific task |
| `EXTRA_IMAGEDEPENDS` | recipes built for the image but not installed into it (bootloaders) |
| `DEPENDS:append = " foo-native"` | host tool |

`virtual/*` is resolved with `PREFERRED_PROVIDER_virtual/kernel = "linux-vendor"` in the
machine conf. Check what actually got picked:

```bash
bitbake -e virtual/kernel | grep '^PN='
bitbake-getvar -r virtual/kernel PREFERRED_PROVIDER_virtual/kernel
```

## 5. Task signatures — "why did it rebuild?"

Every task gets a hash of: its own code, every variable it references (transitively), and
the hashes of its dependencies. Change any of those → rebuild + sstate miss.

```bash
# What does this task depend on?
bitbake-dumpsig tmp/stamps/<arch>/<pn>/<pv>.do_compile.sigdata.<hash>

# What changed between two builds?
bitbake -S printdiff <recipe>          # modern; compares against sstate
bitbake-diffsigs sigdata_A sigdata_B
bitbake --dump-signatures=printdiff <recipe>
```

Controls:

```bitbake
do_compile[vardeps] += "MY_TUNABLE"        # force dependency (e.g. var used only in a helper)
do_compile[vardepsexclude] = "DATETIME"    # break a spurious dependency
do_deploy[vardepvalue] = "fixed"           # pin the hash outright (last resort)
BB_BASEHASH_IGNORE_VARS                    # global excludes: TMPDIR, DL_DIR, ... (was BB_HASHBASE_WHITELIST pre-4.0)
BB_SIGNATURE_HANDLER = "OEEquivHash"       # enables hash equivalence with BB_HASHSERVE
```

Classic causes of "everything rebuilds":
* `DISTRO_FEATURES` / `MACHINE_FEATURES` / `TUNE_*` changed → world rebuild, expected.
* A variable containing a timestamp/hostname/build path leaked into a task → add to
  `vardepsexclude`.
* `SRCPV`/`AUTOREV` in `PV` → rebuilds on every upstream commit, by design.
* Layer added/removed changes `BBPATH`/`FILESPATH` → file lookups shift.

## 6. Task graph inspection

```bash
bitbake -g <target>                    # pn-buildlist, task-depends.dot, recipe-depends.dot
bitbake -g -u taskexp <target>         # GTK dependency explorer
bitbake -g -u taskexp_ncurses <target> # terminal version (4.1+)
bitbake <recipe> -c listtasks
bitbake -e <recipe> > /tmp/e.txt       # full flattened datastore + history of every assignment
bitbake-getvar -r <recipe> <VAR>       # modern, shows the assignment chain
```

`bitbake -e` output shows, above each variable, a comment trail of every file/line that
touched it. That trail is the answer to 90% of "who set this?".

## 7. Execution control

```bash
bitbake <recipe> -c <task>        # respects deps
bitbake <recipe> -c <task> -f     # force rerun this task
bitbake <recipe> -C <task>        # invalidate <task>, then run do_build (cascades!)
bitbake -b path/to/recipe.bb      # parse/run this file ONLY, no deps — debugging only
bitbake -k                        # keep going after failure
bitbake -D / -DD / -DDD -v        # increasing debug verbosity (provider selection etc.)
bitbake -n                        # dry run
```

## 8. Layer/file lookup order

* Recipes: highest `BBFILE_PRIORITY_<collection>` wins when two layers ship the same recipe.
* `.bbappend`: **all** matching appends apply, ordered by layer priority (low → high, so
  highest priority applied last).
* Files in `SRC_URI = "file://..."`: found via `FILESPATH`, which is built from
  `FILESOVERRIDES` (machine, distro, arch) — machine-specific dirs win:
  `<recipe-dir>/<PN>/<MACHINE>/f` beats `<recipe-dir>/<PN>/f`. Extend with
  `FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"`.

```bash
bitbake-layers show-layers
bitbake-layers show-appends
bitbake-layers show-overlayed      # recipes shadowed by a higher-priority layer
bitbake-layers show-recipes <pn>
```

## Anti-patterns

* Editing files under `tmp/work/` and expecting them to persist — they are wiped by
  `do_unpack`/`rm_work`. Use `devtool modify` (see `yocto-devtool-workflow`).
* Using `_append`/`:append` without a leading space: `SRC_URI:append = "file://x"` glues
  onto the previous item. Always `" file://x"`.
* `RDEPENDS` naming a recipe when the package is named differently (`${PN}-dev`,
  `libfoo1`). Check with `oe-pkgdata-util list-pkgs`.
* Putting machine-specific logic in a distro conf or vice versa.
* `INHERIT +=` in a recipe (that is `inherit`); `INHERIT` is for conf files only.
