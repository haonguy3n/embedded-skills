---
name: yocto-build-performance
description: Making Yocto builds fast and reproducible — BB_NUMBER_THREADS/PARALLEL_MAKE tuning, shared DL_DIR/SSTATE_DIR, SSTATE_MIRRORS and PREMIRRORS, hash equivalence (BB_HASHSERVE/OEEquivHash), rm_work, ccache/icecc, diagnosing sstate misses with bitbake -S printdiff, CI cache strategy, build statistics (buildstats, toaster, pybootchartgui), and reproducible-builds settings. Use when builds are slow, CI rebuilds everything, sstate hit rate is poor, or binaries must be bit-identical.
---

# Build performance & reproducibility

## Baseline machine settings (`local.conf` / `site.conf`)

```bitbake
BB_NUMBER_THREADS ?= "${@oe.utils.cpu_count()}"
PARALLEL_MAKE     ?= "-j ${@oe.utils.cpu_count()}"
BB_NUMBER_PARSE_THREADS ?= "${@oe.utils.cpu_count()}"

DL_DIR     ?= "/var/cache/yocto/downloads"
SSTATE_DIR ?= "/var/cache/yocto/sstate"
TMPDIR      = "${TOPDIR}/tmp"

INHERIT += "rm_work"          # frees tmp/work as recipes finish
RM_WORK_EXCLUDE += "myapp linux-vendor"      # keep the ones you debug

BB_SERVER_TIMEOUT = "3600"    # keep the memory-resident bitbake server warm
```

Rules of thumb:
* `BB_NUMBER_THREADS × PARALLEL_MAKE` is the real concurrency. Setting both to nproc on a
  64-core box means 4096 jobs → thrashing. Start with
  `BB_NUMBER_THREADS = nproc`, `PARALLEL_MAKE = -j nproc/2` and measure.
* RAM is usually the binding constraint (~2–4 GB per parallel task for heavy recipes:
  webkit, chromium, llvm, kernel LTO).
* Disk: ext4 with `noatime`; a full build is 50–100 GB of small-file churn. NVMe matters
  more than core count past ~16 cores. `tmp/` on tmpfs works if you have >64 GB RAM.
* `DL_DIR` and `SSTATE_DIR` **outside** `TMPDIR` so `rm -rf tmp` is always safe.

## Shared state — where the wins actually are

sstate lets any task be *replaced* by its cached output. A cold build with a good sstate
mirror is minutes, not hours.

```bitbake
SSTATE_MIRRORS ?= "\
file://.* http://sstate.example.com/PATH;downloadfilename=PATH \n \
file://.* file:///mnt/nfs/sstate/PATH \n \
"
BB_HASHSERVE = "auto"                       # local hash-equivalence server
BB_SIGNATURE_HANDLER = "OEEquivHash"
# Shared team server instead:
# BB_HASHSERVE = "hashserv.example.com:8686"
# BB_HASHSERVE_UPSTREAM = "hashserv.yoctoproject.org:8686"

PREMIRRORS:prepend = "\
git://.*/.* http://sources.example.com/ \n \
https?://.*/.* http://sources.example.com/ \n"
BB_GENERATE_MIRROR_TARBALLS = "1"          # makes git checkouts mirrorable
```

**Hash equivalence** is the single biggest CI win: when a task's *output* is unchanged even
though its input hash changed (e.g. a comment-only patch in a dependency), the hashserv
maps the new hash to the old one and the whole downstream tree stays cached. Without it, a
one-character change in `zlib` rebuilds the world.

### Diagnosing a miss

```bash
bitbake -S printdiff <target>      # "what would have been reused, and why wasn't it"
bitbake-diffsigs <sigA> <sigB>
bitbake-dumpsig tmp/stamps/.../do_compile.sigdata.<hash>
bitbake-whatchanged <target>       # older helper
```
Then fix the *cause*:

| Cause | Fix |
|---|---|
| build path leaked into a signature | it's in `BB_BASEHASH_IGNORE_VARS` normally; a recipe re-exposed it → `vardepsexclude` |
| `DATETIME`, `BUILD_ID`, git describe in a variable | `do_x[vardepsexclude] = "DATETIME"` |
| `AUTOREV`/`SRCPV` | pin `SRCREV` in release configs |
| layer added/removed → `FILESPATH` changed | expected; keep layer sets identical across builds |
| different host distro in CI | use a container; `uninative` (`INHERIT += "uninative"`) makes sstate portable across host libc versions |
| `TMPDIR` path differs between machines | sstate is path-relocatable for most tasks but not all — keep `TOPDIR` layout consistent |

`uninative` is essential for sharing sstate between different build hosts. It ships a
common glibc for native tools so `-native` sstate is reusable. Enabled by default in poky's
`local.conf.sample.extended`.

## ccache and icecc

```bitbake
INHERIT += "ccache"
CCACHE_TOP_DIR ?= "/var/cache/yocto/ccache"
CCACHE_DISABLE:pn-<recipe> = "1"      # exclude problem recipes
```
```bitbake
INHERIT += "icecc"
ICECC_PARALLEL_MAKE = "-j 40"
ICECC_DISABLED = ""
ICECC_USER_PACKAGE_BL = "linux-vendor"   # blacklist
```
Honest assessment: with a working sstate mirror + hash equivalence, ccache adds little and
costs disk. icecc helps a small team with idle machines and no shared sstate. **Fix sstate
first.**

## Measuring

```bitbake
INHERIT += "buildstats buildstats-summary"
```
```bash
# per-task time/IO under tmp/buildstats/<build>/
scripts/pybootchartgui/pybootchartgui.py tmp/buildstats/<build>   # timeline PNG
bitbake -P <target>                          # profile bitbake itself
oe-build-perf-test                           # the upstream perf suite
```
`buildstats-summary` prints the top time-consuming tasks at the end of a build — the
cheapest possible instrumentation, turn it on permanently.

Also: `INHERIT += "buildhistory"` with `BUILDHISTORY_COMMIT = "1"` for output tracking
(sizes, package lists, dependency changes) — `buildhistory-diff` between builds.

## CI strategy that works

1. Build in a **pinned container** (same host distro for everyone).
2. `INHERIT += "uninative"`.
3. Persistent volumes for `DL_DIR` and `SSTATE_DIR`; publish sstate from `main` builds to
   an HTTP mirror consumed by PR builds (read-only).
4. Run a shared `bitbake-hashserv` (`BB_HASHSERVE = "host:8686"`), persisted.
5. Pin every layer to a SHA (kas/repo manifest). No floating branches.
6. `BB_GENERATE_MIRROR_TARBALLS = "1"` on the mirror-populating job; PR jobs run with
   `BB_NO_NETWORK = "1"` or `BB_FETCH_PREMIRRORONLY = "1"` to prove sources are mirrored.
7. `IMAGE_ROOTFS_MAXSIZE` + `buildhistory-diff` as gates so size/content regressions fail
   the pipeline instead of surprising you at release.

```bitbake
# PR job hardening
BB_FETCH_PREMIRRORONLY = "1"
BB_NO_NETWORK = "1"
SSTATE_MIRRORS = "file://.* http://sstate.internal/PATH;downloadfilename=PATH"
```

## Reproducible builds

```bitbake
INHERIT += "reproducible_build"        # default in poky since kirkstone
BUILD_REPRODUCIBLE_BINARIES = "1"
SOURCE_DATE_EPOCH                       # derived from git/most-recent file mtime
export PYTHONHASHSEED = "0"
```
Checks:
```bash
oe-selftest -r reproducible            # upstream reproducibility test
diffoscope a/foo.ipk b/foo.ipk
```
Common breakers: embedded `__DATE__`/`__TIME__`, absolute build paths (`buildpaths` QA),
hostname/username in binaries, non-deterministic archive ordering (`tar --sort=name`),
locale-dependent sorting, `RANDOM`/`uuidgen` at build time, unsorted `ls` in a Makefile.

Fix in the recipe, not by disabling the check — `buildpaths` failing today means your SBOM
and your sstate portability are both already broken.

## Quick wins checklist

- [ ] `DL_DIR`/`SSTATE_DIR` shared and outside `tmp`
- [ ] `BB_HASHSERVE = "auto"` (or a team server) + `OEEquivHash`
- [ ] `uninative` inherited
- [ ] `rm_work` on, with `RM_WORK_EXCLUDE` for what you debug
- [ ] `BB_SERVER_TIMEOUT` so bitbake doesn't re-parse each invocation
- [ ] `buildstats-summary` on; know your top-10 slow tasks
- [ ] no `AUTOREV` in release configs
- [ ] sstate mirror reachable from CI, hit rate monitored (parse the
      `Sstate summary: Wanted N Local L Mirrors M Missed X` line bitbake prints)
