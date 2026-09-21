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
# Install only furo and sphinx-basic-ng (its sole non-system dep) without
# pulling in Sphinx or other packages already provided by apt.  Mixing a
# pip-bundled Sphinx with the system's sphinx_inline_tabs causes API
# incompatibilities; --no-deps avoids that conflict.
pip install --no-deps --target="${WORK_DIR}/pip-packages" furo sphinx-basic-ng accessible-pygments

# Bundle a newer docutils.
# kitty's docs/conf.py imports docutils.parsers.rst.roles.normalize_options,
# which was only added in docutils 0.23; Noble ships 0.20.1. --no-deps avoids
# pulling in a newer Sphinx that would conflict with the system one.
echo "==> Bundling newer docutils..."
pip install --no-deps --target="${WORK_DIR}/pip-packages" 'docutils>=0.22'

tar -czf "${EXPECTED_DIR}/debian/pip-packages.tar.gz" \
    -C "${WORK_DIR}" pip-packages/

# Bundle the shader slang compiler (slangc).
# kitty 0.49.0 added support for custom shaders, which requires slangc to
# compile the built-in default shaders at build time. It is not packaged for
# Ubuntu, so we download the prebuilt release pinned in kitty's own
# bypy/sources.json and ship it in debian/slang.tar.gz; debian/rules extracts
# it and points SLANGC at the bundled binary. We drop libslang-llvm.so (LLVM
# backend, ~150MB) and libgfx.so (GPU API runtime) since kitty only uses
# slangc to compile to GLSL/SPIR-V text, not to run compiled shaders.
echo "==> Bundling shader slang compiler..."
SLANG_VERSION=$(python3 -c "
import json
with open('${EXPECTED_DIR}/bypy/sources.json') as f:
    for dep in json.load(f):
        if dep['name'].startswith('slang '):
            print(dep['name'].split()[-1])
            break
")
echo "    shader-slang ${SLANG_VERSION}"
mkdir -p "${WORK_DIR}/slang-bundle/slang"
curl -fL \
    "https://github.com/shader-slang/slang/releases/download/v${SLANG_VERSION}/slang-${SLANG_VERSION}-linux-x86_64.tar.gz" \
    -o "${WORK_DIR}/slang.tar.gz"
tar -xzf "${WORK_DIR}/slang.tar.gz" -C "${WORK_DIR}/slang-bundle/slang" bin lib
rm -f "${WORK_DIR}/slang-bundle/slang/lib/libslang-llvm.so" \
    "${WORK_DIR}/slang-bundle/slang/lib/libgfx.so"*
tar -czf "${EXPECTED_DIR}/debian/slang.tar.gz" \
    -C "${WORK_DIR}/slang-bundle" slang/

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
