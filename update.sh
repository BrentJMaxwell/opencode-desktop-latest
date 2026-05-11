#!/usr/bin/env bash
#
# update.sh — pulls the latest opencode-desktop release from GitHub, builds an
# Arch package, and adds it to the local pacman repo.
#
# Run this first, then `sudo pacman -Syu` (or `paru`) to upgrade.
#
# Usage:
#   ./update.sh              # check + build if new version
#   ./update.sh --force      # rebuild even if version matches
#   ./update.sh --check      # check only, don't build
#   ./update.sh --quiet      # less verbose
#

set -euo pipefail

readonly REPO_OWNER="anomalyco"
readonly REPO_NAME="opencode"
readonly DEB_ASSET="opencode-desktop-linux-amd64.deb"
readonly PKG_NAME="opencode-desktop"
readonly LOCAL_REPO_NAME="opencode-local"
readonly KEEP_OLD_VERSIONS=3
readonly REQUIRED_CMDS=(curl makepkg repo-add bsdtar sha256sum sed grep flock)

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PKGBUILD_PATH="${SCRIPT_DIR}/PKGBUILD"
readonly REPO_DIR="${SCRIPT_DIR}/repo"
readonly BUILD_DIR="${SCRIPT_DIR}/build"
readonly SRC_CACHE="${BUILD_DIR}/src-cache"
readonly LOCK_FILE="/tmp/opencode-desktop-latest.lock"

FORCE=0
CHECK_ONLY=0
QUIET=0

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --force)   FORCE=1 ;;
            --check)   CHECK_ONLY=1 ;;
            --quiet)   QUIET=1 ;;
            --help|-h) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *)         echo "Unknown flag: $arg" >&2; exit 2 ;;
        esac
    done
}

init_colors() {
    if [[ -t 1 ]]; then
        C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
        C_RED=$'\033[1;31m';  C_DIM=$'\033[2m';     C_RESET=$'\033[0m'
    else
        C_BLUE=; C_GREEN=; C_YELLOW=; C_RED=; C_DIM=; C_RESET=
    fi
}

log()   { [[ $QUIET -eq 1 ]] && return 0; printf "%s▸%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf "%s✓%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf "%s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf "%s✗%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
debug() { [[ $QUIET -eq 1 ]] && return 0; printf "%s  %s%s\n" "$C_DIM" "$*" "$C_RESET"; }

require_tools() {
    local missing=()
    for cmd in "${REQUIRED_CMDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required commands: ${missing[*]}"
        err "Install with: sudo pacman -S --needed base-devel libarchive curl"
        exit 1
    fi
}

acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        err "Another update.sh instance is already running (lock: $LOCK_FILE)"
        exit 1
    fi
}

fetch_latest_version() {
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh release view --repo "${REPO_OWNER}/${REPO_NAME}" --json tagName -q .tagName
    else
        curl -fsSL "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
            | grep -m1 '"tag_name"' \
            | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
    fi
}

read_pkgbuild_version() {
    grep -E '^pkgver=' "$PKGBUILD_PATH" | head -1 | cut -d= -f2 | tr -d '"' || echo "0"
}

built_pkg_exists_for_version() {
    local version="$1"
    shopt -s nullglob
    local matches=("${REPO_DIR}/${PKG_NAME}-${version}-"*"-x86_64.pkg.tar.zst")
    shopt -u nullglob
    [[ ${#matches[@]} -gt 0 ]]
}

bump_pkgbuild_version() {
    local new_ver="$1"
    sed -i -E "s/^pkgver=.*/pkgver=${new_ver}/" "$PKGBUILD_PATH"
    sed -i -E "s/^pkgrel=.*/pkgrel=1/" "$PKGBUILD_PATH"
}

set_pkgbuild_checksum() {
    local sum="$1"
    sed -i -E "s/^sha256sums=.*/sha256sums=('${sum}')/" "$PKGBUILD_PATH"
}

download_deb_if_needed() {
    local version="$1" target="$2"
    if [[ -f "$target" && $FORCE -eq 0 ]]; then
        debug "Using cached: $target"
        return
    fi
    local url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/v${version}/${DEB_ASSET}"
    log "Downloading ${DEB_ASSET}..."
    curl -fL --progress-bar -o "$target.tmp" "$url"
    mv "$target.tmp" "$target"
}

build_package() {
    log "Building Arch package (makepkg)..."
    cd "$SCRIPT_DIR"
    BUILDDIR="$BUILD_DIR" PKGDEST="$REPO_DIR" SRCDEST="$SRC_CACHE" \
        makepkg -f --noconfirm --noprogressbar --skippgpcheck 2>&1 \
        | sed "s/^/  ${C_DIM}|${C_RESET} /"
}

register_in_local_repo() {
    local pkg_file="$1"
    log "Registering in local repo '${LOCAL_REPO_NAME}'..."
    cd "$REPO_DIR"
    repo-add --new --remove --quiet "${LOCAL_REPO_NAME}.db.tar.gz" "$(basename "$pkg_file")" >/dev/null
}

prune_old_packages() {
    local count
    count=$(ls -1 "${REPO_DIR}/${PKG_NAME}-"*"-x86_64.pkg.tar.zst" 2>/dev/null | wc -l)
    if [[ $count -le $KEEP_OLD_VERSIONS ]]; then
        return
    fi
    local to_delete=$((count - KEEP_OLD_VERSIONS))
    log "Pruning ${to_delete} old package(s), keeping last ${KEEP_OLD_VERSIONS}..."
    ls -1t "${REPO_DIR}/${PKG_NAME}-"*"-x86_64.pkg.tar.zst" \
        | tail -n +$((KEEP_OLD_VERSIONS + 1)) \
        | while read -r old; do
            debug "Removing $(basename "$old")"
            rm -f "$old" "${old}.sig" 2>/dev/null || true
        done
}

main() {
    parse_args "$@"
    init_colors
    require_tools
    acquire_lock

    log "Querying GitHub for latest release of ${REPO_OWNER}/${REPO_NAME}..."
    local latest_tag latest_ver current_ver
    latest_tag="$(fetch_latest_version)"
    if [[ -z "$latest_tag" ]]; then
        err "Could not determine latest release tag"
        exit 1
    fi
    latest_ver="${latest_tag#v}"
    if [[ ! "$latest_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        err "Unexpected version format: $latest_ver"
        exit 1
    fi
    current_ver="$(read_pkgbuild_version)"

    debug "Upstream:  v${latest_ver}"
    debug "PKGBUILD:  v${current_ver}"

    if [[ "$current_ver" == "$latest_ver" ]] && built_pkg_exists_for_version "$latest_ver" && [[ $FORCE -eq 0 ]]; then
        ok "Already up to date: v${latest_ver}"
        debug "Package exists in repo. Run 'sudo pacman -Syu' if not yet installed."
        exit 0
    fi

    if [[ $CHECK_ONLY -eq 1 ]]; then
        if [[ "$current_ver" == "$latest_ver" ]] && built_pkg_exists_for_version "$latest_ver"; then
            ok "Up to date (v${latest_ver})"
        else
            warn "Update available: v${current_ver} → v${latest_ver}"
            echo "Run: ./update.sh"
        fi
        exit 0
    fi

    log "Updating PKGBUILD to v${latest_ver}..."
    bump_pkgbuild_version "$latest_ver"

    mkdir -p "$SRC_CACHE" "$REPO_DIR"
    local cached_deb="${SRC_CACHE}/opencode-desktop-${latest_ver}.deb"
    download_deb_if_needed "$latest_ver" "$cached_deb"

    local sha256
    sha256="$(sha256sum "$cached_deb" | cut -d' ' -f1)"
    debug "SHA256: $sha256"
    set_pkgbuild_checksum "$sha256"

    build_package

    local built_pkg
    built_pkg=$(ls -t "${REPO_DIR}/${PKG_NAME}-${latest_ver}-"*"-x86_64.pkg.tar.zst" 2>/dev/null | head -1 || true)
    if [[ -z "$built_pkg" ]]; then
        err "Build did not produce a package in $REPO_DIR"
        exit 1
    fi
    ok "Built: $(basename "$built_pkg")"

    register_in_local_repo "$built_pkg"
    prune_old_packages

    echo
    ok "Local repo updated to v${latest_ver}"
    echo
    echo "  Next step: ${C_BLUE}sudo pacman -Syu${C_RESET}  (or ${C_BLUE}paru${C_RESET})"
    echo "  This will install/upgrade ${PKG_NAME} from your local repo."
}

main "$@"
