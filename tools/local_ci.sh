#!/bin/bash
# 本地测试 / 打包（主路径）。
#
# GitHub Actions 仍保留在 .github/workflows/ios.yml，但改成**只手动触发**：
# 日常验证在这台 Mac 上跑，省掉排队时间。
#
# 用法：
#   tools/local_ci.sh test      preflight + 逻辑镜像 + 单元/UI 测试
#   tools/local_ci.sh ipa       打未签名 IPA（仓库根目录 AIHOT-unsigned.ipa）
#
# 可选环境变量：
#   SIMULATOR_UDID   指定模拟器（默认自动挑第一台可用 iPhone）
#   BUILD_NUMBER     指定 CFBundleVersion（默认 yyyymmddHHMM）
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
用法：
  tools/local_ci.sh test     跑 preflight + 逻辑镜像 + 单元/UI 测试
  tools/local_ci.sh ipa      打未签名 IPA（输出到仓库根目录）
环境变量：
  SIMULATOR_UDID             指定模拟器（默认自动挑第一台可用 iPhone）
  BUILD_NUMBER               指定 CFBundleVersion（默认 yyyymmddHHMM）
EOF
}

require_tools() {
    for tool in xcodegen xcodebuild xcrun python3; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "缺少命令：$tool"
            exit 1
        fi
    done
}

prepare() {
    require_tools
    python3 tools/make_appicon.py
    test -s AIHOT/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
    xcodegen generate
    python3 tools/preflight.py
    python3 tools/logic_tests.py
}

pick_simulator() {
    if [ -n "${SIMULATOR_UDID:-}" ]; then
        echo "$SIMULATOR_UDID"
        return
    fi
    # 优先用已经启动的 iPhone：本机可能同时装了多个 runtime，
    # 新 runtime 首次启动可能超过 UI 测试等待的 15 秒。
    xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
iphones = [
    x
    for group in devices.values()
    for x in group
    if x.get("isAvailable") and x.get("name", "").startswith("iPhone")
]
booted = [x for x in iphones if x.get("state") == "Booted"]
print((booted or iphones)[0]["udid"])
'
}

case "${1:-}" in
    test)
        prepare
        UDID="$(pick_simulator)"
        echo "使用模拟器：$UDID"
        xcodebuild test \
            -project AIHOT.xcodeproj \
            -scheme AIHOT \
            -destination "platform=iOS Simulator,id=$UDID" \
            -derivedDataPath build
        ;;
    ipa)
        prepare
        BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
        xcodebuild clean build \
            -project AIHOT.xcodeproj \
            -scheme AIHOT \
            -configuration Release \
            -sdk iphoneos \
            -destination 'generic/platform=iOS' \
            -derivedDataPath build \
            CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGN_IDENTITY="" \
            CODE_SIGN_ENTITLEMENTS=""

        APP="build/Build/Products/Release-iphoneos/AIHOT.app"
        test -d "$APP"
        rm -rf Payload AIHOT-unsigned.ipa
        mkdir -p Payload
        cp -R "$APP" Payload/
        zip -qry AIHOT-unsigned.ipa Payload
        /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist"
        echo "IPA: $(pwd)/AIHOT-unsigned.ipa（CFBundleVersion=$BUILD_NUMBER）"
        ;;
    *)
        usage
        exit 1
        ;;
esac
