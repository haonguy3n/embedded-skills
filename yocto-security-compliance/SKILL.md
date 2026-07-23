---
name: yocto-security-compliance
description: Security and license compliance in Yocto — cve-check class and CVE_PRODUCT/CVE_VERSION/CVE_STATUS/CVE_CHECK_SKIP_RECIPE/cve-exclusion, reading the CVE reports, SPDX/SBOM generation with create-spdx, license manifests, LICENSE/LIC_FILES_CHKSUM, INCOMPATIBLE_LICENSE and LICENSE_FLAGS, source archiving with archiver.bbclass for GPL compliance, security_flags hardening, and image hardening (debug-tweaks, read-only rootfs, meta-security). Use for CVE triage, SBOM/audit requests, GPL source-release obligations, or hardening a production image.
---

# Security & compliance

## CVE scanning

```bitbake
INHERIT += "cve-check"
# or per-image: IMAGE_CLASSES += "cve-check"
include conf/distro/include/cve-extra-exclusions.inc   # upstream-agreed non-issues
```
```bash
bitbake -k <image>                      # -k so one bad recipe doesn't stop the scan
bitbake <recipe> -c cve_check
```

Reports land in `tmp/deploy/cve/` and `${DEPLOY_DIR_IMAGE}/<image>*.cve` /
`.json`. Formats controlled by:

```bitbake
CVE_CHECK_REPORT_PATCHED = "1"       # include Patched/Ignored, not just Unpatched
CVE_CHECK_FORMAT_JSON = "1"
CVE_CHECK_CREATE_MANIFEST = "1"
CVE_CHECK_DB_FILE                    # local NVD mirror (fetched by cve-update-nvd2-native)
CVE_CHECK_SKIP_RECIPE = "linux-firmware glibc-locale"
```

### Per-recipe controls

| Variable | Use |
|---|---|
| `CVE_PRODUCT` | map recipe → NVD product; supports `vendor:product`, multiple entries. Wrong `CVE_PRODUCT` is the #1 cause of both false positives and missed CVEs |
| `CVE_VERSION` | when `PV` doesn't match NVD's versioning (git snapshots, `1.2.3+gitX`) |
| `CVE_STATUS[CVE-2024-1234] = "<reason>: <explanation>"` | per-CVE disposition |
| `CVE_CHECK_IGNORE` | **legacy**, replaced by `CVE_STATUS` in kirkstone+ |
| `CVE_CHECK_SKIP_RECIPE` | exclude a whole recipe |
| `CVE_CHECK_STATUSMAP` | maps reason strings → `Patched` / `Ignored` / `Unpatched` |

```bitbake
CVE_STATUS[CVE-2023-12345] = "not-applicable-config: feature disabled via PACKAGECONFIG"
CVE_STATUS[CVE-2023-99999] = "fixed-version: patched by 0003-fix-cve.patch"
CVE_STATUS[CVE-2022-11111] = "upstream-wontfix: only affects the Windows build"
```
Standard reasons: `patched`, `ignored`, `not-applicable-config`, `not-applicable-platform`,
`disputed`, `upstream-wontfix`, `cpe-incorrect`, `fixed-version`.

A patch that fixes a CVE is auto-detected if its filename or a `CVE: CVE-2024-1234` line in
the patch header names it — **always put `CVE: CVE-xxxx-yyyy` in the patch header**. That's
how `cve-check` marks it Patched without any extra metadata.

### Triage workflow

1. `bitbake -k <image>` with `cve-check`; collect `<image>.json`.
2. Filter to `Unpatched`. Sort by CVSS.
3. For each: does the shipped configuration actually reach the vulnerable code?
   (`PACKAGECONFIG`, is the daemon even installed, is the port exposed?)
4. Fix in this order: **upgrade recipe** → **backport patch** (with `CVE:` header +
   `Upstream-Status: Backport [<url>]`) → **document `CVE_STATUS`** with a real reason.
5. Never bulk-add to `CVE_CHECK_SKIP_RECIPE` to make the report green.

Caveats to state when reporting: `cve-check` matches CPE names, so it misses vendored
third-party code inside a recipe, and it does not know about your own first-party code. Pair
it with SBOM-based scanning.

## SBOM / SPDX

```bitbake
INHERIT += "create-spdx"          # default via INHERIT_DISTRO in newer releases
SPDX_PRETTY = "1"
SPDX_INCLUDE_SOURCES = "1"
SPDX_INCLUDE_COMPILED_SOURCES = "1"
SPDX_INCLUDE_KERNEL_CONFIG = "1"
SPDX_INCLUDE_PACKAGECONFIG = "1"
SPDX_ORGANIZATION / SPDX_SUPPLIER / SPDX_PACKAGE_SUPPLIER
SPDX_FILE_EXCLUDE_PATTERNS
```
```bash
bitbake <image>                             # → tmp/deploy/images/<m>/<image>.spdx.json
bitbake <recipe> -c create_recipe_sbom       # recipe-level SBOM without a full build
```
Disable: `INHERIT_DISTRO:remove = "create-spdx"`.

Yocto emits SPDX 2.2 (`create-spdx-2.2`) or SPDX 3.0 (`create-spdx-3.0`) depending on
release — check which class the tree inherits before promising a format to an auditor.

## License compliance

```bitbake
LICENSE = "GPL-2.0-only & MIT"
LIC_FILES_CHKSUM = "file://COPYING;md5=…"
INCOMPATIBLE_LICENSE = "GPL-3.0* LGPL-3.0* AGPL-3.0*"    # classic embedded policy
LICENSE_FLAGS_ACCEPTED = "commercial_gst-plugins-ugly synaptics-killswitch"
AVAILABLE_LICENSES / SPDXLICENSEMAP
COPY_LIC_MANIFEST = "1"
COPY_LIC_DIRS = "1"
LICENSE_CREATE_PACKAGE = "1"      # ships ${PN}-lic packages onto the target
```
Outputs: `tmp/deploy/licenses/<image>/license.manifest` and per-recipe license dirs.

`INCOMPATIBLE_LICENSE` failures look like:
```
ERROR: Nothing PROVIDES 'foo' ... was skipped: because it has incompatible license(s): GPL-3.0-only
```
Resolve by choosing a differently-licensed alternative (`VIRTUAL-RUNTIME_*`,
`PREFERRED_PROVIDER`), not by whitelisting silently.

## Source release (GPL obligation)

```bitbake
INHERIT += "archiver"
ARCHIVER_MODE[src] = "original"        # or "patched" / "configured"
ARCHIVER_MODE[diff] = "1"
ARCHIVER_MODE[dumpdata] = "1"
ARCHIVER_MODE[recipe] = "1"
COPYLEFT_LICENSE_INCLUDE = "GPL* LGPL* AGPL*"
COPYLEFT_RECIPE_TYPES = "target"       # exclude native/nativesdk
```
Output: `tmp/deploy/sources/`. For a real release you generally want
`ARCHIVER_MODE[src] = "patched"` (what you actually built) plus the recipe and the
`.bbappend`s — that is the "corresponding source".

Do this **per release build**, archive it, and keep it as long as the obligation runs
(often 3 years). Reconstructing it later from a moving branch is painful.

## Compiler / toolchain hardening

```bitbake
require conf/distro/include/security_flags.inc
```
Provides `-fstack-protector-strong`, `-D_FORTIFY_SOURCE=2`, `-Wl,-z,relro,-z,now`,
`-fPIE -pie` via `SECURITY_CFLAGS`/`SECURITY_LDFLAGS`, with a per-recipe exclusion list
(`SECURITY_CFLAGS:pn-<x>`). Some recipes break under PIE — fix or exempt individually.

```bitbake
# also useful
GCCPIE = "--enable-default-pie"
DISTRO_FEATURES:append = " pam seccomp"
```

## Image hardening checklist

- [ ] no `debug-tweaks`, no `allow-empty-password`, no `empty-root-password`
- [ ] no `package-management` unless you truly do field package installs
- [ ] no `tools-debug` / `dbg-pkgs` / `-dev` packages
- [ ] `read-only-rootfs` in `IMAGE_FEATURES` (+ overlayfs/tmpfs for `/var`)
- [ ] root login disabled or key-only; real user accounts via `useradd` in a recipe, never
      by editing `/etc/passwd` in a postprocess
- [ ] SSH host keys and `/etc/machine-id` generated at **first boot**, not baked in
- [ ] `EXTRA_USERS_PARAMS` for password hashes, never plaintext in metadata
- [ ] serial console / U-Boot prompt disabled or authenticated in production
      (`CONFIG_AUTOBOOT_KEYED`, `CONFIG_CMD_*` trimmed)
- [ ] secure boot chain enabled and *verified* (`hab_status` clean) before fuses are blown
- [ ] `INCOMPATIBLE_LICENSE` policy enforced in the distro conf, not per-image
- [ ] cve-check + SBOM produced and archived for each release build

Extra layers worth knowing: `meta-security` (AppArmor/SELinux, `dm-verity`, IMA/EVM, clamav,
`meta-tpm`), `meta-integrity`, `meta-openssl-*` for FIPS-ish builds.

`dm-verity` in poky: `INHERIT += "dm-verity-img"`, `DM_VERITY_IMAGE`,
`DM_VERITY_IMAGE_TYPE` — pairs naturally with a signed FIT and a read-only rootfs.

## Reporting findings

When you report CVE or license results, always state:
* which image and which build (commit SHAs of every layer),
* the scanner and its limitations (CPE matching; vendored code invisible),
* counts by status (Unpatched/Patched/Ignored) **and** the reason for every Ignored,
* what was *not* scanned (first-party code, prebuilt vendor blobs, firmware).
