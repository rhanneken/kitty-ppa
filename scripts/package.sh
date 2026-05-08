#!/usr/bin/env bash
set -euo pipefail

KITTY_VERSION="${KITTY_VERSION:?KITTY_VERSION must be set}"
GPG_KEY_ID="${GPG_KEY_ID:-2722591F921E292C948419835A34B1A5CFB6BF30}"
DISTRO="${DISTRO:-noble}"
PPA_REVISION="${PPA_REVISION:-ppa1}"

PACKAGE_VERSION="${KITTY_VERSION}-0~${PPA_REVISION}~${DISTRO}1"
ORIG_TARBALL="kitty_${KITTY_VERSION}.orig.tar.gz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"

echo "==> Working directory: $WORK_DIR"
cd "$WORK_DIR"

# Download upstream tarball
echo "==> Downloading kitty ${KITTY_VERSION}..."
curl -fL \
    "https://github.com/kovidgoyal/kitty/archive/refs/tags/v${KITTY_VERSION}.tar.gz" \
    -o "${ORIG_TARBALL}"

# Extract and locate source directory
echo "==> Extracting..."
tar xf "${ORIG_TARBALL}"

SOURCE_DIR=""
for candidate in "kitty-${KITTY_VERSION}" "kitty-v${KITTY_VERSION}"; do
    if [ -d "$candidate" ]; then
        SOURCE_DIR="$candidate"
        break
    fi
done
if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR=$(find . -maxdepth 1 -type d -name 'kitty*' | head -1)
fi
if [ -z "$SOURCE_DIR" ]; then
    echo "ERROR: cannot locate extracted kitty source directory" >&2
    exit 1
fi
# debuild requires the directory to be named <package>-<upstream-version>
EXPECTED_DIR="kitty-${KITTY_VERSION}"
if [ "$SOURCE_DIR" != "$EXPECTED_DIR" ]; then
    mv "$SOURCE_DIR" "$EXPECTED_DIR"
fi

echo "==> Source directory: $EXPECTED_DIR"

# Copy debian/ into the source tree (without changelog; we generate it fresh)
echo "==> Copying debian/..."
cp -r "${REPO_DIR}/debian" "${EXPECTED_DIR}/"

# Vendor Go module dependencies.
# Launchpad's build environment has no network access, so we download all
# modules here and bundle them into debian/vendor.tar.gz so the build can
# use -mod=vendor without touching the network.
echo "==> Vendoring Go modules..."
cd "${EXPECTED_DIR}"
GOMODCACHE="${WORK_DIR}/go-mod-cache" GOFLAGS="" go mod vendor
tar -czf debian/vendor.tar.gz vendor/
rm -rf vendor/
cd "${WORK_DIR}"

# Download the latest SymbolsNerdFontMono font for add_builtin_fonts.
# setup.py uses fc-list to find it on the build host, but Launchpad's build
# environment has no Nerd Fonts package, so we pre-place it in debian/fonts/
# and copy it into position in debian/rules before setup.py runs.
echo "==> Fetching latest Symbols NERD Font Mono..."
NERDFONT_TAG=$(curl -fsSL \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
    "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
echo "    nerd-fonts ${NERDFONT_TAG}"
mkdir -p "${EXPECTED_DIR}/debian/fonts"
curl -fL \
    "https://github.com/ryanoasis/nerd-fonts/raw/${NERDFONT_TAG}/patched-fonts/NerdFontsSymbolsOnly/SymbolsNerdFontMono-Regular.ttf" \
    -o "${EXPECTED_DIR}/debian/fonts/SymbolsNerdFontMono-Regular.ttf"

# Bundle the furo Sphinx theme and its dependencies.
# Launchpad has no network access, so we pre-install furo here and ship it
# in debian/pip-packages.tar.gz; debian/rules extracts it and adds it to
# PYTHONPATH so sphinx-build can build the HTML docs.
echo "==> Bundling furo Sphinx theme..."
pip install --target="${WORK_DIR}/pip-packages" furo
tar -czf "${EXPECTED_DIR}/debian/pip-packages.tar.gz" \
    -C "${WORK_DIR}" pip-packages/

# Generate a fresh changelog for this version
echo "==> Generating debian/changelog..."
cd "${EXPECTED_DIR}"
DEBEMAIL="rhanneken@pobox.com" \
DEBFULLNAME="Russell Hanneken" \
dch --create \
    --package kitty \
    --newversion "${PACKAGE_VERSION}" \
    --distribution "${DISTRO}" \
    "New upstream release ${KITTY_VERSION}."

# Build the signed source package.
# Include the orig tarball (-sa) only for ppa1; on re-uploads (ppa2+) the
# orig is already in Launchpad's file pool and re-uploading it causes rejection.
echo "==> Building source package (version ${PACKAGE_VERSION})..."
if [ "${PPA_REVISION}" = "ppa1" ]; then
    ORIG_FLAG="-sa"
else
    ORIG_FLAG="-sd"
fi
debuild -S "${ORIG_FLAG}" -d -k"${GPG_KEY_ID}"

# Upload to Launchpad
echo "==> Uploading to Launchpad..."
cd "$WORK_DIR"
dput --config "${REPO_DIR}/dput.cf" kitty-ppa \
    "kitty_${PACKAGE_VERSION}_source.changes"

echo "==> Done. kitty ${KITTY_VERSION} submitted to ppa:rhanneken/kitty."
