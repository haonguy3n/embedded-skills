---
name: yocto-testing
description: Testing a Yocto build and its output — ptest packaging and running, testimage/testexport runtime tests on QEMU or real hardware (TEST_SUITES, TEST_TARGET, TESTIMAGE_AUTO, TEST_SERVER_IP, controllers), writing oeqa runtime and selftest cases, oe-selftest and bitbake-selftest, yocto-check-layer, buildhistory as a regression gate, and CI test wiring. Use when adding tests, setting up automated validation, or asked "how do we know this image works".
---

# Testing

Four layers of testing, use the right one:

| Layer | Tool | Tests what |
|---|---|---|
| Metadata/build | `oe-selftest`, `yocto-check-layer`, `buildhistory-diff` | the build system and your layers |
| Package | `ptest` | upstream unit tests, on target |
| Image runtime | `testimage` (oeqa/runtime) | a booted image, QEMU or hardware |
| SDK | `testsdk`, `testsdk_ext` | the toolchain you ship |

## ptest

Turn on globally:
```bitbake
DISTRO_FEATURES:append = " ptest"
EXTRA_IMAGE_FEATURES += "ptest-pkgs"
```
Add to a recipe:
```bitbake
inherit ptest

SRC_URI += "file://run-ptest"
RDEPENDS:${PN}-ptest += "make bash python3-core"

do_install_ptest() {
    install -d ${D}${PTEST_PATH}/tests
    cp -r ${B}/tests/* ${D}${PTEST_PATH}/tests/
}
```
`run-ptest` must print TAP-ish lines (`PASS: name`, `FAIL: name`, `SKIP: name`) and exit 0:
```sh
#!/bin/sh
cd tests && ./run_all.sh 2>&1 | sed -u 's/^ok /PASS: /; s/^not ok /FAIL: /'
```
Run:
```bash
# on target
ptest-runner            # all
ptest-runner mypkg
# from the host, as part of testimage
TEST_SUITES = "ping ssh ptest"
```
Notes: ptest packages are `${PN}-ptest`; `PTEST_ENABLED` gates the build;
`PTEST_PATH = ${libdir}/${PN}/ptest`. Keep them out of production images.

## testimage — runtime tests

```bitbake
INHERIT += "testimage"
TEST_SUITES = "ping ssh date parselogs systemd python3 ptest"
TEST_TARGET = "qemu"                # or "simpleremote", "SystemdbootTarget", custom
TEST_TARGET_IP = "192.168.1.10"
TEST_SERVER_IP = "192.168.1.1"
TESTIMAGE_AUTO = "1"                # run tests automatically after every image build
TEST_QEMUBOOT_TIMEOUT = "1000"
IMAGE_CLASSES += "testimage"
```
```bash
bitbake <image> -c testimage
bitbake <image> -c testexport      # export tests to run elsewhere (tmp/testexport)
runqemu <machine> <image> nographic slirp
```
Requirements: image must include `ssh-server-dropbear`/`openssh` and `TEST_SUITES` deps;
QEMU targets need `IMAGE_FSTYPES` with something runqemu understands (`ext4`, `wic`).

For **real hardware**, `TEST_TARGET = "simpleremote"` with `TEST_TARGET_IP` — the target
must already be booted and reachable over SSH. For power-cycling/flashing rigs, write a
`TEST_TARGET` controller class (subclass `oeqa.controllers.*`) and point `TEST_TARGET` at it;
that's the supported extension point.

### Writing a runtime test

`meta-mylayer/lib/oeqa/runtime/cases/myapp.py`:
```python
from oeqa.runtime.case import OERuntimeTestCase
from oeqa.core.decorator.depends import OETestDepends
from oeqa.runtime.decorator.package import OEHasPackage

class MyAppTest(OERuntimeTestCase):

    @OETestDepends(['ssh.SSHTest.test_ssh'])
    @OEHasPackage(['myapp'])
    def test_myapp_version(self):
        status, output = self.target.run('myapp --version')
        self.assertEqual(status, 0, msg='myapp failed: %s' % output)
        self.assertIn('1.2.3', output)
```
The layer must expose it:
```bitbake
# conf/layer.conf
BBPATH .= ":${LAYERDIR}"
# oeqa picks up <layer>/lib/oeqa/... automatically because BBPATH is on sys.path
```
Then `TEST_SUITES += "myapp"`.

Useful helpers: `self.target.run(cmd)`, `self.target.copyTo/copyFrom`,
`@OETestDepends`, `@OEHasPackage`, `@skipIfNotFeature('systemd', ...)`,
`@OETimeout(60)`.

## oe-selftest — testing the metadata

```bash
oe-selftest -l                    # list
oe-selftest -a                    # everything (hours)
oe-selftest -r devtool            # a module
oe-selftest -r devtool.DevtoolAddTests.test_devtool_add
oe-selftest -j 8                  # parallel
oe-selftest -r reproducible       # reproducibility check
bitbake-selftest                  # bitbake's own unit tests (fetchers, parser)
```
Your cases go in `meta-mylayer/lib/oeqa/selftest/cases/*.py` and subclass
`oeqa.selftest.case.OESelftestTestCase`. Handy API: `self.write_config()`,
`self.append_config()`, `bitbake('target')`, `get_bb_var('X', 'recipe')`,
`runCmd()`, `self.track_for_cleanup()`.

Constraints (they are enforced socially, and they bite in CI):
* never `cleanall`/`cleansstate` shared dirs (`DL_DIR`, `SSTATE_DIR`) — parallel runners
  share them,
* never modify layer metadata in place; write to a temp layer.

## Layer validation

```bash
yocto-check-layer ../meta-mycompany
yocto-check-layer --machines myboard -- ../meta-mycompany
yocto-check-layer --dependency ../meta-<soc-vendor> -- ../meta-mycompany
```
Checks: README present, layer parses, `LAYERSERIES_COMPAT` set, world build works, no
signature changes when the layer is merely *added* (this is the important one — a layer must
not change other layers' output just by being present), BSP layers don't set `MACHINE`,
distro layers don't set `DISTRO`, patches have `Upstream-Status`.

Also run in CI:
```bash
bitbake world -k --dry-run           # parse everything, catch broken recipes
bitbake -k --runall=fetch world      # prove all sources are fetchable/mirrored
bitbake -k --runall=unpack world
```

## Regression gates that cost nothing

```bitbake
INHERIT += "buildhistory"
BUILDHISTORY_COMMIT = "1"
IMAGE_ROOTFS_MAXSIZE = "500000"
```
```bash
buildhistory-diff                        # vs previous commit
buildhistory-diff HEAD~5
```
Fail CI on: image size growth beyond a threshold, new packages appearing in the image,
removed files, changed package dependencies, changed kernel config. This catches far more
real regressions than most bespoke test suites, for one config line.

## SDK tests

```bash
bitbake <image> -c testsdk
bitbake <image> -c testsdk_ext
```
Cases in `meta/lib/oeqa/sdk/cases/` and `sdkext/cases/`. Add your own under
`meta-mylayer/lib/oeqa/sdk/cases/` and extend `TESTSDK_SUITES`.

## A practical CI pipeline

1. **lint/parse**: `bitbake -p`, `yocto-check-layer`, `oe-selftest -r <fast module>`
2. **build**: image + SDK, with sstate mirror + hashserv
3. **gates**: `buildhistory-diff`, `IMAGE_ROOTFS_MAXSIZE`, `cve-check` report, license
   manifest diff
4. **runtime**: `testimage` on QEMU for every commit; on real hardware nightly
5. **publish**: sstate to the mirror, images + SBOM + license manifest + source archive to
   artifact storage, all tagged with every layer's SHA

Report results honestly: if the hardware leg didn't run, say so — a green QEMU run is not
evidence the board boots.
