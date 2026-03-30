#!/bin/zsh
# Запускает Guitar EQ Analyzer (Swift). Двойной клик в Finder.
# Собирает автоматически если бинарник устарел.

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

# Xcode CLT / homebrew swift
for d in \
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin" \
    "/Library/Developer/CommandLineTools/usr/bin" \
    "$HOME/.swiftenv/shims" \
    "/opt/homebrew/bin"; do
    [[ -d "$d" ]] && export PATH="$d:$PATH"
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BINARY=".build/arm64-apple-macosx/release/GuitarEQAnalyzerSwift"

if ! command -v swift &>/dev/null; then
    osascript -e 'display alert "Swift not found" message "Install Xcode Command Line Tools:\nxcode-select --install"'
    exit 1
fi

if [[ ! -f "$BINARY" ]] || find GuitarEQAnalyzerSwift -name "*.swift" -newer "$BINARY" | grep -q .; then
    echo "Building Guitar EQ Analyzer..."
    swift build -c release 2>&1
fi

exec "$BINARY"
