#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BINARY=".build/arm64-apple-macosx/release/GuitarEQAnalyzerSwift"

# Собрать если бинарника нет или исходники новее
if [[ ! -f "$BINARY" ]] || find GuitarEQAnalyzerSwift -name "*.swift" -newer "$BINARY" | grep -q .; then
    echo "Building Guitar EQ Analyzer..."
    swift build -c release 2>&1
fi

exec "$BINARY"
