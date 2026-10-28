#!/usr/bin/env bash
# Fallback build using swiftc directly, bypassing SwiftPM.
#
# Prefer `swift build`. This script exists because some Command Line Tools
# betas ship a SwiftPM manifest library that doesn't match its own interface,
# so no Package.swift compiles (link error on `PackageDescription.Package.init`).
#
# Usage: scripts/build.sh            → .build/swiftc/muesli
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=.build/swiftc
TARGET="$(uname -m)-apple-macosx26.0"
FLAGS=(-target "$TARGET" -swift-version 6 -parse-as-library -I "$OUT")
mkdir -p "$OUT"

lib() {  # lib <Module>
  local m="$1"
  swiftc "${FLAGS[@]}" -module-name "$m" -emit-module -emit-module-path "$OUT/$m.swiftmodule" \
    -static -emit-library -o "$OUT/lib$m.a" Sources/"$m"/*.swift
}

lib MuesliCore
lib MuesliAudio
lib MuesliTranscribe
lib MuesliSummarize
lib MuesliSession

swiftc "${FLAGS[@]}" -module-name muesli -o "$OUT/muesli" Sources/muesli/*.swift \
  "$OUT"/libMuesli{Session,Summarize,Transcribe,Audio,Core}.a \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Sources/muesli/Info.plist

echo "built $OUT/muesli"
