#!/usr/bin/env bash
#
# uninstall.sh — reverses install.sh.
#
# Removes the [opencode-local] section and IgnorePkg entries from
# /etc/pacman.conf, optionally uninstalls the package, and optionally
# deletes the local repo files.
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="${SCRIPT_DIR}/repo"
readonly BUILD_DIR="${SCRIPT_DIR}/build"
readonly PACMAN_CONF="/etc/pacman.conf"
readonly LOCAL_REPO_NAME="opencode-local"
readonly IGNORE_PKGS=("opencode-desktop-bin" "opencode-desktop-git")

if [[ -t 1 ]]; then
    C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
    C_RED=$'\033[1;31m';  C_DIM=$'\033[2m';     C_RESET=$'\033[0m'
else
    C_BLUE=; C_GREEN=; C_YELLOW=; C_RED=; C_DIM=; C_RESET=
fi
log()  { printf "%s▸%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf "%s✓%s %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%s⚠%s %s\n" "$C_YELLOW" "$C_RESET" "$*" >&2; }
skip() { printf "%s• %s%s\n" "$C_DIM" "$*" "$C_RESET"; }

confirm() {
    local prompt="$1"
    read -r -p "$(printf "%s? %s[y/N]%s " "$prompt" "$C_DIM" "$C_RESET")" answer
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

backup_pacman_conf() {
    local ts backup
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="${PACMAN_CONF}.backup-${ts}"
    log "Backing up $PACMAN_CONF → $backup"
    sudo cp "$PACMAN_CONF" "$backup"
}

remove_local_repo_section() {
    if ! grep -qE "^\[${LOCAL_REPO_NAME}\]" "$PACMAN_CONF"; then
        skip "[${LOCAL_REPO_NAME}] not present in $PACMAN_CONF"
        return
    fi
    log "Removing [${LOCAL_REPO_NAME}] section from $PACMAN_CONF"
    sudo sed -i -E "/^\[${LOCAL_REPO_NAME}\]/,/^\[/{/^\[${LOCAL_REPO_NAME}\]/d;/^SigLevel|^Server/d;/^[[:space:]]*$/d}" "$PACMAN_CONF"
    ok "Repository section removed"
}

remove_ignorepkg_entries() {
    local has_any=0
    for pkg in "${IGNORE_PKGS[@]}"; do
        if grep -qE "^[[:space:]]*IgnorePkg[[:space:]]*=.*\b${pkg}\b" "$PACMAN_CONF"; then
            has_any=1
            break
        fi
    done
    if [[ $has_any -eq 0 ]]; then
        skip "No matching IgnorePkg entries present"
        return
    fi

    log "Removing from IgnorePkg: ${IGNORE_PKGS[*]}"
    for pkg in "${IGNORE_PKGS[@]}"; do
        sudo sed -i -E "s|([[:space:]]*IgnorePkg[[:space:]]*=[^#]*)\b${pkg}\b[[:space:]]?|\1|g" "$PACMAN_CONF"
    done
    sudo sed -i -E "s|^([[:space:]]*IgnorePkg[[:space:]]*=)[[:space:]]*$|#\1|" "$PACMAN_CONF"
    ok "IgnorePkg entries removed"
}

main() {
    if [[ $EUID -eq 0 ]]; then
        warn "Do not run as root."
        exit 1
    fi

    echo "This will:"
    echo "  • Remove [${LOCAL_REPO_NAME}] from $PACMAN_CONF"
    echo "  • Remove from IgnorePkg: ${IGNORE_PKGS[*]}"
    echo "  • The local repo files at ${REPO_DIR} are left alone (delete manually if desired)"
    echo
    if ! confirm "Proceed"; then
        echo "Aborted."
        exit 0
    fi

    backup_pacman_conf
    remove_local_repo_section
    remove_ignorepkg_entries

    echo
    if pacman -Qq opencode-desktop >/dev/null 2>&1; then
        if confirm "Also uninstall the local 'opencode-desktop' package now"; then
            sudo pacman -Rns opencode-desktop
        fi
    fi

    if [[ -d "$REPO_DIR" || -d "$BUILD_DIR" ]]; then
        if confirm "Delete local build/ and repo/ directories"; then
            rm -rf "$BUILD_DIR" "$REPO_DIR"
            ok "Local files removed"
        fi
    fi

    echo
    ok "Uninstall complete. To restore the AUR version: paru -S opencode-desktop-bin"
}

main "$@"
