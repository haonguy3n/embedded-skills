---
name: yocto-migration-upgrade
description: Migrating a Yocto tree between releases — release/codename/version/LTS map, the 3.4 override syntax change (_ to :) and convert-overrides.py, per-release breaking changes (SPDX license identifier renames, WORKDIR/UNPACKDIR/S changes, variable renames like BB_ENV_EXTRAWHITE and BB_HASHBASE_WHITELIST, class removals, systemd/usrmerge shifts), LAYERSERIES_COMPAT bumps, and a staged upgrade procedure. Use when moving a BSP or product from one Yocto release to another, or when metadata from a newer/older release does not parse.
---

# Release migration

## Release map

| Version | Codename | Released | LTS | Notes |
|---|---|---|---|---|
| 2.5 | sumo | 2018-04 | | |
| 2.6 | thud | 2018-11 | | |
| 2.7 | warrior | 2019-04 | | |
| 3.0 | zeus | 2019-10 | | `_` override syntax |
| 3.1 | **dunfell** | 2020-04 | **LTS** | very widely deployed in vendor BSPs |
| 3.2 | gatesgarth | 2020-10 | | |
| 3.3 | hardknott | 2021-04 | | last `_` syntax release; `branch=` becomes mandatory on git SRC_URI |
| 3.4 | honister | 2021-10 | | **`:` override syntax** |
| 4.0 | **kirkstone** | 2022-04 | **LTS** | SPDX license IDs, many variable renames |
| 4.1 | langdale | 2022-10 | | |
| 4.2 | mickledore | 2023-04 | | |
| 4.3 | nanbield | 2023-11 | | |
| 5.0 | **scarthgap** | 2024-04 | **LTS** | |
| 5.1 | styhead | 2024-10 | | `UNPACKDIR` split from `WORKDIR` |
| 5.2 | walnascar | 2025-04 | | |
| 5.3 | whinlatter | 2025-10 | | |
| 6.0 | wrynose | 2026-04 | **LTS** (expected) | meta-qcom's LTS branch targets this |

Always read every intermediate release's migration guide:
<https://docs.yoctoproject.org/migration-guides/>. Skipping releases does not skip their
breaking changes.

**Reality check on vendor BSPs**: NXP, NVIDIA and Qualcomm BSPs lag upstream. Your upgrade
is gated by whether `meta-freescale`/`meta-imx`/`meta-tegra` has a branch for the target
release. Check that *first* — it usually decides the plan.

## The big one: 3.3 → 3.4 override syntax

`_` → `:` for override and operator separators.

```
SRC_URI_append          →  SRC_URI:append
SRC_URI_qemux86         →  SRC_URI:qemux86
FILES_${PN}-ptest       →  FILES:${PN}-ptest
IMAGE_CMD_tar           →  IMAGE_CMD:tar
d.getVar("RDEPENDS_${PN}")  →  d.getVar("RDEPENDS:${PN}")
do_install_append()     →  do_install:append()
```

Automated pass:
```bash
# from your layer's root
../poky/scripts/contrib/convert-overrides.py .
```
Edit the script's override list first to include **your** machine/distro/feature overrides
— it can't know them. Then review every hunk: the script is "enthusiastic" and will happily
rewrite `my_append_function` into `my:append:function`. Things it commonly gets wrong:

* function names containing `_append`, `_remove`, `_class`, or a machine name
* variables that legitimately contain an underscore matching an override
  (`SRCREV_machine` is a real name, not `SRCREV:machine`... it *is* an override — verify)
* Python string literals and comments
* shell variables inside tasks

Verify with `git diff --stat` and then `bitbake -e <recipe>` on a handful of recipes,
comparing key variables before/after.

Cannot be mixed: a honister+ BitBake does not understand `_append`. It won't error — it
will silently treat `FOO_append` as a *different variable*. That silent failure is why the
conversion must be complete and reviewed.

## Other high-impact changes by release

**hardknott (3.3)**
* `branch=` required on `git://` SRC_URI (else warning → later error).
* `${PYTHON_PN}` and python2 removals.

**honister (3.4)**
* Override syntax (above).
* Host now needs `lz4c`, `pzstd`, `zstd`.
* Prelinking disabled.
* `TOOLCHAIN_HOST_TASK_ESDK` split out.

**kirkstone (4.0)** — the biggest content churn:
* **SPDX license identifiers**: `GPLv2` → `GPL-2.0-only`, `LGPLv2.1+` →
  `LGPL-2.1-or-later`, `BSD` → specific variants. `INCOMPATIBLE_LICENSE` values too.
  Script: `scripts/contrib/convert-spdx-licenses.py`.
* Variable renames:
  `BB_ENV_EXTRAWHITE` → `BB_ENV_PASSTHROUGH_ADDITIONS`,
  `BB_HASHBASE_WHITELIST` → `BB_BASEHASH_IGNORE_VARS`,
  `BB_HASHCONFIG_WHITELIST` → `BB_HASHCONFIG_IGNORE_VARS`,
  `BB_SETSCENE_ENFORCE_WHITELIST` → `BB_SETSCENE_ENFORCE_IGNORE_TASKS`,
  `CVE_CHECK_PN_WHITELIST` → `CVE_CHECK_SKIP_RECIPE`,
  `CVE_CHECK_WHITELIST` → `CVE_CHECK_IGNORE` (→ later `CVE_STATUS`),
  `SSTATE_DUPWHITELIST` → `SSTATE_ALLOW_OVERLAP_FILES`,
  `PNBLACKLIST` → `SKIP_RECIPE`,
  `ICECC_USER_CLASS_BL` → `ICECC_CLASS_DISABLE`, etc.
  Script: `scripts/contrib/convert-variable-renames.py`.
* `inherit_defer` semantics, `create-spdx` on by default.
* Recipe-specific sysroots stricter; `do_configure` network access blocked.

**mickledore/nanbield (4.2/4.3)**
* `INHERIT_DISTRO`/class reshuffles; `python3-setuptools` build backends split
  (`setuptools3` vs `python_setuptools_build_meta`).
* `useradd` ordering and `USERADD_ERROR_DYNAMIC` strictness.

**scarthgap (5.0)**
* Many `-native` recipes dropped; `go`/`rust` recipe conventions changed.
* `PACKAGECONFIG` conflicts now hard errors in places.

**styhead (5.1)**
* `UNPACKDIR` introduced: `SRC_URI` `file://` entries unpack to `${UNPACKDIR}`, not
  `${WORKDIR}`. Recipes doing `install ${WORKDIR}/foo.service` must become
  `${UNPACKDIR}/foo.service`. This breaks a *lot* of downstream layers — grep for
  `${WORKDIR}/` in `do_install`.
* `S = "${WORKDIR}/git"` conventions shift accordingly.

## Staged upgrade procedure

1. **Scope**: list every layer and check it has a branch for the target release
   (`git branch -r` in each). Layers without one are your real work item — either upgrade
   them yourself or find a maintained replacement.
2. **Baseline**: record the current build. `INHERIT += "buildhistory"`, build, commit.
   Save `installed-packages.txt`, `image-info.txt`, kernel `.config`, license manifest.
3. **One release at a time** if crossing several. Each step: bump poky + layers, fix
   parsing, build `core-image-minimal`, then the product image.
4. **Mechanical passes** in order:
   ```bash
   scripts/contrib/convert-overrides.py <layer>          # 3.3 → 3.4
   scripts/contrib/convert-spdx-licenses.py <layer>      # → 4.0
   scripts/contrib/convert-variable-renames.py <layer>   # → 4.0
   grep -rn '\${WORKDIR}/' <layer> --include='*.bb*'     # → 5.1 UNPACKDIR
   ```
5. **Bump `LAYERSERIES_COMPAT_<collection>`** in each of your layers only after that layer
   builds.
6. **Fix parse errors, then QA errors, then runtime.** Do not skip QA errors with
   `INSANE_SKIP` during a migration — new QA checks are exactly where the real regressions
   surface.
7. **Diff the result**:
   ```bash
   buildhistory-diff <baseline-commit>
   diff <(old installed-packages.txt) <(new installed-packages.txt)
   scripts/diffconfig old.config new.config      # kernel
   ```
8. **Boot and run `testimage`** on real hardware before declaring done.

## Downgrading / backporting

Sometimes you must take a recipe from a newer release into an older tree. Check, in order:
class availability (`inherit` targets that don't exist yet), override syntax, license
identifier style, `${WORKDIR}` vs `${UNPACKDIR}`, and any `bb.utils`/`oe.` helper that
postdates your BitBake. Put backports in a clearly-named
`meta-mylayer/recipes-*/…` with a comment recording the upstream commit — future-you will
need to drop them at the next upgrade.

## What to tell stakeholders

An LTS-to-LTS upgrade (e.g. dunfell → kirkstone → scarthgap) on a real product BSP is
typically weeks, not days, and the long pole is almost always the **vendor BSP layer and
the kernel**, not core recipes. Say that up front, and stage it so the tree keeps building
at every step.
