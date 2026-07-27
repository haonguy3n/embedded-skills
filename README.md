# Embedded Linux / Yocto skill

A single Claude Code **skill** encoding senior-level Yocto / BitBake / kernel / BSP practice.

It is **platform-neutral**. It was written by studying how the Yocto Project reference
documentation and the major upstream BSP layers — `meta-freescale`/`meta-imx` (NXP),
`meta-tegra` (NVIDIA/OE4T), `meta-qcom` (Qualcomm), and OpenBMC — solve the same recurring
problems, and then extracting the *pattern* rather than the vendor's spelling of it. Examples
use `<soc>` / `myboard` / `linux-vendor` placeholders; substitute your silicon. Upstream layers
are named only where they are cited as evidence that a pattern is real and battle-tested.

## Install

Skills are discovered from `~/.claude/skills/<name>/SKILL.md`. Symlink it:

```bash
./install.sh                           # symlinks into ~/.claude/skills
./install.sh --project /path/to/repo   # or into <repo>/.claude/skills
```

## Layout

`SKILL.md` is a lean core — override-syntax detection, assignment operators, `OVERRIDES`
precedence, where a setting belongs, the inspection commands, and the `tmp/work` layout — plus
a routing table. Everything else lives in `references/`, loaded only when the task needs it.

| Reference | Covers |
|---|---|
| [`triage.md`](yocto/references/triage.md) | Build failures: logs, devshell, QA taxonomy, fetch/patch/configure/rootfs/sysroot/sstate errors |
| [`recipes.md`](yocto/references/recipes.md) | Writing, upgrading and packaging recipes; PACKAGECONFIG, FILES, services, licensing |
| [`layers-bsp.md`](yocto/references/layers-bsp.md) | layer.conf, bbappends, machine/distro confs, board bring-up, and the cross-vendor BSP design patterns |
| [`kernel.md`](yocto/references/kernel.md) | Kernel recipes, `.cfg`/`.scc` config, patching, device trees, out-of-tree modules |
| [`boot.md`](yocto/references/boot.md) | Boot chain, U-Boot, boot containers, media offsets, FIT signing, fuses, A/B updates |
| [`images.md`](yocto/references/images.md) | Image recipes, IMAGE_FSTYPES, wic/`.wks`, initramfs, SDK/eSDK |
| [`devtool.md`](yocto/references/devtool.md) | Fast edit-build-deploy iteration, patch round-tripping, EXTERNALSRC |
| [`performance.md`](yocto/references/performance.md) | sstate, hash equivalence, mirrors, CI caching, reproducible builds |
| [`security.md`](yocto/references/security.md) | CVE triage, SPDX/SBOM, licence compliance, GPL source release, hardening |
| [`testing.md`](yocto/references/testing.md) | ptest, testimage, oeqa cases, oe-selftest, buildhistory gates, CI |
| [`migration.md`](yocto/references/migration.md) | Release map, the 3.4 override conversion, per-release breaking changes |
| [`bitbake.md`](yocto/references/bitbake.md) | Deeper BitBake: Python/datastore, dependency kinds, signatures, task chain |

## Release-syntax note

Two override syntaxes exist in the wild:

* **≤ 3.3 (zeus/dunfell/gatesgarth/hardknott)** — `SRC_URI_append`, `FILES_${PN}`, `DEPENDS_<override>`
* **≥ 3.4 (honister and later)** — `SRC_URI:append`, `FILES:${PN}`, `DEPENDS:<override>`

Examples throughout use `:`. **Match the syntax of the tree you are editing** — check
`LAYERSERIES_COMPAT` in `conf/layer.conf` or `DISTRO_VERSION` first. Mixing them fails
silently: a honister+ BitBake treats `FOO_append` as a different variable, not an error.

## Sources

- Yocto Project docs — <https://docs.yoctoproject.org/> (dev-manual, ref-manual, kernel-dev,
  bsp-guide, overview-manual, test-manual, migration-guides)
- meta-freescale / meta-imx — <https://github.com/Freescale/meta-freescale>,
  <https://github.com/nxp-imx/meta-imx>
- meta-tegra (OE4T) — <https://github.com/OE4T/meta-tegra>, <https://oe4t.github.io/>
- meta-qcom — <https://github.com/qualcomm-linux/meta-qcom>
- OpenBMC — <https://github.com/openbmc/openbmc>, <https://github.com/openbmc/docs>
