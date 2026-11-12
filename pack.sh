#!/usr/bin/env bash
#
# nextplayer 编译打包脚本 —— 目标系统 Rocky Linux 9.3 (Blue Onyx)
#
# 做什么：
#   1. 检查 /usr/local 下有没有本项目要用的 JDK / Android SDK / Gradle，缺哪个装哪个
#      —— 只往 /usr/local 里解压，不写 PATH、不改 /etc/profile
#   2. 环境齐了以后编译 release APK，再用项目根目录的 nextplayer.jks 签名
#   3. 所有工具都用绝对路径调用，不依赖 PATH
#
# 用法：
#   sudo bash pack.sh                 # 首次要往 /usr/local 写，需要 root
#   bash pack.sh                      # 环境已就绪时普通用户也能跑
#   PREFIX=$HOME/tools bash pack.sh   # 不想装 /usr/local 就换前缀
#
# 只支持 x86_64；下载优先走国内镜像（清华 / 腾讯），失败自动退回官方源。
#
set -euo pipefail

# ============================================================ 可调参数

PREFIX="${PREFIX:-/usr/local}"

# 工具链版本 —— 与本项目 gradle/wrapper 和 libs.versions.toml 对齐，别乱改
JDK_DIR_NAME="jdk-17.0.21"
JDK_TARBALL="OpenJDK17U-jdk_x64_linux_hotspot_17.0.21_9.tar.gz"
GRADLE_VER="9.9.0"
GRADLE_SHA256="0b00b0ffe07c4d4789c12d4935a44a7057d55774b7540bd4a3f76f336deb177a"
PLATFORM_ID="android-37.0"      # compileSdk = 37
BUILD_TOOLS_VER="37.0.0"

PLATFORM_ZIP="platform-37.0_r02.zip"
BUILDTOOLS_ZIP="build-tools_r37_linux.zip"
PLATFORMTOOLS_ZIP="platform-tools_r37.0.3-linux.zip"

# 镜像优先，官方兜底
M_TUNA="https://mirrors.tuna.tsinghua.edu.cn"
M_TX="https://mirrors.cloud.tencent.com"

JDK_URL="$M_TUNA/Adoptium/17/jdk/x64/linux/$JDK_TARBALL"
GRADLE_URL="$M_TX/gradle/gradle-$GRADLE_VER-bin.zip"
GRADLE_URL_ALT="https://services.gradle.org/distributions/gradle-$GRADLE_VER-bin.zip"

SDK_MIRROR="$M_TX/AndroidSDK"
SDK_MIRROR_ALT="https://dl.google.com/android/repository"

# 签名
KS_PASS="000777"
KS_ALIAS="nextplayer"

# ============================================================ 路径

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JDK_HOME="$PREFIX/$JDK_DIR_NAME"
GRADLE_HOME="$PREFIX/gradle-$GRADLE_VER"
SDK_HOME="$PREFIX/android-sdk"
KEYSTORE="$PROJECT_DIR/$KS_ALIAS.jks"

APK_DIR="$PROJECT_DIR/app/build/outputs/apk/release"
UNSIGNED_APK="$APK_DIR/app-arm64-v8a-release-unsigned.apk"

# ============================================================ 输出

if [ -t 1 ]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
    C_B=$'\033[36m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_BOLD=''; C_0=''
fi

step() { printf '\n%s==> %s%s\n' "$C_B$C_BOLD" "$*" "$C_0"; }
ok()   { printf '  %s[ ok ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
say()  { printf '  %s\n' "$*"; }

TMP_DIRS=()
cleanup() {
    local d
    for d in "${TMP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap cleanup EXIT

new_tmp() {
    local d
    d="$(mktemp -d)"
    TMP_DIRS+=("$d")
    printf '%s' "$d"
}

# ============================================================ 前置检查

check_host() {
    step "检查系统"
    if [ -f /etc/redhat-release ]; then
        say "系统：$(cat /etc/redhat-release)"
    else
        warn "不是 RHEL 系发行版，脚本按 Rocky 9 写的，可能不适用"
    fi

    local arch; arch="$(uname -m)"
    say "架构：$arch"
    [ "$arch" = "x86_64" ] || die "只准备了 x86_64 工具链，当前是 $arch"

    local c
    for c in curl tar unzip; do
        command -v "$c" >/dev/null 2>&1 || die "缺少命令 $c，请先执行：dnf install -y $c"
    done
    ok "curl / tar / unzip 都在"
}

# 需要往 PREFIX 写时得有权限；全部装好了就不需要
check_writable() {
    [ -w "$PREFIX" ] && return 0
    if [ -x "$JDK_HOME/bin/javac" ] &&
        [ -x "$GRADLE_HOME/bin/gradle" ] &&
        [ -f "$SDK_HOME/platforms/$PLATFORM_ID/android.jar" ] &&
        [ -x "$SDK_HOME/build-tools/$BUILD_TOOLS_VER/apksigner" ]; then
        return 0
    fi
    die "$PREFIX 不可写，请用 sudo 运行：sudo bash $0"
}

# ============================================================ 下载 / 解压

# fetch <url> <文件> [备用url]
# 成功返回 0；失败返回非 0（调用方决定是致命错误还是可以跳过），不走 die
fetch() {
    local url="$1" dest="$2" alt="${3:-}"
    mkdir -p "$(dirname "$dest")"
    say "下载 $(basename "$dest")"
    if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
        --progress-bar -o "$dest" "$url" 2>&1; then
        return 0
    fi
    if [ -n "$alt" ]; then
        warn "镜像不通，改用官方源重试"
        if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
            --progress-bar -o "$dest" "$alt" 2>&1; then
            return 0
        fi
    fi
    return 1
}

# fetch_required <url> <文件> [备用url] —— 下载失败就退出
fetch_required() {
    fetch "$@" || die "下载失败：$1"
}

# 镜像偶发返回 HTML 错误页，curl 却当成 200。按体积粗筛一下再解压，报错更清楚
check_archive_size() {
    local file="$1" min_bytes="$2" what="$3"
    local size
    size="$(stat -c %s "$file" 2>/dev/null || echo 0)"
    if [ "$size" -lt "$min_bytes" ]; then
        die "$what 下载不完整（$size 字节，至少应有 $min_bytes）
  可能是镜像返回了错误页，重跑一次试试；持续失败请换网络或手动下载"
    fi
}

# ============================================================ JDK

ensure_jdk() {
    step "JDK"
    if [ -x "$JDK_HOME/bin/javac" ]; then
        ok "已存在 $JDK_HOME"
        say "$("$JDK_HOME/bin/java" -version 2>&1 | head -1)"
        return 0
    fi

    say "未找到，安装到 $JDK_HOME"
    local tmp; tmp="$(new_tmp)"
    fetch_required "$JDK_URL" "$tmp/$JDK_TARBALL"
    check_archive_size "$tmp/$JDK_TARBALL" 100000000 "JDK"

    mkdir -p "$JDK_HOME"
    tar -xzf "$tmp/$JDK_TARBALL" -C "$JDK_HOME" --strip-components=1
    [ -x "$JDK_HOME/bin/javac" ] || die "JDK 解压后没有 javac"
    ok "完成：$("$JDK_HOME/bin/java" -version 2>&1 | head -1)"
}

# ============================================================ Gradle

ensure_gradle() {
    step "Gradle"
    if [ -x "$GRADLE_HOME/bin/gradle" ]; then
        ok "已存在 $GRADLE_HOME"
        return 0
    fi

    say "未找到，安装 Gradle $GRADLE_VER 到 $GRADLE_HOME"
    local tmp; tmp="$(new_tmp)"
    fetch_required "$GRADLE_URL" "$tmp/gradle.zip" "$GRADLE_URL_ALT"

    local actual
    actual="$(sha256sum "$tmp/gradle.zip" | awk '{print $1}')"
    if [ "$actual" != "$GRADLE_SHA256" ]; then
        die "Gradle 校验不通过
  期望 $GRADLE_SHA256
  实际 $actual"
    fi
    ok "sha256 校验通过"

    unzip -q "$tmp/gradle.zip" -d "$PREFIX"
    [ -x "$GRADLE_HOME/bin/gradle" ] || die "解压后找不到 $GRADLE_HOME/bin/gradle"
    ok "完成"
}

# ============================================================ Android SDK

# 直接解压 SDK 官方 zip，不走 sdkmanager —— 不依赖它的换源能力，最稳
ensure_sdk() {
    step "Android SDK"

    local platform_ok=0 buildtools_ok=0
    [ -f "$SDK_HOME/platforms/$PLATFORM_ID/android.jar" ] && platform_ok=1
    [ -x "$SDK_HOME/build-tools/$BUILD_TOOLS_VER/apksigner" ] && buildtools_ok=1

    if [ "$platform_ok" = 1 ] && [ "$buildtools_ok" = 1 ]; then
        ok "已存在 $SDK_HOME"
        say "platform $PLATFORM_ID + build-tools $BUILD_TOOLS_VER"
        return 0
    fi

    mkdir -p "$SDK_HOME/platforms" "$SDK_HOME/build-tools"

    # ---- platform ----
    if [ "$platform_ok" = 1 ]; then
        ok "platform $PLATFORM_ID 已存在"
    else
        say "安装 platform $PLATFORM_ID"
        local tmp; tmp="$(new_tmp)"
        fetch_required "$SDK_MIRROR/$PLATFORM_ZIP" "$tmp/p.zip" "$SDK_MIRROR_ALT/$PLATFORM_ZIP"
        check_archive_size "$tmp/p.zip" 40000000 "platform $PLATFORM_ID"
        unzip -q "$tmp/p.zip" -d "$tmp/x"
        rm -rf "$SDK_HOME/platforms/$PLATFORM_ID"
        mv "$tmp/x/$PLATFORM_ID" "$SDK_HOME/platforms/$PLATFORM_ID"
        [ -f "$SDK_HOME/platforms/$PLATFORM_ID/android.jar" ] ||
            die "platform 安装后找不到 android.jar"
        ok "platform 完成"
    fi

    # ---- build-tools ----
    if [ "$buildtools_ok" = 1 ]; then
        ok "build-tools $BUILD_TOOLS_VER 已存在"
    else
        say "安装 build-tools $BUILD_TOOLS_VER"
        local tmp; tmp="$(new_tmp)"
        fetch_required "$SDK_MIRROR/$BUILDTOOLS_ZIP" "$tmp/b.zip" "$SDK_MIRROR_ALT/$BUILDTOOLS_ZIP"
        check_archive_size "$tmp/b.zip" 40000000 "build-tools $BUILD_TOOLS_VER"
        unzip -q "$tmp/b.zip" -d "$tmp/x"
        # zip 里的目录名是 android-37.0，SDK 要求按版本号命名
        local src
        src="$(find "$tmp/x" -maxdepth 1 -mindepth 1 -type d | head -1)"
        [ -n "$src" ] || die "build-tools 压缩包结构异常"
        rm -rf "$SDK_HOME/build-tools/$BUILD_TOOLS_VER"
        mv "$src" "$SDK_HOME/build-tools/$BUILD_TOOLS_VER"
        chmod +x "$SDK_HOME/build-tools/$BUILD_TOOLS_VER"/{aapt2,apksigner,zipalign} 2>/dev/null || true
        [ -x "$SDK_HOME/build-tools/$BUILD_TOOLS_VER/apksigner" ] ||
            die "build-tools 安装后找不到 apksigner"
        ok "build-tools 完成"
    fi

    # ---- platform-tools（可选，编译不需要；装了只是让 SDK 目录完整）----
    if [ ! -d "$SDK_HOME/platform-tools" ]; then
        say "安装 platform-tools（可选）"
        local tmp; tmp="$(new_tmp)"
        if fetch "$SDK_MIRROR/$PLATFORMTOOLS_ZIP" "$tmp/pt.zip" \
            "$SDK_MIRROR_ALT/$PLATFORMTOOLS_ZIP"; then
            unzip -q "$tmp/pt.zip" -d "$tmp/x" || true
            if [ -d "$tmp/x/platform-tools" ]; then
                mv "$tmp/x/platform-tools" "$SDK_HOME/platform-tools"
                ok "platform-tools 完成"
            else
                warn "platform-tools 结构异常，跳过（不影响编译）"
            fi
        else
            warn "platform-tools 下载失败，跳过（不影响编译）"
        fi
    fi

    ok "Android SDK 就绪：$SDK_HOME"
}

# ============================================================ 项目准备

prepare_project() {
    step "项目准备"

    [ -f "$PROJECT_DIR/settings.gradle.kts" ] ||
        die "$PROJECT_DIR 不是项目根目录（没有 settings.gradle.kts）"
    [ -f "$PROJECT_DIR/gradlew" ] || die "项目里没有 gradlew"
    [ -f "$PROJECT_DIR/gradle/wrapper/gradle-wrapper.properties" ] ||
        die "项目里没有 gradle-wrapper.properties"

    # 显式告诉 AGP SDK 位置。local.properties 被 .gitignore 忽略，写它最安全
    local props="$PROJECT_DIR/local.properties"
    local want="sdk.dir=$SDK_HOME"
    if [ -f "$props" ]; then
        # 只替换 / 追加 sdk.dir，不动别的行
        if grep -q '^sdk\.dir=' "$props"; then
            if ! grep -qxF "$want" "$props"; then
                sed -i "s|^sdk\.dir=.*|$want|" "$props"
                ok "已更新 local.properties 的 sdk.dir"
            else
                ok "local.properties 已指向 $SDK_HOME"
            fi
        else
            printf '\n%s\n' "$want" >> "$props"
            ok "已向 local.properties 追加 sdk.dir"
        fi
    else
        printf '%s\n' "$want" > "$props"
        ok "已创建 local.properties"
    fi

    [ -f "$KEYSTORE" ] ||
        die "找不到签名库 $KEYSTORE
  请把 nextplayer.jks 放到项目根目录：$PROJECT_DIR/"
    ok "签名库：$KEYSTORE"

    # 整个脚本可能是 sudo 跑的，配置文件不该留在 root 名下
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        chown "$SUDO_USER": "$PROJECT_DIR/local.properties" 2>/dev/null || true
    fi
}

# ============================================================ 构建

# 用 sudo 跑过之后，项目里的 build/ .gradle/ 会变成 root 所有，
# 以后普通用户再构建就会报权限错误。所以构建和签名都以原用户身份执行。
as_owner() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        sudo -u "$SUDO_USER" \
            --preserve-env=JAVA_HOME,ANDROID_HOME,ANDROID_SDK_ROOT \
            "$@"
    else
        "$@"
    fi
}

build_apk() {
    step "编译 release"

    export JAVA_HOME="$JDK_HOME"
    export ANDROID_HOME="$SDK_HOME"
    export ANDROID_SDK_ROOT="$SDK_HOME"

    say "JAVA_HOME   = $JAVA_HOME"
    say "ANDROID_HOME= $ANDROID_HOME"
    say "gradle      = $GRADLE_HOME/bin/gradle"
    say ""

    cd "$PROJECT_DIR"
    as_owner "$GRADLE_HOME/bin/gradle" assembleRelease --console=plain --no-daemon

    [ -f "$UNSIGNED_APK" ] || die "构建结束但没找到产物：$UNSIGNED_APK"
    ok "产物：$(basename "$UNSIGNED_APK")"
}

# ============================================================ 签名

sign_apk() {
    step "签名"

    local bt="$SDK_HOME/build-tools/$BUILD_TOOLS_VER"
    local apksigner="$bt/apksigner"
    local aapt2="$bt/aapt2"
    [ -x "$apksigner" ] || die "找不到 apksigner：$apksigner"

    # 版本号从构建脚本里读，不写死在脚本里
    local version="unknown"
    local v
    v="$(sed -n 's/.*versionName *= *"\([^"]*\)".*/\1/p' \
        "$PROJECT_DIR/app/build.gradle.kts" 2>/dev/null | head -1)"
    [ -n "$v" ] && version="$v"

    local stamp out
    stamp="$(date +%y%m%d_%H%M%S)"
    out="$PROJECT_DIR/nextplayer_${stamp}_appRelease_${version}_arm64.apk"

    export JAVA_HOME="$JDK_HOME"

    as_owner "$apksigner" sign \
        --ks "$KEYSTORE" \
        --ks-key-alias "$KS_ALIAS" \
        --ks-pass "pass:$KS_PASS" \
        --key-pass "pass:$KS_PASS" \
        --v1-signing-enabled true \
        --v2-signing-enabled true \
        --v3-signing-enabled true \
        --out "$out" \
        "$UNSIGNED_APK"

    # apksigner 会顺带写 .idsig，不留
    rm -f "$out.idsig"

    say "校验签名"
    "$apksigner" verify --print-certs "$out" | head -3

    if [ -x "$aapt2" ]; then
        say "APK 信息"
        "$aapt2" dump badging "$out" 2>/dev/null |
            grep -E '^package:|^native-code' || true
    fi

    printf '\n%s产物：%s%s\n\n' "$C_BOLD" "$out" "$C_0"
}

# ============================================================ main

main() {
    printf '\n%snextplayer 编译打包%s\n' "$C_BOLD" "$C_0"
    printf '项目目录：%s\n' "$PROJECT_DIR"
    printf '安装前缀：%s\n' "$PREFIX"

    check_host
    check_writable
    ensure_jdk
    ensure_gradle
    ensure_sdk
    prepare_project
    build_apk
    sign_apk
}

main "$@"
