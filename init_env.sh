#!/usr/bin/env bash
#
# nextplayer 环境初始化 —— 目标系统 Rocky Linux 9.3 (Blue Onyx)
#
# 用 root 跑一次，把本项目要用的 JDK / Android SDK / Gradle 装进 /usr/local。
# 装完之后，用 itdev 跑 pack.sh 就能直接编译打包。
#
# 用法：
#   sudo bash init_env.sh             # 必须 root，否则直接退出
#   sudo bash init_env.sh             # 用 sh 调也行：sudo sh init_env.sh
#   PREFIX=/opt/tools sudo bash init_env.sh   # 装到别处
#   OWNER=itdev sudo bash init_env.sh         # 顺手把项目里的 root 残留交给 itdev
#
# 特点：
#   - 只往 /usr/local 解压，不写 PATH、不改 /etc/profile
#   - 下载优先国内镜像（清华 / 腾讯），失败自动退回官方源
#   - 已存在的工具会跳过，可以反复跑
#   - 只支持 x86_64
#
set -euo pipefail

# 用 sh 调起时（Rocky 的 /bin/sh 会进 POSIX 模式）切回 bash，保证数组等语法可用
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

# ============================================================ 身份闸门

# 最前面就卡身份：必须是 root，否则立刻退出。
# 装环境要写 /usr/local，非 root 做不到；让它在最前失败，别跑到一半才报错。
if [ "$(id -un)" != "root" ]; then
    printf '\n\033[31m[FAIL]\033[0m init_env.sh 必须由 root 运行，当前用户是 %s\n' \
        "$(id -un)" >&2
    printf '\n  请执行：\n' >&2
    printf '    sudo bash %s\n\n' "${BASH_SOURCE[0]:-$0}" >&2
    exit 1
fi

# ============================================================ 可调参数

PREFIX="${PREFIX:-/usr/local}"

# 工具链版本 —— 与项目 gradle/wrapper 和 libs.versions.toml 对齐，别乱改
JDK_DIR_NAME="jdk-17.0.21"
JDK_TARBALL="OpenJDK17U-jdk_x64_linux_hotspot_17.0.21_9.tar.gz"
GRADLE_VER="9.9.0"
GRADLE_SHA256="0b00b0ffe07c4d4789c12d4935a44a7057d55774b7540bd4a3f76f336deb177a"
PLATFORM_ID="android-37.0"      # compileSdk = 37
# 37.0.0 是脚本签名用的；36.0.0 是 AGP 9.5.1 的默认 build-tools 版本，
# 项目没有显式声明 buildToolsVersion，所以 Gradle 会去找 36.0.0，缺了就构建失败。
BUILD_TOOLS_VERS=("37.0.0" "36.0.0")

PLATFORM_ZIP="platform-37.0_r02.zip"
# build-tools 的 zip 名和版本号不是一一对应（r37/r36），用关联数组映射
declare -A BUILD_TOOLS_ZIP_MAP=(
    ["37.0.0"]="build-tools_r37_linux.zip"
    ["36.0.0"]="build-tools_r36_linux.zip"
)
PLATFORMTOOLS_ZIP="platform-tools_r37.0.3-linux.zip"

# 镜像优先，官方兜底
M_TUNA="https://mirrors.tuna.tsinghua.edu.cn"
M_TX="https://mirrors.cloud.tencent.com"

JDK_URL="$M_TUNA/Adoptium/17/jdk/x64/linux/$JDK_TARBALL"
GRADLE_URL="$M_TX/gradle/gradle-$GRADLE_VER-bin.zip"
GRADLE_URL_ALT="https://services.gradle.org/distributions/gradle-$GRADLE_VER-bin.zip"

SDK_MIRROR="$M_TX/AndroidSDK"
SDK_MIRROR_ALT="https://dl.google.com/android/repository"

# ============================================================ 路径

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JDK_HOME="$PREFIX/$JDK_DIR_NAME"
GRADLE_HOME="$PREFIX/gradle-$GRADLE_VER"
SDK_HOME="$PREFIX/android-sdk"

# 项目里由构建产生的东西，root 跑过就会留成 root 所有
CACHE_ROOT="$PROJECT_DIR/.build-cache"

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
        command -v "$c" >/dev/null 2>&1 ||
            die "缺少命令 $c，请先执行：dnf install -y $c"
    done
    ok "curl / tar / unzip 都在"

    [ -d "$PREFIX" ] || die "$PREFIX 不存在"
    [ -w "$PREFIX" ] || die "$PREFIX 不可写，本脚本需要 root 权限"
}

# ============================================================ 下载 / 解压

# fetch <url> <文件> [备用url]
# 成功返回 0；失败返回非 0（调用方决定是致命还是可跳过），不走 die
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

# 在 $PREFIX 下找可用的 JDK 17，找不到就返回空。
# 不写死某一个目录名：机器上可能已经装了 jdk-17.0.15、jdk-17.0.21+9 之类，
# 只要 bin/javac 存在且大版本是 17 就直接复用，不重复下载。
find_existing_jdk() {
    local d ver major

    # 候选顺序：约定的目录名优先（多个 JDK 17 并存时行为确定），
    # 之后才是其他 jdk-17* 目录。注意直接写 jdk-17.0.21 时 java 读不到，
    # 因为它没有 bin/，会被下面的检查挡掉，所以不用特判。
    local candidates=(
        "$PREFIX/$JDK_DIR_NAME"
        "$PREFIX"/jdk-17*
        "$PREFIX"/jdk17*
        "$PREFIX"/*/jdk-17*
    )

    for d in "${candidates[@]}"; do
        [ -d "$d" ] || continue
        # javac 和 java 都要在，缺一个就不是完整 JDK
        [ -x "$d/bin/javac" ] && [ -x "$d/bin/java" ] || continue

        # 按 java -version 的实际版本判断，不看目录名 —— 目录名可能和真实版本不一致
        ver="$("$d/bin/java" -version 2>&1 | head -1)"
        major="$(printf '%s\n' "$ver" | sed -n 's/.*version "\([0-9]*\)[."].*/\1/p')"
        [ "$major" = "17" ] || continue

        printf '%s' "$d"
        return 0
    done
    return 1
}

ensure_jdk() {
    step "JDK 17"

    # 先在 $PREFIX 里找现成的，避免重复安装
    local found
    if found="$(find_existing_jdk)"; then
        JDK_HOME="$found"
        ok "已存在 $JDK_HOME"
        say "$("$JDK_HOME/bin/java" -version 2>&1 | head -1)"
        return 0
    fi

    # 有 jdk-17* 目录但不可用，说明是坏的，说清楚再装
    local broken
    for broken in "$PREFIX"/jdk-17*; do
        [ -d "$broken" ] && [ ! -x "$broken/bin/javac" ] &&
            warn "$broken 存在但不可用（缺 bin/javac 或版本不是 17），将重新安装"
    done

    say "安装到 $JDK_HOME"
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
    step "Gradle $GRADLE_VER"
    if [ -x "$GRADLE_HOME/bin/gradle" ]; then
        ok "已存在 $GRADLE_HOME"
        return 0
    fi

    say "安装到 $GRADLE_HOME"
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
# 生成 SDK 的 package.xml。
#
# SDK 官方 zip 里没有 package.xml（那是 sdkmanager 安装时生成的元数据），
# 而 Gradle 靠它判断组件是否已安装。缺了就会尝试"安装"，写不进只读的 SDK 目录
# 就报 "The SDK directory is not writable"。
#
# 已实测：这个精简版（不含完整许可证文本）Gradle 完全接受。
# 参数：<目录> <localPackage path> <platform 的 api-level 或空>
write_platform_package_xml() {
    local dir="$1" path="$2" api="$3"
    cat > "$dir/package.xml" <<XML
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02" xmlns:ns6="http://schemas.android.com/sdk/android/repo/repository2/04">
    <license id="android-sdk-license" type="text">accepted</license>
    <localPackage path="$path" obsolete="false">
        <type-details xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="ns6:platformDetailsType">
            <api-level>$api</api-level>
            <codename></codename>
            <extension-level>22</extension-level>
            <base-extension>true</base-extension>
            <layoutlib api="15"/>
        </type-details>
        <revision>
            <major>1</major>
        </revision>
        <display-name>Android SDK Platform $api</display-name>
        <uses-license ref="android-sdk-license"/>
    </localPackage>
</ns2:repository>
XML
}

write_buildtools_package_xml() {
    local dir="$1" path="$2" ver="$3"
    local major minor micro
    major="${ver%%.*}"
    local rest="${ver#*.}"
    minor="${rest%%.*}"
    micro="${rest#*.}"

    cat > "$dir/package.xml" <<XML
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02" xmlns:ns5="http://schemas.android.com/sdk/android/repo/repository2/04">
    <license id="android-sdk-license" type="text">accepted</license>
    <localPackage path="$path" obsolete="false">
        <type-details xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="ns5:genericDetailsType"/>
        <revision>
            <major>$major</major>
            <minor>$minor</minor>
            <micro>$micro</micro>
        </revision>
        <display-name>Android SDK Build-Tools $major</display-name>
        <uses-license ref="android-sdk-license"/>
    </localPackage>
</ns2:repository>
XML
}

ensure_sdk() {
    step "Android SDK"

    local platform_ok=0
    [ -f "$SDK_HOME/platforms/$PLATFORM_ID/android.jar" ] && platform_ok=1

    # 检查所有需要的 build-tools 版本
    local v all_bt_ok=1
    for v in "${BUILD_TOOLS_VERS[@]}"; do
        [ -x "$SDK_HOME/build-tools/$v/apksigner" ] || all_bt_ok=0
    done

    # 目录在但缺 package.xml（早期版本用解压 zip 的方式装的都会有这个问题），
    # 补上就行，不用重下。Gradle 靠它判断组件是否已安装。
    local fixed=0
    if [ "$platform_ok" = 1 ] && [ ! -f "$SDK_HOME/platforms/$PLATFORM_ID/package.xml" ]; then
        write_platform_package_xml \
            "$SDK_HOME/platforms/$PLATFORM_ID" \
            "platforms;$PLATFORM_ID" \
            "${PLATFORM_ID#android-}"
        fixed=1
        ok "补写 platform $PLATFORM_ID 的 package.xml"
    fi
    for v in "${BUILD_TOOLS_VERS[@]}"; do
        if [ -x "$SDK_HOME/build-tools/$v/apksigner" ] &&
            [ ! -f "$SDK_HOME/build-tools/$v/package.xml" ]; then
            write_buildtools_package_xml "$SDK_HOME/build-tools/$v" "build-tools;$v" "$v"
            fixed=1
            ok "补写 build-tools $v 的 package.xml"
        fi
    done

    if [ "$platform_ok" = 1 ] && [ "$all_bt_ok" = 1 ]; then
        ok "已存在 $SDK_HOME"
        say "platform $PLATFORM_ID"
        for v in "${BUILD_TOOLS_VERS[@]}"; do
            say "build-tools $v"
        done
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
        # zip 里没有 package.xml，补一个，否则 Gradle 会认为没安装
        write_platform_package_xml \
            "$SDK_HOME/platforms/$PLATFORM_ID" \
            "platforms;$PLATFORM_ID" \
            "${PLATFORM_ID#android-}"
        ok "platform 完成"
    fi

    # ---- build-tools（逐个版本装，zip 内层目录名是 android-XX.Y，要改名成版本号）----
    local zipname
    for v in "${BUILD_TOOLS_VERS[@]}"; do
        if [ -x "$SDK_HOME/build-tools/$v/apksigner" ]; then
            ok "build-tools $v 已存在"
            continue
        fi

        zipname="${BUILD_TOOLS_ZIP_MAP[$v]:-}"
        [ -n "$zipname" ] || die "内部错误：build-tools $v 没有对应的 zip 名"

        say "安装 build-tools $v"
        local tmp; tmp="$(new_tmp)"
        fetch_required "$SDK_MIRROR/$zipname" "$tmp/b.zip" "$SDK_MIRROR_ALT/$zipname"
        check_archive_size "$tmp/b.zip" 30000000 "build-tools $v"
        unzip -q "$tmp/b.zip" -d "$tmp/x"

        local src
        src="$(find "$tmp/x" -maxdepth 1 -mindepth 1 -type d | head -1)"
        [ -n "$src" ] || die "build-tools $v 压缩包结构异常"
        rm -rf "$SDK_HOME/build-tools/$v"
        mv "$src" "$SDK_HOME/build-tools/$v"
        chmod +x "$SDK_HOME/build-tools/$v"/{aapt2,apksigner,zipalign} 2>/dev/null || true
        [ -x "$SDK_HOME/build-tools/$v/apksigner" ] ||
            die "build-tools $v 安装后找不到 apksigner"
        write_buildtools_package_xml "$SDK_HOME/build-tools/$v" "build-tools;$v" "$v"
        ok "build-tools $v 完成"
    done

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

# ============================================================ SDK 许可证

# Gradle 装 SDK 组件前会查 licenses 目录。只解压 zip 是不够的：
# 没有许可证文件，Gradle 会报 "Failed to install the following Android SDK packages
# as some licences have not been accepted"，构建直接失败。
ensure_sdk_licenses() {
    step "SDK 许可证"

    local dir="$SDK_HOME/licenses"
    mkdir -p "$dir"

    # 这两个哈希是 Android SDK 的 standard license 与 build-tools license，
    # 内容就是 sdkmanager --licenses 同意后写入的东西。
    local changed=0 f hash
    while IFS=':' read -r f hash; do
        [ -n "$f" ] || continue
        if [ -f "$dir/$f" ] && grep -qxF "$hash" "$dir/$f" 2>/dev/null; then
            continue
        fi
        printf '\n%s\n' "$hash" >> "$dir/$f"
        chown -R "$(stat -c %U "$SDK_HOME"):" "$dir" 2>/dev/null || true
        changed=1
    done <<'EOF'
android-sdk-license:24333f8a63b6825ea9c5514f83c2829b004d1fee
android-sdk-preview-license:84831b9409646a918e30573bab4c9c91346d8abd
EOF

    if [ "$changed" = 1 ]; then
        ok "已写入许可证：$dir"
    else
        ok "许可证已存在"
    fi
}
# ============================================================ 项目归属交接

# root 装环境时如果之前有人用 root 跑过构建，项目里会残留 root 所有的目录，
# 业务用户接手时会写不进去。这里把已知的构建产物目录交给接手人。
# 只动脚本/构建产生的东西，不碰源码（源码本来就在业务用户名下）。
hand_over_project() {
    step "项目目录归属"

    # 推断接手人：显式 OWNER > 项目目录当前所有者
    local owner="${OWNER:-}"
    if [ -z "$owner" ]; then
        local dir_owner
        dir_owner="$(stat -c %U "$PROJECT_DIR" 2>/dev/null || true)"
        if [ -n "$dir_owner" ] && [ "$dir_owner" != "root" ]; then
            owner="$dir_owner"
        fi
    fi

    if [ -z "$owner" ]; then
        warn "无法确定该把项目交给谁（项目目录属于 root，且没给 OWNER）"
        warn "如果以后用 itdev 构建，请执行："
        warn "  chown -R itdev: '$PROJECT_DIR'"
        return 0
    fi

    if ! id "$owner" >/dev/null 2>&1; then
        warn "用户不存在：$owner，跳过归属交接"
        return 0
    fi

    local changed=0 p
    for p in "$CACHE_ROOT" "$PROJECT_DIR/.gradle" "$PROJECT_DIR/local.properties"; do
        if [ -e "$p" ] && [ "$(stat -c %U "$p" 2>/dev/null)" != "$owner" ]; then
            chown -R "$owner": "$p" 2>/dev/null && changed=1
        fi
    done

    # 各模块的 build/ 目录
    local d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        if [ "$(stat -c %U "$d" 2>/dev/null)" != "$owner" ]; then
            chown -R "$owner": "$d" 2>/dev/null && changed=1
        fi
    done < <(find "$PROJECT_DIR" -maxdepth 3 -type d -name build \
        -not -path "*/.build-cache/*" -not -path "*/.git/*" 2>/dev/null)

    # 根目录的 APK
    local apk
    for apk in "$PROJECT_DIR"/*.apk; do
        [ -e "$apk" ] || continue
        if [ "$(stat -c %U "$apk" 2>/dev/null)" != "$owner" ]; then
            chown "$owner": "$apk" 2>/dev/null && changed=1
        fi
    done

    # 项目根目录本身：让业务用户能在这里创建 local.properties 和产物
    if [ "$(stat -c %U "$PROJECT_DIR" 2>/dev/null)" = "root" ]; then
        warn "项目目录本身属于 root，业务用户无法写入"
        warn "请执行：chown -R $owner: '$PROJECT_DIR'"
        return 0
    fi

    if [ "$changed" = 1 ]; then
        ok "已把构建残留交给 $owner"
    else
        ok "归属正常，无需调整（接手人：$owner）"
    fi
}

# ============================================================ main

main() {
    printf '\n%snextplayer 环境初始化%s\n' "$C_BOLD" "$C_0"
    printf '项目目录：%s\n' "$PROJECT_DIR"
    printf '安装前缀：%s\n' "$PREFIX"

    check_host
    ensure_jdk
    ensure_gradle
    ensure_sdk
    ensure_sdk_licenses
    hand_over_project

    # 提示怎么验、怎么跑
    local owner="${OWNER:-}"
    if [ -z "$owner" ]; then
        owner="$(stat -c %U "$PROJECT_DIR" 2>/dev/null || true)"
    fi
    if [ -z "$owner" ] || [ "$owner" = "root" ]; then
        owner="<业务用户>"
    fi

    step "全部就绪"
    say "JDK        : $JDK_HOME"
    say "Gradle     : $GRADLE_HOME"
    say "Android SDK: $SDK_HOME"
    printf '\n接下来用 %s 执行编译打包：\n' "$owner"
    printf '  cd %s && sh pack.sh\n\n' "$PROJECT_DIR"
}

main "$@"
