# Testing

| Layer | Tool | Tests what |
|---|---|---|
| Metadata/build | `oe-selftest`, `yocto-check-layer`, `buildhistory-diff` | the build system and your layers |
| Package | `ptest` | upstream unit tests, on target |
| Image runtime | `testimage` (oeqa/runtime) | a booted image, QEMU or hardware |
| SDK | `testsdk`, `testsdk_ext` | the toolchain you ship |

## ptest

```bitbake
# globally
DISTRO_FEATURES:append = " ptest"
EXTRA_IMAGE_FEATURES += "ptest-pkgs"
```
```bitbake
# in a recipe
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
```bash
ptest-runner            # on target: all
ptest-runner mypkg
```
Packages are `${PN}-ptest`; `PTEST_ENABLED` gates the build;
`PTEST_PATH = ${libdir}/${PN}/ptest`. Keep them out of production images.

## testimage — runtime tests

```bitbake
INHERIT += "testimage"
IMAGE_CLASSES += "testimage"
TEST_SUITES = "ping ssh date parselogs systemd python3 ptest"
TEST_TARGET = "qemu"                # or "simpleremote", "SystemdbootTarget", custom
TEST_TARGET_IP = "192.168.1.10"
TEST_SERVER_IP = "192.168.1.1"
TESTIMAGE_AUTO = "1"                # run tests after every image build
TEST_QEMUBOOT_TIMEOUT = "1000"
```
```bash
bitbake <image> -c testimage
bitbake <image> -c testexport      # export tests to run elsewhere (tmp/testexport)
runqemu <machine> <image> nographic slirp
```
The image must include `ssh-server-dropbear`/`openssh` and the `TEST_SUITES` deps; QEMU targets
need an `IMAGE_FSTYPES` runqemu understands (`ext4`, `wic`).

For **real hardware**, `TEST_TARGET = "simpleremote"` with `TEST_TARGET_IP` — the target must
already be booted and reachable over SSH. For power-cycling/flashing rigs, write a `TEST_TARGET`
controller class (subclass `oeqa.controllers.*`); that is the supported extension point.

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
oeqa picks up `<layer>/lib/oeqa/...` automatically because `BBPATH .= ":${LAYERDIR}"` puts the
layer on `sys.path`. Then `TEST_SUITES += "myapp"`.

Helpers: `self.target.run(cmd)`, `self.target.copyTo/copyFrom`, `@OETestDepends`,
`@OEHasPackage`, `@skipIfNotFeature('systemd', ...)`, `@OETimeout(60)`.

## oe-selftest — testing the metadata

```bash
oe-selftest -l                    # list
oe-selftest -a                    # everything (hours)
oe-selftest -r devtool            # a module
oe-selftest -r devtool.DevtoolAddTests.test_devtool_add
oe-selftest -j 8                  # parallel
oe-selftest -r reproducible
bitbake-selftest                  # bitbake's own unit tests (fetchers, parser)
```
Your cases go in `meta-mylayer/lib/oeqa/selftest/cases/*.py` and subclass
`oeqa.selftest.case.OESelftestTestCase`. API: `self.write_config()`, `self.append_config()`,
`bitbake('target')`, `get_bb_var('X', 'recipe')`, `runCmd()`, `self.track_for_cleanup()`.

Constraints — enforced socially, and they bite in CI:
* never `cleanall`/`cleansstate` shared dirs (`DL_DIR`, `SSTATE_DIR`) — parallel runners share
  them,
* never modify layer metadata in place; write to a temp layer.

## Layer validation

`yocto-check-layer` invocations and what it checks are in `layers-bsp.md`. Also run in CI:
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
buildhistory-diff            # vs previous commit
buildhistory-diff HEAD~5
```
Fail CI on: image size growth beyond a threshold, new packages appearing, removed files,
changed package dependencies, changed kernel config. This catches far more real regressions
than most bespoke test suites, for one config line.

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
3. **gates**: `buildhistory-diff`, `IMAGE_ROOTFS_MAXSIZE`, `cve-check` report, licence manifest
   diff
4. **runtime**: `testimage` on QEMU for every commit; on real hardware nightly
5. **publish**: sstate to the mirror; images + SBOM + licence manifest + source archive to
   artifact storage, all tagged with every layer's SHA

Report results honestly: if the hardware leg didn't run, say so — a green QEMU run is not
evidence the board boots.
