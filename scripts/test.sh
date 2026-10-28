#!/usr/bin/env bash
# Fallback test runner using swiftc directly (see scripts/build.sh for why).
# Prefer `swift test`.
#
# Usage: scripts/test.sh            → runs all Swift Testing suites
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=.build/swiftc-test
TARGET="$(uname -m)-apple-macosx26.0"
FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
FLAGS=(-target "$TARGET" -swift-version 6 -parse-as-library -enable-testing -I "$OUT")
mkdir -p "$OUT"

lib() {
  local m="$1"
  swiftc "${FLAGS[@]}" -module-name "$m" -emit-module -emit-module-path "$OUT/$m.swiftmodule" \
    -static -emit-library -o "$OUT/lib$m.a" Sources/"$m"/*.swift
}
lib MuesliCore
lib MuesliAudio
lib MuesliTranscribe
lib MuesliSummarize
lib MuesliSession

cat > "$OUT/Runner.swift" <<'SWIFT'
import Testing
@main struct Runner {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
SWIFT

swiftc "${FLAGS[@]}" -module-name MuesliTests -F "$FRAMEWORKS" -framework Testing \
  -plugin-path "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/usr/lib" \
  -o "$OUT/muesli-tests" "$OUT/Runner.swift" Tests/*/*.swift \
  "$OUT"/libMuesli{Session,Summarize,Transcribe,Audio,Core}.a

"$OUT/muesli-tests"
