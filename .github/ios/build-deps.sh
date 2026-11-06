#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the iOS arm64 libraries Lichii needs that have no iOS package: FFmpeg (video decoding)
# and OpenSSL (ssl service), plus MoltenVK.framework (Vulkan on Metal).
# Usage: build-deps.sh <prefix>   (produces <prefix>/{include,lib} and <prefix>/MoltenVK.framework)
set -euo pipefail

PREFIX="$1"
MIN_IOS=16.0
FFMPEG_TAG=n7.1.1
OPENSSL_TAG=openssl-3.5.4
MOLTENVK_VERSIONS="v1.4.1 v1.4.0 v1.3.0"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos --find clang)"
JOBS="$(sysctl -n hw.ncpu)"
WORK="$(mktemp -d)"
mkdir -p "$PREFIX"

if [ ! -f "$PREFIX/lib/libavcodec.a" ]; then
    echo "::group::FFmpeg $FFMPEG_TAG"
    git clone --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git "$WORK/ffmpeg"
    cd "$WORK/ffmpeg"
    ./configure \
        --prefix="$PREFIX" \
        --enable-cross-compile --target-os=darwin --arch=aarch64 \
        --cc="$CC" --sysroot="$SDK" \
        --extra-cflags="-arch arm64 -mios-version-min=$MIN_IOS" \
        --extra-ldflags="-arch arm64 -mios-version-min=$MIN_IOS" \
        --enable-static --disable-shared --enable-pic \
        --disable-autodetect --disable-everything \
        --disable-programs --disable-doc --disable-debug \
        --disable-avformat --disable-avdevice --disable-swresample \
        `# hevc: h264's shared SEI code links against aom_film_grain, built only with hevc` \
        --enable-avcodec --enable-avfilter --enable-avutil --enable-swscale \
        --enable-decoder=h264,hevc,vp8,vp9 --enable-parser=h264,hevc,vp8,vp9
    make -j"$JOBS"
    make install
    echo "::endgroup::"
fi

if [ ! -f "$PREFIX/lib/libssl.a" ]; then
    echo "::group::OpenSSL $OPENSSL_TAG"
    git clone --depth 1 --branch "$OPENSSL_TAG" https://github.com/openssl/openssl.git "$WORK/openssl"
    cd "$WORK/openssl"
    ./Configure ios64-xcrun no-shared no-tests no-apps no-docs no-module \
        --prefix="$PREFIX" --libdir=lib "-mios-version-min=$MIN_IOS"
    make -j"$JOBS" build_libs
    make install_dev
    echo "::endgroup::"
fi

if [ ! -d "$PREFIX/MoltenVK.framework" ]; then
    echo "::group::MoltenVK"
    for version in $MOLTENVK_VERSIONS; do
        url="https://github.com/KhronosGroup/MoltenVK/releases/download/$version/MoltenVK-ios.tar"
        if curl -fsSL "$url" -o "$WORK/moltenvk.tar"; then
            echo "Using MoltenVK $version"
            break
        fi
        echo "MoltenVK $version: no iOS release asset"
    done
    tar -xf "$WORK/moltenvk.tar" -C "$WORK"
    # Prefer the device (not simulator) slice of the dynamic xcframework; fall back to the dylib.
    framework="$(find "$WORK" -type d -path '*ios-arm64/MoltenVK.framework' | grep -v simulator | head -n 1 || true)"
    if [ -n "$framework" ]; then
        cp -R "$framework" "$PREFIX/MoltenVK.framework"
    else
        dylib="$(find "$WORK" -name libMoltenVK.dylib -path '*iOS*' | grep -v -i simulator | head -n 1)"
        mkdir -p "$PREFIX/MoltenVK.framework"
        cp "$dylib" "$PREFIX/MoltenVK.framework/MoltenVK"
        install_name_tool -id @rpath/MoltenVK.framework/MoltenVK "$PREFIX/MoltenVK.framework/MoltenVK"
        cat > "$PREFIX/MoltenVK.framework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MoltenVK</string>
    <key>CFBundleIdentifier</key><string>com.khronos.MoltenVK</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>16.0</string>
    <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict>
</plist>
PLIST
    fi
    lipo -info "$PREFIX/MoltenVK.framework/MoltenVK"
    echo "::endgroup::"
fi

rm -rf "$WORK"
