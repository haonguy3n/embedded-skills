# Embedded Linux / Yocto Skills

A set of Claude Code **skills** encoding senior-level Yocto / BitBake / kernel / BSP
practice.

These are **platform-neutral**. They were written by studying how the Yocto Project
reference documentation and the major upstream BSP layers — `meta-freescale`/`meta-imx`
(NXP), `meta-tegra` (NVIDIA/OE4T), `meta-qcom` (Qualcomm), and OpenBMC — solve the same
recurring problems, and then extracting the *pattern* rather than the vendor's spelling of
it. Examples use `<soc>` / `myboard` / `linux-vendor` placeholders; substitute your silicon.

Upstream layers are named only where they are cited as evidence that a pattern is real and
battle-tested.

## Install

Skills are discovered from `~/.claude/skills/<name>/SKILL.md`. Symlink them:

```bash
./install.sh                           # symlinks every skill into ~/.claude/skills
./install.sh --project /path/to/repo   # or into <repo>/.claude/skills
```

Or manually:

```bash
ln -s /home/hao/work/skills/yocto-build-triage ~/.claude/skills/yocto-build-triage
```

## The skills

| Skill | Use it when |
|---|---|
| [`yocto-bitbake-core`](yocto-bitbake-core/SKILL.md) | Reasoning about variable expansion, overrides, task graph, signatures, datastore |
| [`yocto-build-triage`](yocto-build-triage/SKILL.md) | A build failed and you need a systematic root-cause loop |
| [`yocto-recipe-authoring`](yocto-recipe-authoring/SKILL.md) | Writing, upgrading, or packaging a recipe |
| [`yocto-layer-and-bsp`](yocto-layer-and-bsp/SKILL.md) | Creating layers, machine/distro configs, bbappends, board bring-up |
| [`yocto-bsp-patterns`](yocto-bsp-patterns/SKILL.md) | Designing a BSP that scales past the first board — the cross-vendor patterns |
| [`yocto-kernel-dev`](yocto-kernel-dev/SKILL.md) | Kernel recipes, config fragments, patches, out-of-tree modules, device trees |
| [`yocto-bootloader-secureboot`](yocto-bootloader-secureboot/SKILL.md) | Boot chain integration, boot containers, media offsets, signing and secure boot |
| [`yocto-image-wic-deploy`](yocto-image-wic-deploy/SKILL.md) | Image recipes, IMAGE_FSTYPES, wic/.wks, initramfs, flashing artifacts |
| [`yocto-devtool-workflow`](yocto-devtool-workflow/SKILL.md) | Fast edit/build/deploy iteration on a component |
| [`yocto-build-performance`](yocto-build-performance/SKILL.md) | Slow builds, sstate misses, CI caching, reproducibility |
| [`yocto-security-compliance`](yocto-security-compliance/SKILL.md) | CVE scanning, SBOM/SPDX, license compliance, source archiving |
| [`yocto-testing`](yocto-testing/SKILL.md) | ptest, testimage, oe-selftest, layer validation |
| [`yocto-migration-upgrade`](yocto-migration-upgrade/SKILL.md) | Moving between Yocto releases; override-syntax conversion |

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
