#!/bin/sh
# OpenWrt / iStoreOS / ImmortalWrt. Run with BusyBox ash.
set -eu
export LC_ALL=C

repo=wkccd/CloudRunFilesBuilder
mirror_list=https://yishijie.gitlab.io/ziyuan/gh.txt
verbose=0
if [ "${1:-}" = --verbose ]; then verbose=1; shift; fi
detail() { if [ "$verbose" -eq 1 ]; then printf '%s\n' "$*"; fi; }
die() { printf '%s\n' "$*" >&2; exit 1; }
usage() {
    echo '用法: sh openwrt-plugin-install.sh [--verbose] [--info | --list | --dry-run 插件 | 插件]'
    echo '插件: passwall passwall2 openclash ssrp nikki homeproxy dae'
    echo '不带参数打开交互菜单。--dry-run 只查询和匹配，不安装。'
}
case "${1:-}" in -h|--help) usage; exit 0;; esac

release_field() {
    awk -F= -v key="$1" '$1 == key {gsub(/["\047]/, "", $2); print $2; exit}' /etc/openwrt_release
}
echo '[1/7] 正在识别路由器系统、固件版本和安装类型（本机检查，通常几秒）…'
[ -r /etc/openwrt_release ] || die '找不到 OpenWrt 固件信息。'
distro=$(release_field DISTRIB_ID)
version=$(release_field DISTRIB_RELEASE)
target=$(release_field DISTRIB_TARGET)
arch=$(release_field DISTRIB_ARCH)
case "$version" in
    24.*) manager=opkg ;;
    25.12|25.12.*|25.12-*) manager=apk ;;
    *) die "固件 $version 未在支持范围内（24.x / 25.12.x）。" ;;
esac
command -v "$manager" >/dev/null || die "固件版本 $version 对应 $manager，但系统中找不到该命令。"
if [ "$manager" = apk ]; then
    package_arch=$(apk --print-arch)
    [ -n "$arch" ] || arch=$package_arch
    [ "$arch" = "$package_arch" ] || die "固件架构 $arch 与 apk 架构 $package_arch 不一致。"
else
    accepted=$(opkg print-architecture)
    [ -n "$arch" ] || arch=$(printf '%s\n' "$accepted" |
        awk '$1=="arch" && $2!="all" && $2!="noarch" {print $3, $2}' |
        sort -rn | awk 'NR==1 {print $2}')
    printf '%s\n' "$accepted" | awk -v a="$arch" '$1=="arch" && $2==a {ok=1} END {exit !ok}' ||
        die "opkg 软件源未声明架构 $arch。"
fi
case "$arch" in ''|*[!A-Za-z0-9_-]*|all|noarch) die '无法识别软件包架构。';; esac
printf '      已识别 %s %s，安装包类型已自动匹配。\n' "$distro" "$version"
if [ "${1:-}" = --info ] || [ "$verbose" -eq 1 ]; then
    printf '固件 %s %s | 目标 %s | 内核 %s | 包架构 %s | %s\n' \
        "$distro" "$version" "$target" "$(uname -m)" "$arch" "$manager"
fi
[ "${1:-}" != --info ] || exit 0

mode=${1:-}
plugin=$mode
case "$mode" in
    --dry-run) [ "$#" -eq 2 ] || die '请指定要预检的插件。'; plugin=$2 ;;
    *) [ "$#" -le 1 ] || die '参数过多，请使用 --help。' ;;
esac
case "$plugin" in ''|--list|passwall|passwall2|openclash|ssrp|nikki|homeproxy|dae) ;; *) usage; exit 1;; esac
for cmd in curl jsonfilter sha256sum base64; do
    command -v "$cmd" >/dev/null || die "缺少 $cmd。请用 $manager 从固件软件源安装所缺命令。"
done
work=$(mktemp -d /tmp/ow-plugin.XXXXXX)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fetch() {
    curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 5 "$@"
}
api="https://api.github.com/repos/$repo/releases/latest"
read_release() {
    source=$1
    number=$2
    path="$work/release-$number"
    if [ "$source" = direct ]; then request=$api; else request="$source/$api"; fi
    elapsed=$(fetch --max-time 8 --max-filesize 2097152 -w '%{time_total}' \
        -o "$path.json" "$request" 2>/dev/null) || return 0
    release_tag=$(jsonfilter -i "$path.json" -e '@.tag_name' 2>/dev/null) || return 0
    case "$release_tag" in ????-??-??) ;; *) return 0;; esac
    case "$release_tag" in *[!0-9-]*) return 0;; esac
    jsonfilter -i "$path.json" -e '@.assets[*].name' > "$path.assets" 2>/dev/null || return 0
    [ -s "$path.assets" ] || return 0
    printf '%s %s %s %s\n' "$elapsed" "$number" "$source" "$release_tag"
}

# Encoding keeps the built-in list compact and is not a secret.
builtin=$(printf '%s' 'aHR0cHM6Ly9naC1wcm94eS5jb20KaHR0cHM6Ly9naGZhc3QudG9wCmh0dHBzOi8vZ2hwcm94eS5uZXQKaHR0cHM6Ly9mYXN0Z2l0LmNjCg==' | base64 -d)
load_mirrors() {
    [ ! -f "$work/mirrors" ] || return 0
    : > "$work/mirrors"
    if fetch --max-time 4 --max-filesize 65536 -o "$work/mirror-list" "$mirror_list" 2>/dev/null; then
        awk -v builtin="$builtin" 'BEGIN {
            n=split(builtin, nodes)
            for (i=1; i<=n; i++) seen[nodes[i]]=1
        }
        {
            gsub(/^[[:space:]]+|[[:space:]\/]+$/, "")
            host=tolower($0)
            if (host ~ /^https:\/\/[a-z0-9][a-z0-9.-]*\.[a-z][a-z]+$/ && !seen[host]++) {
                print host
                if (++count == 12) exit
            }
        }' "$work/mirror-list" > "$work/mirrors"
    fi
}

query_group() {
    (
        number=0
        for mirror do
            number=$((number+1))
            read_release "$mirror" "$number" &
        done
        wait
    ) > "$work/releases"
    sort -n "$work/releases" | head -n 1 > "$work/selected"
}

echo '[2/7] 正在测速并查询最新版（4 条优选线路并行，最多约 8 秒）…'
release_group=builtin
query_group $builtin
if [ ! -s "$work/selected" ]; then
    echo '      常用线路查询失败，尝试网站候选（最多约 12 秒）…'
    load_mirrors
    release_group=website
    query_group $(cat "$work/mirrors")
fi
if [ ! -s "$work/selected" ]; then
    echo '      加速查询失败，尝试 GitHub 直连（最多约 8 秒）…'
    release_group=direct
    query_group direct
fi
if read -r elapsed number metadata_source tag < "$work/selected"; then
    mv "$work/release-$number.json" "$work/release.json"
    mv "$work/release-$number.assets" "$work/assets"
else
    metadata_source=direct
    tag=
    : > "$work/assets"
fi
detail "发布信息来源 $metadata_source"
printf '\nOpenWrt 插件安装助手\n\n'

find_asset() {
    awk -v plugin="$1" -v arch="$arch" -v manager="$manager" '
        /\.run$/ {
            name=tolower($0)
            apk=(name ~ /^25[-_]/)
            if ((manager=="apk") != apk) next
            sub(/^(24|25)[-_]/, "", name)
            sub(/^luci-app-/, "", name)
            if (plugin=="ssrp" && name ~ /^shadowsocksr[-_]/) sub(/^shadowsocksr/, "ssrp", name)
            if (plugin=="dae") sub(/^openwrt-daede[-_]/, "dae-", name)
            gsub(/aarch64_a53/, "aarch64_cortex-a53", name)
            gsub(/x86-64/, "x86_64", name)
            if (name !~ ("^" plugin "[-_]")) next
            if (name ~ ("[-_]" arch "([-_.]|$)")) print $0
        }
    ' "${2:-$work/assets}"
}
plugin_name() {
    case "$1" in
        passwall) echo PassWall;; passwall2) echo PassWall2;; openclash) echo OpenClash;;
        ssrp) echo SSRP;; nikki) echo Nikki;; homeproxy) echo HomeProxy;; dae) echo dae;;
    esac
}
asset_version() {
    printf '%s\n' "$1" | awk -v arch="$arch" '{
        name=tolower($0)
        sub(/\.run$/, "", name)
        sub(/^(24|25)[-_]/, "", name)
        sub(/^luci-app-/, "", name)
        gsub(/aarch64_a53/, "aarch64_cortex-a53", name)
        gsub(/x86-64/, "x86_64", name)
        gsub(/aarch64_a72/, "aarch64_cortex-a72", name)
        sub(/_all_sdk_[0-9.]+$/, "", name)
        sub(/[+](aarch64|x86_64)_core_sdk_[0-9.]+$/, "", name)
        sub(/^openwrt-nikki_/, "nikki_", name)
        sub(/^ssr-plus_/, "ssrp_", name)
        sub(/^daede_/, "dae_", name)
        sub("[-_]" arch, "", name)
        sub(/^(openwrt-daede|ssrp[-_]mihomo|shadowsocksr|passwall2?|openclash|nikki|homeproxy|ssrp|dae)[-_]/, "", name)
        gsub(/_/, "-", name)
        if (name ~ /^v?[0-9]/) print name
        else print "最新发布"
    }'
}
are_repo=bcseputetto/Are-u-ok
are_tag=
case "$version" in
    24.10|24.10.*|24.10-*) are_tag=iStoreOS_24.10 ;;
    25.12|25.12.*|25.12-*) are_tag=iStoreOS_25.12 ;;
esac

load_are_release() {
    [ -n "$are_tag" ] || return 0
    echo "正在查询优先来源 Are-u-ok（$are_tag）…"
    are_api="https://api.github.com/repos/$are_repo/releases/tags/$are_tag"
    for are_source in "$metadata_source" direct; do
        request=$are_api
        [ "$are_source" = direct ] || request="$are_source/$are_api"
        if fetch --max-time 8 --max-filesize 4194304 -o "$work/are.json" "$request" 2>/dev/null &&
           [ "$(jsonfilter -i "$work/are.json" -e '@.tag_name' 2>/dev/null)" = "$are_tag" ] &&
           jsonfilter -i "$work/are.json" -e '@.assets[*].name' > "$work/are.assets" 2>/dev/null &&
           [ -s "$work/are.assets" ]; then
            return 0
        fi
        [ "$are_source" != direct ] || break
    done
    : > "$work/are.assets"
    echo 'Are-u-ok 查询未成功，使用 CloudRunFilesBuilder。'
}

find_are_asset() {
    [ -s "$work/are.assets" ] || return 0
    candidate=$(awk -v plugin="$1" -v arch="$arch" -v sdk="${are_tag#iStoreOS_}" '
        {
            name=tolower($0)
            sub(/^openwrt-nikki_/, "nikki_", name)
            sub(/^ssr-plus_/, "ssrp_", name)
            sub(/^daede_/, "dae_", name)
            gsub(/aarch64_a53/, "aarch64_cortex-a53", name)
            gsub(/aarch64_a72/, "aarch64_cortex-a72", name)
            if (name !~ ("^" plugin "_") || substr(name, length(name)-length(sdk)-8) != ("_sdk_" sdk ".run")) next
            if (name ~ ("_" arch "_all_sdk_")) print $0
            else if (plugin=="openclash" && ((arch ~ /^aarch64_/ && name ~ /[+]aarch64_core_sdk_/) ||
                     (arch=="x86_64" && name ~ /[+]x86_64_core_sdk_/))) print $0
        }' "$work/are.assets")
    case "$candidate" in ''|*[!A-Za-z0-9._+-]*) return 0;; esac
    candidate_digest=$(jsonfilter -i "$work/are.json" -e "@.assets[@.name=\"$candidate\"].digest" 2>/dev/null) || return 0
    printf '%s\n' "$candidate_digest" | awk '/^sha256:[0-9a-f]+$/ && length($0)==71 {ok=1} END {exit !ok}' || return 0
    printf '%s\n' "$candidate"
}

load_are_release
[ -s "$work/assets" ] || [ -s "$work/are.assets" ] ||
    die '两个软件包来源都无法查询，请稍后重试。'

# Query one bounded page only when a requested plugin is missing.
lookup_history() {
    [ -n "$tag" ] || return 0
    for item do
        [ -z "$(find_are_asset "$item")$(find_asset "$item")" ] && break
    done
    [ -z "$(find_are_asset "$item")$(find_asset "$item")" ] || return 0
    echo '部分插件缺包，正在查询最近 10 期发布（每条线路最多约 8 秒）…'
    history_url="https://api.github.com/repos/$repo/releases?per_page=10"
    history_ok=0
    for source in "$metadata_source" direct; do
        request=$history_url
        [ "$source" = direct ] || request="$source/$history_url"
        if fetch --max-time 8 --max-filesize 4194304 -o "$work/history.json" "$request" 2>/dev/null &&
           first_tag=$(jsonfilter -i "$work/history.json" -e '@[0].tag_name' 2>/dev/null) &&
           [ -n "$first_tag" ]; then
            history_ok=1
            break
        fi
        [ "$source" != direct ] || break
        echo '加速线路未返回有效历史清单，尝试 GitHub 直连…'
    done
    if [ "$history_ok" -eq 0 ]; then
        echo '历史清单查询失败，仅显示当前发布的匹配结果。'
        return 0
    fi
    history_count=0
    index=0
    while [ "$index" -lt 10 ]; do
        if ! jsonfilter -i "$work/history.json" -e "@[$index]" > "$work/history-item.json" 2>/dev/null ||
           [ ! -s "$work/history-item.json" ]; then
            break
        fi
        index=$((index+1))
        old_tag=$(jsonfilter -i "$work/history-item.json" -e '@.tag_name' 2>/dev/null) || continue
        case "$old_tag" in ????-??-??) ;; *) continue;; esac
        case "$old_tag" in *[!0-9-]*) continue;; esac
        [ "$(printf '%s\n' "$tag" "$old_tag" | sort -u | head -n 1)" = "$old_tag" ] &&
            [ "$old_tag" != "$tag" ] || continue
        [ "$(jsonfilter -i "$work/history-item.json" -e '@.prerelease')" = false ] || continue
        jsonfilter -i "$work/history-item.json" -e '@.assets[*].name' > "$work/old-$old_tag.assets" 2>/dev/null || continue
        cp "$work/history-item.json" "$work/old-$old_tag.json"
        history_count=$((history_count+1))
    done
    printf '历史清单查询成功，已读取 %s 期较早的正式发布。\n' "$history_count"
}

resolve_asset() {
    asset_repo=$repo
    asset_source=$metadata_source
    asset=$(find_are_asset "$1")
    if [ -n "$asset" ]; then
        asset_repo=$are_repo
        asset_source=$are_source
        asset_tag=$are_tag
        asset_json="$work/are.json"
        return 0
    fi
    asset_tag=$tag
    asset_json="$work/release.json"
    asset=$(find_asset "$1")
    [ -z "$asset" ] || return 0
    for old_tag in $(printf '%s\n' "$work"/old-*.json | sort -r); do
        [ -f "$old_tag" ] || continue
        matches=$(find_asset "$1" "${old_tag%.json}.assets")
        case "$matches" in ''|*[!A-Za-z0-9._+-]*) continue;; esac
        old_digest=$(jsonfilter -i "$old_tag" -e "@.assets[@.name=\"$matches\"].digest" 2>/dev/null) || continue
        printf '%s\n' "$old_digest" | awk '/^sha256:[0-9a-f]+$/ && length($0)==71 {ok=1} END {exit !ok}' || continue
        asset=$matches
        asset_json=$old_tag
        asset_tag=${old_tag##*/old-}
        asset_tag=${asset_tag%.json}
        break
    done
}

if [ -z "$plugin" ] || [ "$mode" = --list ]; then
    lookup_history passwall passwall2 openclash ssrp nikki homeproxy dae
else
    lookup_history "$plugin"
fi

show_menu() {
    number=0
    for item in passwall passwall2 openclash ssrp nikki homeproxy dae; do
        number=$((number+1))
        resolve_asset "$item"
        matches=$asset
        label=$(plugin_name "$item")
        case "$matches" in
            ''|*[!A-Za-z0-9._+-]*) printf '%s) %-10s 暂无可用版本\n' "$number" "$label" ;;
            *) if [ "$asset_repo" = "$are_repo" ]; then
                   printf '%s) %-10s %s（Are-u-ok）\n' "$number" "$label" "$(asset_version "$matches")"
               elif [ "$asset_tag" = "$tag" ]; then
                   printf '%s) %-10s 最新版 %s\n' "$number" "$label" "$(asset_version "$matches")"
               else
                   printf '%s) %-10s %s（历史发布 %s）\n' "$number" "$label" "$(asset_version "$matches")" "$asset_tag"
               fi
               detail "   $matches" ;;
        esac
    done
}
if [ -z "$plugin" ] || [ "$mode" = --list ]; then
    show_menu
    [ "$mode" != --list ] || exit 0
    printf '选择要安装或更新的插件（0 退出）: '
    read -r choice || exit 0
    case "$choice" in
        0) exit 0;; 1) plugin=passwall;; 2) plugin=passwall2;; 3) plugin=openclash;;
        4) plugin=ssrp;; 5) plugin=nikki;; 6) plugin=homeproxy;; 7) plugin=dae;;
        *) die '无效选项。';;
    esac
fi
resolve_asset "$plugin"
case "$asset" in
    '') die "最近查询的发布中没有 $plugin 的 $manager / $arch 安装包。" ;;
    *[!A-Za-z0-9._+-]*) die '有多个匹配包或包名异常，停止自动安装。' ;;
esac
digest=$(jsonfilter -i "$asset_json" -e "@.assets[@.name=\"$asset\"].digest")
size=$(jsonfilter -i "$asset_json" -e "@.assets[@.name=\"$asset\"].size")
case "$size" in ''|*[!0-9]*) die '发布元数据缺少有效文件大小。';; esac
sha=${digest#sha256:}
case "$sha" in *[!0-9a-f]*) die 'SHA-256 格式无效。';; esac
[ "$digest" = "sha256:$sha" ] && [ "${#sha}" -eq 64 ] || die 'GitHub 没有提供 SHA-256，停止。'
url="https://github.com/$asset_repo/releases/download/$asset_tag/$asset"
printf '%s %s（发布 %s）\n' "$(plugin_name "$plugin")" "$(asset_version "$asset")" "$asset_tag"
detail "文件 $asset ($size 字节)
$url
SHA-256 $sha"
[ "$mode" != --dry-run ] || exit 0
[ "$(id -u)" -eq 0 ] || die '请以 root 用户运行安装。'
available=$(df -Pk "$work" | awk 'END {print $4}')
[ "$available" -ge "$(( (size + 1023) / 1024 ))" ] || die '/tmp 可用空间不足以保存下载包。'

# The digest comes from the selected release metadata source.
# Probe real release bytes, bound request sizes, and rank by measured throughput.
probe() {
    endpoint=$1
    if [ "$endpoint" = direct ]; then link=$url; else link="$endpoint/$url"; fi
    stats=$(fetch --max-time 6 --max-filesize 262144 --range 0-262143 \
        -o /dev/null -w '%{http_code} %{size_download} %{speed_download}' "$link" 2>/dev/null) || return 0
    set -- $stats
    expected=262144
    [ "$size" -ge "$expected" ] || expected=$size
    [ "$2" = "$expected" ] || return 0
    case "$1" in 206) ;; 200) [ "$2" = "$size" ] || return 0;; *) return 0;; esac
    printf '%s %s\n' "$3" "$endpoint"
}

echo '[3/7] 等待确认，确认后开始测速和下载。'
if [ "$asset_source" != direct ]; then
    printf '版本信息和校验值来自第三方加速节点 %s。\n' "$asset_source"
    echo '仅在信任该节点时继续安装。'
fi
printf '安装或更新这个插件？输入 y 继续，回车取消: '
read -r answer || exit 0
case "$answer" in y|Y) ;; *) exit 0;; esac
pick_mirror() {
    (
        for mirror do
            probe "$mirror" &
        done
        wait
    ) > "$work/speeds"
    sort -rn "$work/speeds" > "$work/ranked"
    awk 'NR==1 {print $2}' "$work/ranked"
}

file="$work/$asset"
download_package() {
    endpoint=$1
    if [ "$endpoint" = direct ]; then link=$url; else link="$endpoint/$url"; fi
    echo '      单条线路最多 5 分钟。'
    detail "下载来源 $endpoint"
    echo '      进度看 %，实时速度看右侧 Current Speed，预计剩余时间看 Left。'
    if curl -fL --proto '=https' --proto-redir '=https' --connect-timeout 5 \
        --max-time 300 --max-filesize "$size" -o "$file" "$link"; then
        echo '      下载完成，正在校验文件（通常几秒）…'
        if [ "$(wc -c < "$file" | tr -d ' ')" = "$size" ] &&
           printf '%s  %s\n' "$sha" "$file" | sha256sum -c - >"$work/checksum" 2>&1; then
            return 0
        fi
        echo '      文件校验失败。'
    fi
    rm -f "$file"
    return 1
}

if [ "$asset_source" = direct ]; then
    echo '[4/7] 加速查询未成功，使用 GitHub 直连。'
else
    echo '[4/7] 已选出查询最快的可用线路，将沿用该线路下载。'
fi
echo '[5/7] 正在下载安装包…'
downloaded=0
if download_package "$asset_source"; then
    downloaded=1
elif [ "$asset_source" != direct ] && [ "$release_group" = builtin ]; then
    echo '      优选线路下载未完成，尝试网站候选（测速最多约 10 秒）…'
    load_mirrors
    best=$(pick_mirror $(cat "$work/mirrors"))
    if [ -n "$best" ] && download_package "$best"; then
        downloaded=1
    fi
fi
if [ "$downloaded" -eq 0 ] && [ "$asset_source" != direct ]; then
    echo '      加速下载未完成，尝试 GitHub 直连一次。'
    if download_package direct; then
        downloaded=1
    fi
fi
[ "$downloaded" -eq 1 ] || die 'GitHub 直连下载失败或校验未通过，本次安装结束。'

echo '[6/7] 文件校验通过，正在备份路由器配置（通常几秒）…'
# Store the configuration outside /tmp so the backup survives a reboot.
umask 077
backup_dir=$(mktemp -d /root/openwrt-plugin-backup.XXXXXX)
tar -czf "$backup_dir/config.tar.gz" -C /etc config ||
    die "配置备份失败，停止安装。目录 $backup_dir"
detail "配置备份 $backup_dir/config.tar.gz"
echo '[7/7] 正在安装插件。安装时间取决于路由器和依赖下载，请等待下方安装输出。'
(cd "$work" && sh "./$asset") || die "安装失败。配置备份在 $backup_dir。"
echo '安装程序已运行完毕，请刷新路由器后台查看。'
