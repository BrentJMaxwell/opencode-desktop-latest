# Maintainer: brent <brent@local>
# This PKGBUILD repackages the official upstream .deb from anomalyco/opencode
# into a native Arch package. Version and checksum are managed by update.sh.

pkgname=opencode-desktop
pkgver=1.14.48
pkgrel=1
pkgdesc="OpenCode AI desktop client (latest, repackaged from upstream .deb)"
arch=('x86_64')
url="https://github.com/anomalyco/opencode"
license=('MIT')
depends=(
    'gtk3'
    'nss'
    'libxss'
    'libxtst'
    'alsa-lib'
    'libsecret'
    'libnotify'
    'xdg-utils'
    'at-spi2-core'
)
optdepends=(
    'libappindicator-gtk3: system tray icon support'
)
provides=('opencode-desktop')
conflicts=('opencode-desktop-bin' 'opencode-desktop-git')
replaces=('opencode-desktop-bin' 'opencode-desktop-git')
options=('!strip' '!debug' '!emptydirs')
source=("opencode-desktop-${pkgver}.deb::https://github.com/anomalyco/opencode/releases/download/v${pkgver}/opencode-desktop-linux-amd64.deb")
sha256sums=('2be86127041b1f4a8553bf168fab7ded46f690dcbe5f36496644301db6609816')
noextract=("opencode-desktop-${pkgver}.deb")

package() {
    cd "$srcdir"

    # Extract the .deb: ar archive containing data.tar.xz
    bsdtar -xf "opencode-desktop-${pkgver}.deb"

    # Unpack data payload directly into $pkgdir
    bsdtar -xf data.tar.xz -C "$pkgdir"

    # Upstream .deb does not provide a /usr/bin entry — add one matching AUR convention
    install -d "$pkgdir/usr/bin"
    ln -sf "/opt/OpenCode/@opencode-aidesktop" "$pkgdir/usr/bin/opencode-desktop"

    # Ensure correct permissions on Electron binaries
    if [ -f "$pkgdir/opt/OpenCode/@opencode-aidesktop" ]; then
        chmod 755 "$pkgdir/opt/OpenCode/@opencode-aidesktop"
    fi
    # chrome-sandbox requires setuid root for Electron's sandbox
    if [ -f "$pkgdir/opt/OpenCode/chrome-sandbox" ]; then
        chmod 4755 "$pkgdir/opt/OpenCode/chrome-sandbox"
    fi
}
