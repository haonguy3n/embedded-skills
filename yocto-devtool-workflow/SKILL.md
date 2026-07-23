---
name: yocto-devtool-workflow
description: Fast iteration on a component inside a Yocto build using devtool and externalsrc — devtool add/modify/upgrade/build/deploy-target/finish/reset/status/ide-sdk, the workspace layer, patch round-tripping, working on the kernel or u-boot, EXTERNALSRC for a permanently out-of-tree component, and the eSDK. Use when the edit-compile-test cycle through plain bitbake is too slow, when rebasing patches, or when integrating a component whose source lives in its own git repo.
---

# devtool & fast iteration

Plain `bitbake` wipes `${S}` on every `do_unpack`. `devtool` gives you a persistent git
worktree that BitBake builds from, so you can edit, build, and turn the result back into
patches.

## The core loop

```bash
devtool modify <recipe>                 # extract source to workspace/sources/<recipe>
cd build/workspace/sources/<recipe>
# ... edit ...
devtool build <recipe>                  # == bitbake <recipe> -c populate_sysroot
devtool deploy-target <recipe> root@192.168.1.10       # scp the build output onto a board
# iterate ...
git add -A && git commit -s -m "subsys: do the thing"
devtool finish <recipe> ../meta-mycompany              # write patches back, leave workspace
```

`devtool modify` turns each existing `SRC_URI` patch into a **git commit**. So rebasing
patches onto a new version is `git rebase`, and `devtool finish` regenerates the patch
files from the commits. This is the correct way to maintain a patch stack.

## Subcommands

| Command | What it does |
|---|---|
| `devtool add <name> <srctree> [<fetchuri>]` | create a brand-new recipe from a source tree or URL; auto-detects build system, license, deps |
| `devtool add --binary` | package a prebuilt tree |
| `devtool modify <recipe> [<srctree>]` | check out an existing recipe's source for editing; `-x` to extract, `-n` to skip patch application |
| `devtool upgrade <recipe> -V <ver> [-S <srcrev>]` | bump version, rebase patches |
| `devtool build <recipe>` | build it |
| `devtool build-image <image>` | build an image **including** everything in the workspace |
| `devtool deploy-target <recipe> user@host[:destdir]` | rsync the recipe's `${D}` onto a running target over SSH (bypasses the package manager) |
| `devtool undeploy-target <recipe> user@host` | undo that |
| `devtool finish <recipe> <layer>` | update the recipe/append in `<layer>` from your commits, then reset |
| `devtool finish <recipe> <layer> --no-clean / --remove-work` | control cleanup |
| `devtool reset <recipe>` | drop from workspace (modified files preserved in `workspace/attic/`) |
| `devtool status` | what's currently in the workspace |
| `devtool edit-recipe <recipe>` | open the workspace recipe in `$EDITOR` |
| `devtool search <keyword>` | find recipes by name/description/shipped file |
| `devtool check-upgrade-status` | which recipes have newer upstream releases |
| `devtool ide-sdk <recipe> <image> --target user@host` | generate VS Code / gdb config + SDK for a recipe |
| `devtool sdk-install <recipe>` / `sdk-update` | eSDK only |
| `devtool create-workspace <path>` | put the workspace layer somewhere specific |

## Workspace layout

```
build/workspace/
├── conf/layer.conf
├── appends/<recipe>.bbappend      # points EXTERNALSRC at sources/<recipe>
├── recipes/<recipe>/<recipe>.bb   # only for `devtool add`/`upgrade`
├── sources/<recipe>/              # your git worktree
├── attic/                         # rescued files from `devtool reset`
└── README
```
The workspace is a real layer, auto-added to `BBLAYERS`. Nothing is magic — the appends
just set `EXTERNALSRC`.

## Kernel and U-Boot

```bash
devtool modify virtual/kernel
cd build/workspace/sources/linux-vendor
# edit / add a driver / change a Kconfig default
devtool build virtual/kernel
devtool build-image core-image-minimal
devtool finish virtual/kernel ../meta-mycompany
```
Notes:
* Config changes still go through `bitbake virtual/kernel -c menuconfig` +
  `-c diffconfig` → a `.cfg` fragment. Don't commit `.config` from the worktree.
* `devtool finish` on the kernel writes patches next to the `.bbappend` and updates
  `SRC_URI` — review that diff before committing, it can be noisy.
* Same flow works for `virtual/bootloader`.

## EXTERNALSRC — permanent out-of-tree source

For a first-party component whose repo you own, skip fetch/unpack/patch entirely:

```bitbake
# in a local .conf or a dev-only bbappend
INHERIT += "externalsrc"
EXTERNALSRC:pn-myapp = "/home/me/src/myapp"
EXTERNALSRC_BUILD:pn-myapp = "/home/me/src/myapp/build"
```
Caveats:
* Signatures no longer track source content → **BitBake cannot know when to rebuild**.
  `do_compile` is re-run every time, but downstream sstate can go stale. Never use
  `externalsrc` in a release/CI build; pin a `SRCREV` there.
* `EXTERNALSRC_SYMLINKS` controls the convenience symlinks created in `${WORKDIR}`.

## Deploying to a live board

```bash
devtool deploy-target myapp root@192.168.1.10
# needs: sshd on target, matching filesystem writable, dependencies already installed
```
`deploy-target` does *not* install runtime dependencies. If the app needs a new shared
library, build a full image or install the package from a feed instead.

Alternative for package-managed targets:
```bitbake
# build a feed and point the target at it
bitbake package-index
# on target: echo "src/gz mine http://host:8000/ipk/<arch>" >> /etc/opkg/mine.conf
```

## Extensible SDK (eSDK)

```bash
bitbake my-image -c populate_sdk_ext
./tmp/deploy/sdk/<sdk>.sh -d ~/esdk
source ~/esdk/environment-setup-*
devtool add / modify / build      # same commands, no full metadata checkout
devtool sdk-update                # pull newer sstate from SDK_UPDATE_URL
```
Good for app developers who should not carry the whole BSP. Set `SDK_EXT_TYPE = "minimal"`
+ `SDK_UPDATE_URL` so the installer stays small and pulls sstate on demand.

## When devtool is the wrong tool

* Changing a `.conf` / machine / distro setting — just edit the layer.
* One-line patch to a stable recipe — write the `.patch` + `.bbappend` directly.
* Anything in CI — devtool workspaces are developer state, not build inputs.

## Gotchas

* `devtool finish` refuses if the workspace tree has uncommitted changes — commit first.
* `devtool finish` targets the layer that *already* has the recipe/append by default; pass
  the layer path explicitly to control where patches land.
* `devtool reset` without `finish` silently drops your patch generation — your commits are
  still in `workspace/sources/<r>/.git`, but the workspace dir may be reused. Check
  `workspace/attic/`.
* A stale `workspace/appends/*.bbappend` after a manual `rm -rf sources/x` breaks parsing.
  Run `devtool reset -a` to clear everything.
* `devtool upgrade` on a recipe with `SRCREV`+`AUTOREV` behaves oddly; pin first.
