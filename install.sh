#!/usr/bin/env bash
#
# install.sh — one-time setup for the opencode-desktop-latest local repo.
#
# What this does (all changes are idempotent and clearly logged):
#   1. Creates /srv/opencode-local owned by the current user
#      (outside $HOME so pacman's `alpm` sandbox user can read it)
#   2. Adds [opencode-local] to /etc/pacman.conf pointing at /srv/opencode-local
#   3. Adds opencode-desktop-bin / -git to IgnorePkg in /etc/pacman.conf
#      (so paru/pacman never pulls from the AUR anymore)
#   4. Migrates any pre-existing ./repo/ contents from older installs
#   5. Runs ./update.sh to build the current upstream release into the local repo
#   6. Prints the exact pacman command to install/upgrade
#
# Re-running this script is safe.
#

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="${OPENCODE_REPO_DIR:-/srv/opencode-local}"
readonly OLD_REPO_DIR="${SCRIPT_DIR}/repo"
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
err()  { printf "%s✗%s %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
skip() { printf "%s• %s%s\n" "$C_DIM" "$*" "$C_RESET"; }

assert_arch_linux() {
    if [[ ! -f /etc/arch-release ]]; then
        err "This script is for Arch Linux (or derivatives) only."
        exit 1
    fi
    if [[ ! -f "$PACMAN_CONF" ]]; then
        err "$PACMAN_CONF not found — is this really an Arch system?"
        exit 1
    fi
}

assert_not_root() {
    if [[ $EUID -eq 0 ]]; then
        err "Do not run as root. The script will use sudo when needed."
        exit 1
    fi
}

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
    echo "$backup"
}

ensure_repo_dir() {
    if [[ -d "$REPO_DIR" ]]; then
        local owner
        owner=$(stat -c '%U' "$REPO_DIR")
        if [[ "$owner" == "$USER" ]]; then
            skip "$REPO_DIR exists and is owned by $USER"
            return
        fi
        warn "$REPO_DIR exists but is owned by $owner, not $USER"
        if confirm "  Re-chown to $USER:$USER"; then
            sudo chown -R "$USER:$USER" "$REPO_DIR"
            ok "Ownership fixed"
        fi
        return
    fi

    log "Creating $REPO_DIR (outside \$HOME so pacman's alpm user can read it)"
    sudo mkdir -p "$REPO_DIR"
    sudo chown "$USER:$USER" "$REPO_DIR"
    sudo chmod 755 "$REPO_DIR"
    ok "$REPO_DIR ready"
}

migrate_old_repo_if_present() {
    shopt -s nullglob
    local old_pkgs=("${OLD_REPO_DIR}/"*.pkg.tar.zst)
    local old_dbs=("${OLD_REPO_DIR}/${LOCAL_REPO_NAME}".*)
    shopt -u nullglob

    if [[ ${#old_pkgs[@]} -eq 0 && ${#old_dbs[@]} -eq 0 ]]; then
        return
    fi

    log "Migrating ${#old_pkgs[@]} package(s) + db files from ${OLD_REPO_DIR} → ${REPO_DIR}"
    for f in "${old_pkgs[@]}" "${old_dbs[@]}"; do
        [[ -e "$f" ]] || continue
        mv -n "$f" "$REPO_DIR/" 2>/dev/null || {
            sudo mv -n "$f" "$REPO_DIR/" && sudo chown "$USER:$USER" "$REPO_DIR/$(basename "$f")"
        }
    done
    if [[ -d "$OLD_REPO_DIR" ]] && [[ -z "$(ls -A "$OLD_REPO_DIR" 2>/dev/null)" ]]; then
        rmdir "$OLD_REPO_DIR"
        ok "Removed empty $OLD_REPO_DIR"
    fi
    ok "Migration complete"
}

fix_stale_server_url() {
    if ! grep -qE "^Server[[:space:]]*=[[:space:]]*file://${OLD_REPO_DIR}" "$PACMAN_CONF"; then
        return
    fi
    log "Updating stale Server URL in $PACMAN_CONF: ${OLD_REPO_DIR} → ${REPO_DIR}"
    sudo sed -i -E "s|^(Server[[:space:]]*=[[:space:]]*file://)${OLD_REPO_DIR//\//\\/}.*$|\1${REPO_DIR}|" "$PACMAN_CONF"
    ok "Server URL updated"
}

ensure_ignorepkg_entries() {
    local missing=()
    for pkg in "${IGNORE_PKGS[@]}"; do
        if ! grep -qE "^[[:space:]]*IgnorePkg[[:space:]]*=.*\b${pkg}\b" "$PACMAN_CONF"; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        skip "IgnorePkg already includes: ${IGNORE_PKGS[*]}"
        return
    fi

    log "Adding to IgnorePkg: ${missing[*]}"
    if grep -qE "^[[:space:]]*IgnorePkg[[:space:]]*=" "$PACMAN_CONF"; then
        sudo sed -i -E "s|^([[:space:]]*IgnorePkg[[:space:]]*=.*)$|\1 ${missing[*]}|" "$PACMAN_CONF"
    elif grep -qE "^[[:space:]]*#IgnorePkg[[:space:]]*=" "$PACMAN_CONF"; then
        sudo sed -i -E "s|^[[:space:]]*#IgnorePkg[[:space:]]*=.*$|IgnorePkg = ${missing[*]}|" "$PACMAN_CONF"
    else
        echo "IgnorePkg = ${missing[*]}" | sudo tee -a "$PACMAN_CONF" >/dev/null
    fi
    ok "Updated IgnorePkg"
}

ensure_local_repo_section() {
    if grep -qE "^\[${LOCAL_REPO_NAME}\]" "$PACMAN_CONF"; then
        skip "[${LOCAL_REPO_NAME}] already present in $PACMAN_CONF"
        return
    fi

    log "Adding [${LOCAL_REPO_NAME}] repository section to $PACMAN_CONF"
    local block
    block=$(printf '\n[%s]\nSigLevel = Optional TrustAll\nServer = file://%s\n' \
        "$LOCAL_REPO_NAME" "$REPO_DIR")
    printf "%s" "$block" | sudo tee -a "$PACMAN_CONF" >/dev/null
    ok "Repository section added"
}

remove_aur_package_if_installed() {
    if ! pacman -Qq opencode-desktop-bin >/dev/null 2>&1; then
        return
    fi
    warn "The AUR package 'opencode-desktop-bin' is currently installed."
    echo "  It will conflict with the local opencode-desktop package."
    echo "  When you run 'sudo pacman -Syu' below, pacman will offer to replace it."
    echo "  (It's safe — your config in ~/.config/opencode is untouched.)"
}

build_initial_package() {
    log "Building initial package via update.sh..."
    if [[ ! -x "${SCRIPT_DIR}/update.sh" ]]; then
        err "update.sh is not executable. Run: chmod +x update.sh"
        exit 1
    fi
    "${SCRIPT_DIR}/update.sh"
}

print_next_steps() {
    local pkg_count
    pkg_count=$(ls -1 "${REPO_DIR}/opencode-desktop-"*"-x86_64.pkg.tar.zst" 2>/dev/null | wc -l)

    echo
    echo "─────────────────────────────────────────────────────────────────"
    ok "Install complete"
    echo "─────────────────────────────────────────────────────────────────"
    echo
    echo "  Packages available in local repo: ${pkg_count}"
    echo
    echo "  ${C_BLUE}Next:${C_RESET}"
    echo "    sudo pacman -Syu"
    echo
    echo "  pacman will:"
    echo "    • Refresh the local repo database"
    echo "    • Detect opencode-desktop-bin (AUR) is being replaced by opencode-desktop (local)"
    echo "    • Prompt you to confirm the replacement"
    echo
    echo "  ${C_BLUE}Future upgrades:${C_RESET}"
    echo "    ./update.sh && sudo pacman -Syu"
    echo
}

main() {
    assert_arch_linux
    assert_not_root

    echo "This will:"
    echo "  • Create ${REPO_DIR} (owned by $USER)"
    echo "  • Modify $PACMAN_CONF:"
    echo "      - Add [${LOCAL_REPO_NAME}] repository → file://${REPO_DIR}"
    echo "      - Add to IgnorePkg: ${IGNORE_PKGS[*]}"
    if [[ -d "$OLD_REPO_DIR" ]] && ls "$OLD_REPO_DIR"/*.pkg.tar.zst >/dev/null 2>&1; then
        echo "  • Migrate existing packages from ${OLD_REPO_DIR} → ${REPO_DIR}"
    fi
    echo
    if ! confirm "Proceed"; then
        echo "Aborted."
        exit 0
    fi

    backup_pacman_conf >/dev/null
    ensure_repo_dir
    migrate_old_repo_if_present
    ensure_ignorepkg_entries
    ensure_local_repo_section
    fix_stale_server_url
    build_initial_package
    remove_aur_package_if_installed
    print_next_steps
}

main "$@"
