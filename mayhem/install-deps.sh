#!/usr/bin/env bash
# Runs as root at image build time (online). Nix needs newer tools than Debian trixie ships:
# clang>=21 (C++ `#embed`), boost>=1.90 (boost/compat), libcurl>=8.17, libblake3>=1.8.2, meson>=1.8, and a
# PIC rapidcheck. Everything not in apt is built from a sha256-pinned tarball into a fixed,
# $HOME-independent prefix under /opt/toolchains, so the offline build.sh re-run resolves it from the image.
set -euxo pipefail

PREFIX=/opt/toolchains/nix-deps
BOOST_VER=1.90.0 ; BOOST_SHA=49551aff3b22cbc5c5a9ed3dbc92f0e23ea50a0f7325b0d198b705e8ee3fc305
CURL_VER=8.17.0  ; CURL_SHA=955f6e729ad6b3566260e8fef68620e76ba3c31acf0a18524416a185acf77992
BLAKE3_VER=1.8.2 ; BLAKE3_SHA=6b51aefe515969785da02e87befafc7fdc7a065cd3458cf1141f29267749e81f
RC_REV=2c3c4365aca21ef4e612768fdc95b1ce8b39a651 ; RC_SHA=d7c87d2a728b9cd7adec09aed44f34938cd1b0928b373f9b490c5b2f6d5ab9dc
MESON_VER=1.8.2

[ -n "${SOURCE_DATE_EPOCH:-}" ] && repro-sources-list.sh || true
apt-get update
apt-get install -yq --no-install-recommends \
  bison flex busybox-static bzip2 ca-certificates curl jq xz-utils \
  libarchive-dev libbrotli-dev libbz2-dev libcpuid-dev libgc-dev libgit2-dev libgmock-dev libgtest-dev \
  liblowdown-dev liblzma-dev libreadline-dev libseccomp-dev libsodium-dev libsqlite3-dev libssl-dev \
  libzstd-dev nlohmann-json3-dev libtoml11-dev python3-pip python3-venv zlib1g-dev \
  clang-22 libclang-rt-22-dev
rm -rf /var/lib/apt/lists/*
# Upstream's `#embed "schema.sql"` inside a std::string initializer only compiles with clang>=21; keep the
# compiler reachable by name (`clang`/`clang++`, as the base's CC/CXX and rlenv's ccache expect).
ln -sf /usr/bin/clang-22 /usr/local/bin/clang
ln -sf /usr/bin/clang++-22 /usr/local/bin/clang++

mkdir -p "$PREFIX"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
J=$(nproc)

python3 -m venv "$PREFIX/venv"
"$PREFIX/venv/bin/pip" install --no-cache-dir "meson==$MESON_VER"
ln -sf "$PREFIX/venv/bin/meson" /usr/local/bin/meson

fetch() { curl -sSLf --retry 5 -o "$W/$1" "$2"; echo "$3  $W/$1" | sha256sum -c -; }

fetch blake3.tgz "https://github.com/BLAKE3-team/BLAKE3/archive/refs/tags/$BLAKE3_VER.tar.gz" "$BLAKE3_SHA"
tar -C "$W" -xf "$W/blake3.tgz"
cmake -S "$W/BLAKE3-$BLAKE3_VER/c" -B "$W/blake3-b" -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON -DCMAKE_C_COMPILER=clang
cmake --build "$W/blake3-b" -j"$J" && cmake --install "$W/blake3-b"

# Debian's librapidcheck.a is not PIC (cannot link into the test-support shared libs) and ships no .pc file.
fetch rc.tgz "https://github.com/emil-e/rapidcheck/archive/$RC_REV.tar.gz" "$RC_SHA"
tar -C "$W" -xf "$W/rc.tgz"
cmake -S "$W/rapidcheck-$RC_REV" -B "$W/rc-b" -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_CXX_COMPILER=clang++ -DRC_ENABLE_GTEST=ON -DRC_INSTALL_ALL_EXTRAS=ON
cmake --build "$W/rc-b" -j"$J" && cmake --install "$W/rc-b"
mkdir -p "$PREFIX/lib/pkgconfig"
cat > "$PREFIX/lib/pkgconfig/rapidcheck.pc" <<PC
Name: rapidcheck
Description: rapidcheck property testing
Version: 0.0.0
Libs: -L$PREFIX/lib -lrapidcheck
Cflags: -I$PREFIX/include
PC

fetch curl.txz "https://curl.se/download/curl-$CURL_VER.tar.xz" "$CURL_SHA"
tar -C "$W" -xf "$W/curl.txz"
( cd "$W/curl-$CURL_VER" && ./configure --prefix="$PREFIX" --with-openssl --with-ca-path=/etc/ssl/certs \
    --without-libpsl --without-libidn2 --without-nghttp2 --without-brotli --without-zstd --disable-ldap --disable-static \
  && make -j"$J" && make install )

fetch boost.tbz2 "https://archives.boost.io/release/$BOOST_VER/source/boost_${BOOST_VER//./_}.tar.bz2" "$BOOST_SHA"
tar -C "$W" -xf "$W/boost.tbz2"
( cd "$W/boost_${BOOST_VER//./_}" && ./bootstrap.sh --with-toolset=clang --prefix="$PREFIX" \
  && ./b2 -j"$J" toolset=clang cxxflags="-std=c++23" variant=release link=shared threading=multi \
       --with-container --with-context --with-coroutine --with-iostreams --with-url --with-thread --with-regex --with-random install )
