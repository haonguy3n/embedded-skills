# devtool & fast iteration

Plain `bitbake` wipes `${S}` on every `do_unpack`. `devtool` gives you a persistent git
worktree that BitBake builds from.

## The core loop

```bash
devtool modify <recipe>                 # extract source to workspace/sources/<recipe>
cd build/workspace/sources/<recipe>
devtool build <recipe>                  # == bitbake <recipe> -c populate_sysroot
devtool deploy-target <recipe> root@192.168.1.10
git add -A && git commit -s -m "subsys: do the thing"
devtool finish <recipe> ../meta-mycompany              # write patches back, leave workspace
```

`devtool modify` turns each existing `SRC_URI` patch into a **git commit**, so rebasing a patch
stack onto a new version is `git rebase` and `devtool finish` regenerates the patch files. This
is the correct way to maintain a patch stack.

## Subcommands

| Command | What it does |
|---|---|
| `devtool add <name> <srctree> [<fetchuri>]` | new recipe from a tree/URL; auto-detects build system, licence, deps |
| `devtool add --binary` | package a prebuilt tree |
| `devtool modify <recipe> [<srctree>]` | check out an existing recipe's source; `-x` extract, `-n` skip patch application |
| `devtool upgrade <recipe> -V <ver> [-S <srcrev>]` | bump version, rebase patches |
| `devtool build <recipe>` | build it |
| `devtool build-image <image>` | build an image **including** workspace content |
| `devtool deploy-target <recipe> user@host[:destdir]` | rsync `${D}` onto a running target over SSH (bypasses the package manager) |
| `devtool undeploy-target <recipe> user@host` | undo that |
| `devtool finish <recipe> <layer>` | update recipe/append in `<layer>` from your commits, then reset (`--no-clean` / `--remove-work` control cleanup) |
| `devtool reset <recipe>` | drop from workspace (modified files preserved in `workspace/attic/`) |
| `devtool status` | what's in the workspace |
| `devtool edit-recipe <recipe>` | open the workspace recipe in `$EDITOR` |
| `devtool search <keyword>` | find recipes by name/description/shipped file |
| `devtool check-upgrade-status` | which recipes have newer upstream releases |
| `devtool ide-sdk <recipe> <image> --target user@host` | VS Code / gdb config + SDK |
| `devtool sdk-install <recipe>` / `sdk-update` | eSDK only |
| `devtool create-workspace <path>` | put the workspace layer somewhere specific |

## Workspace layout

```
build/workspace/
├── conf/layer.conf
├── appends/<recipe>.bbappend      # points EXTERNALSRC at sources/<recipe>
├── recipes/<recipe>/<recipe>.bb   # only for `devtool add`/`upgrade`
├── sources/<recipe>/              # your git worktree
└── attic/                         # rescued files from `devtool reset`
```
A real layer, auto-added to `BBLAYERS`. Nothing is magic — the appends just set `EXTERNALSRC`.

## Kernel and U-Boot

```bash
devtool modify virtual/kernel        # or virtual/bootloader
cd build/workspace/sources/linux-vendor
devtool build virtual/kernel
devtool build-image core-image-minimal
devtool finish virtual/kernel ../meta-mycompany
```
* Config changes still go through `-c menuconfig` + `-c diffconfig` → a `.cfg` fragment (see
  `kernel.md`). Don't commit `.config` from the worktree.
* `devtool finish` on the kernel writes patches next to the `.bbappend` and updates `SRC_URI`
  — review that diff, it can be noisy.

## EXTERNALSRC — permanent out-of-tree source

```bitbake
# in a local .conf or a dev-only bbappend
INHERIT += "externalsrc"
EXTERNALSRC:pn-myapp = "/home/me/src/myapp"
EXTERNALSRC_BUILD:pn-myapp = "/home/me/src/myapp/build"
```
* Signatures no longer track source content → **BitBake cannot know when to rebuild**.
  `do_compile` re-runs every time, but downstream sstate can go stale. Never use `externalsrc`
  in a release/CI build; pin a `SRCREV` there.
* `EXTERNALSRC_SYMLINKS` controls the convenience symlinks in `${WORKDIR}`.

## Deploying to a live board

`deploy-target` needs sshd on the target and a writable filesystem, and does **not** install
runtime dependencies. If the app needs a new shared library, build a full image or install from
a feed:
```bash
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
For app developers who should not carry the whole BSP. Set `SDK_EXT_TYPE = "minimal"` +
`SDK_UPDATE_URL` so the installer stays small.

## When devtool is the wrong tool

* Changing a `.conf` / machine / distro setting — edit the layer.
* One-line patch to a stable recipe — write the `.patch` + `.bbappend` directly.
* Anything in CI — workspaces are developer state, not build inputs.

## Gotchas

* `devtool finish` refuses on an uncommitted worktree — commit first.
* `devtool finish` defaults to the layer that already has the recipe/append; pass the layer
  path explicitly to control where patches land.
* `devtool reset` without `finish` drops your patch generation. Commits survive in
  `workspace/sources/<r>/.git`; check `workspace/attic/`.
* A stale `workspace/appends/*.bbappend` after a manual `rm -rf sources/x` breaks parsing —
  `devtool reset -a`.
* `devtool upgrade` on a recipe with `SRCREV`+`AUTOREV` behaves oddly; pin first.
