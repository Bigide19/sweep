#!/usr/bin/env bash
# SwiftPM이 만든 실행 파일을 .app 번들로 감쌉니다.
# NSStatusItem은 번들로 실행되어야 메뉴바에 자리를 잡습니다.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
# 번들은 .build 안에 둡니다. 프로젝트 루트에 build/를 만들면 sweep 자신이
# 그걸 삭제 후보로 잡는 우스운 상황이 생깁니다.
BUNDLE=".build/bundle/Sweep.app"

echo "빌드 중 ($CONFIG)..."
swift build -c "$CONFIG" --product SweepApp
swift build -c "$CONFIG" --product sweep

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp ".build/$CONFIG/SweepApp" "$BUNDLE/Contents/MacOS/Sweep"
cp scripts/Info.plist "$BUNDLE/Contents/Info.plist"

# 앱 아이콘은 scripts/icon/render-icon.swift가 그린 PNG를 iconutil로 icns로 묶습니다.
# 원본 PNG를 레포에 넣지 않고 매번 그리는 이유는, 스크립트 하나가 아이콘의 단일
# 출처가 되게 하려는 것입니다. Finder와 Dock은 이 icns를 씁니다.
ICON_TMP="$(mktemp -d)"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/icon/render-icon.swift "$ICON_TMP/icon-1024.png" >/dev/null
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_TMP/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_TMP/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"

# 로컬에서 쓰려면 ad-hoc 서명으로 충분합니다. 로그인 항목 등록은 서명이
# 없으면 거부될 수 있어서 실패해도 빌드는 계속합니다.
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 \
    && echo "ad-hoc 서명 완료" \
    || echo "서명을 건너뜁니다 (로그인 항목 등록이 안 될 수 있습니다)"

echo "번들: $BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
    TARGET="/Applications/Sweep.app"
    rm -rf "$TARGET"
    cp -R "$BUNDLE" "$TARGET"
    echo "설치: $TARGET"
fi

if [[ "${1:-}" == "--run" || "${2:-}" == "--run" ]]; then
    pkill -x Sweep 2>/dev/null || true
    open "$BUNDLE"
    echo "실행했습니다. 메뉴바를 확인하세요."
fi
