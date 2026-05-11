# opencode-desktop-latest

A local pacman repository that tracks the **latest** [anomalyco/opencode](https://github.com/anomalyco/opencode) desktop releases directly from GitHub — bypassing the AUR which lags behind.

## Why

The AUR `opencode-desktop-bin` package is often days or weeks behind upstream's GitHub releases. This repo gives you a one-command path from "new GitHub release" to "installed via pacman."

```
GitHub release  ─►  ./update.sh  ─►  ./repo/*.pkg.tar.zst  ─►  pacman -Syu  ─►  installed
```

## How it works

```
~/git/opencode-desktop-latest/        ← git-tracked source (~32 KB)
├── PKGBUILD                # Repackages upstream's .deb as an Arch package
├── update.sh               # Queries GitHub → bumps PKGBUILD → makepkg
├── install.sh              # One-time: creates /srv/opencode-local + pacman.conf entries
├── uninstall.sh            # Reverses install.sh
├── README.md
├── .gitignore
└── build/                  # makepkg workspace (gitignored, ~600 MB)

/srv/opencode-local/                  ← built artifacts, alpm-readable (not in git)
├── opencode-local.db.tar.gz
└── opencode-desktop-X.Y.Z-1-x86_64.pkg.tar.zst
```

### Why `/srv/opencode-local/` instead of `./repo/`

Pacman 6.1+ runs downloads as the unprivileged **`alpm` system user** by default (`DownloadUser = alpm` in `/etc/pacman.conf`). This user can't traverse `/home/<you>` (mode 700 on Arch), so a local repo under `~/git/` fails with:

```
error: failed retrieving file 'opencode-local.db' from disk
       : Could not open file /home/<you>/.../opencode-local.db
```

Hosting the built packages at `/srv/opencode-local/` (FHS-blessed path for served data, world-traversable by default) sidesteps the problem cleanly with no permission hacks.

### The PKGBUILD

It doesn't compile anything — it extracts upstream's pre-built `.deb` (same as the AUR `-bin` package) and lays the files into `$pkgdir`. Build takes seconds.

### Override the repo path

If you really want the repo somewhere else, set `OPENCODE_REPO_DIR` in your environment before running `install.sh` / `update.sh`. The default (`/srv/opencode-local`) is recommended.

## Cross-machine setup

The whole repo is only **~32 KB** of source — all the heavyweight artifacts live in `/srv/opencode-local/` (built by `update.sh`) and `~/git/opencode-desktop-latest/build/` (makepkg workspace), both gitignored. Cloning is fast.

```bash
git clone git@github-personal:BrentJMaxwell/opencode-desktop-latest.git ~/git/opencode-desktop-latest
cd ~/git/opencode-desktop-latest
./install.sh                # creates /srv/opencode-local/, updates pacman.conf
sudo pacman -Syu
```

> The `github-personal` SSH alias is defined in `~/.ssh/config` and forces use of `~/.ssh/id_ed25519_personal`. On a fresh machine, make sure that key is present and the corresponding public key is registered on the `BrentJMaxwell` GitHub account.

### Migrating from an older install

If you have an existing install with the repo at `~/git/opencode-desktop-latest/repo/`, just run `./install.sh` again. It detects the old layout, moves the packages to `/srv/opencode-local/`, and updates the `Server = file://...` line in `/etc/pacman.conf` automatically.

Each machine builds its own `.pkg.tar.zst` into its own local `./repo/` — the built artifacts are **not** shared via git because:
- The `sha256sum` in `PKGBUILD` is portable (it's the hash of upstream's `.deb`, identical on every machine)
- Build time is ~5 seconds, so there's no real benefit to syncing binaries
- Keeping binaries out of git means the repo stays small and clones stay fast

### What .gitignore excludes

```
build/                 # makepkg workspace + extracted Electron app
repo/                  # built .pkg.tar.zst and the local pacman db
*.pkg.tar.zst          # belt-and-braces
*.pkg.tar.zst.sig
*.log
src/ pkg/              # makepkg's default in-tree dirs if BUILDDIR/PKGDEST aren't set
```

The committed `PKGBUILD` carries the **last known version + sha256** as a sensible starting point; `./update.sh` on the new machine immediately reconciles it with the current GitHub release.

## Setup (one time)

```bash
cd ~/git/opencode-desktop-latest
./install.sh
sudo pacman -Syu        # pacman will offer to replace opencode-desktop-bin (AUR)
                        # with opencode-desktop (local). Accept.
```

`install.sh` will:
- Add `[opencode-local]` to `/etc/pacman.conf` (file-based, no daemon)
- Add `opencode-desktop-bin` and `opencode-desktop-git` to `IgnorePkg` (so the AUR version is never auto-upgraded again)
- Run `./update.sh` to seed the local repo with the current upstream release
- Back up your `pacman.conf` to `pacman.conf.backup-<timestamp>` first

## About the existing AUR install

**You do not need to manually uninstall `opencode-desktop-bin` before running `./install.sh`.**

The PKGBUILD declares:
```
provides=('opencode-desktop')
conflicts=('opencode-desktop-bin' 'opencode-desktop-git')
replaces=('opencode-desktop-bin' 'opencode-desktop-git')
```

So `sudo pacman -Syu` will detect the AUR version, swap it out atomically, and install the local one in a single transaction.

### What happens during the swap

| Step | State |
|---|---|
| Before | `opencode-desktop-bin <old version>` from AUR installed |
| After `./install.sh` | AUR pkg still installed. Local repo has new pkg waiting. `pacman.conf` updated. |
| During `sudo pacman -Syu` | Pacman prompts: *"opencode-desktop-bin will be replaced by opencode-local/opencode-desktop. Continue? [Y/n]"* → answer **Y** |
| After | `opencode-desktop <new version>` from local repo installed. AUR pkg fully removed. |

### What's preserved across the swap

| Thing | Status |
|---|---|
| `~/.config/opencode/` (settings, sessions, plans) | ✅ Untouched (user data, not package files) |
| `~/.opencode/` if present | ✅ Untouched |
| Desktop launcher / `.desktop` entry | ✅ Replaced 1:1, same name and path |
| `/usr/bin/opencode-desktop` symlink | ✅ Replaced 1:1 |

### If you prefer the manual route

You *can* uninstall the AUR pkg first if you want a clean two-step flow, but there's no functional benefit — pacman's atomic swap during `-Syu` is actually safer (no window where opencode is uninstalled).

```bash
paru -Rns opencode-desktop-bin     # only if you really want to do it manually
cd ~/git/opencode-desktop-latest
./install.sh
sudo pacman -Syu
```

## Daily use

When a new release lands on GitHub:

```bash
cd ~/git/opencode-desktop-latest
./update.sh
sudo pacman -Syu          # or: paru
```

That's it. `update.sh` is a no-op if you're already up to date.

## update.sh flags

| Flag | Meaning |
|---|---|
| *(none)* | Check upstream, build if newer than what's in `./repo/`, register in repo |
| `--check` | Check only — print whether an update is available, no build |
| `--force` | Rebuild even if version matches (useful if PKGBUILD was edited) |
| `--quiet` | Suppress informational output, keep errors |

## Uninstall

```bash
./uninstall.sh
```

Removes the pacman.conf changes, optionally uninstalls the package, optionally deletes the local repo files. After this you can return to the AUR with `paru -S opencode-desktop-bin` if desired.

## Troubleshooting

**`pacman -Syu` doesn't see the new version**
You forgot to run `./update.sh` first. Or run `./update.sh --force` to rebuild and re-register.

**"file is owned by opencode-desktop-bin and opencode-desktop"**
The replacement didn't go through. Run: `sudo pacman -Rdd opencode-desktop-bin && sudo pacman -S opencode-desktop`

**The .deb URL changed (404 on download)**
Upstream renamed an asset. Edit `DEB_ASSET` in `update.sh` to the new filename.

**Need to pin to a specific version**
Edit `PKGBUILD` directly (`pkgver=X.Y.Z`), then `./update.sh --force`. Beware: the next `./update.sh` without `--force` will bump to the latest again.

## Why repackage the `.deb` instead of building from source

Tradeoffs were considered:

| | Repackage `.deb` *(chosen)* | Build from source |
|---|---|---|
| Build time | ~5 seconds | 5–15+ minutes (Electron + Vite + native modules) |
| Build deps | `bsdtar`, `curl` | `bun`, `node`, `electron`, native build tools |
| Reproducibility | Identical to upstream's release artifact | Depends on local toolchain matching theirs |
| Network | ~150 MB | ~500 MB+ (node_modules, electron binaries) |
| Patching ability | None | Full |

For this use case — staying current with upstream — the `.deb` is the right trade. If you ever need to patch the source, you can fork the PKGBUILD and replace the `package()` function with a source build.
