#!/bin/sh
# Pulse/Resources/SystemTrash/pulse-system-trash.sh 的行为测试(p7-cleaner/05)。
# 不提权、不要密码:合成夹具 + 只在非 root 生效的自测开关,把「哪些形状放行、哪些拒绝、
# 年龄复核、硬链接不碰、改归属、改不成就放回、脚本级失败、不靠 PATH 找命令、不怕环境里
# 导入的 shell 函数、被打断后自愈」逐条钉住。这是个以 root 身份移动文件的脚本,复核规则
# 一改必须有测试红。全部在临时目录里(暂存目录也指到临时目录里),整轮 <5s。须以普通
# 用户运行(root 运行时脚本不认自测开关)。
#
# 测不到、如实记在这里的(评审要求把「没钉住」写明白):
# · 「root 属主的文件被放行」:普通用户建不出 root 属主的夹具。自测开关让「属主 = 调用者」
#   等价放行,非 root 属主被拒由第 2 节钉住;真实提权路径归用户目验。
# · 「暂存目录与登记目录不在同一个卷」:本机没有第二个可写的卷,判定那一行没有用例。
# · 「交接失败」与「被信号打断」共用同一个退出钩子,只测了前一种。
# · 改归属、清空暂存目录这些动作在 root 下的真实表现。
#
# Usage: sh scripts/test-system-trash.sh
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
script="${PULSE_SYSTEM_TRASH_SCRIPT:-$root/Pulse/Resources/SystemTrash/pulse-system-trash.sh}"
uid=$(id -u)
gid=$(id -g)

if [ "$uid" -eq 0 ]; then
    echo "❌ test-system-trash: 须以普通用户运行(root 运行时被测脚本不认自测开关)" >&2
    exit 1
fi

tmp_parent="${TMPDIR:-/tmp}"
tmp=$(mktemp -d "${tmp_parent%/}/pulse-system-trash-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'rm -rf "$tmp"; exit 1' HUP INT TERM

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "❌ $1: $2" >&2; }
assert_eq() {
    if [ "$2" = "$3" ]; then ok; else bad "$1" "期望 [$3],实际 [$2]"; fi
}
assert_status() {
    if [ "$status" = "$2" ]; then ok; else bad "$1" "退出码应为 $2,实际 $status"; fi
}
assert_exists() { if [ -e "$2" ] || [ -L "$2" ]; then ok; else bad "$1" "应在却不在: $2"; fi; }
assert_missing() { if [ -e "$2" ] || [ -L "$2" ]; then bad "$1" "不该在却在: $2"; else ok; fi; }
assert_channel_unavailable() {
    case "$(cat "$err")" in
        *'channel-unavailable: '*) ok ;;
        *) bad "$1" "标准错误应说明通道不可用,实际: $(cat "$err")" ;;
    esac
}

# ── 夹具 ──
fx="$tmp/fx"
reports="$fx/reports"
other="$fx/other"
staging_parent="$fx/staging"
out="$fx/out.tsv"
err="$fx/err.log"
now=$(date +%s)
tab=$(printf '\t')
staging=""

# 期望结果行(三段、制表符分隔——与被测脚本的输出格式一致)
line() { printf '%s\t%s\t%s\n' "$@"; }

aged() { # $1 = 路径  $2 = 距今秒数
    : > "$1"
    touch -t "$(date -r $((now - $2)) +%Y%m%d%H%M.%S)" "$1"
}

make_fixture() {
    rm -rf "$fx"
    mkdir -p "$reports/sub" "$staging_parent" "$other"
    aged "$reports/old.diag" $((10 * 86400))
    aged "$reports/old.ips" $((30 * 86400))
    aged "$reports/almost.diag" $((7 * 86400 - 600)) # 差 10 分钟满 7 天
    aged "$reports/young.diag" 3600
    aged "$reports/old report.diag" $((10 * 86400))
    aged "$reports/.hidden.diag" $((10 * 86400))
    ln -s old.diag "$reports/Link.diag"
    aged "$reports/sub/nested.diag" $((20 * 86400))
    aged "$other/old.diag" $((20 * 86400))
    # 把一份文件改到别的组:脚本要把归属改成调用者,跑完组必须变回来——不改归属的话这里露馅。
    chgrp 12 "$reports/old.diag" 2> /dev/null || chgrp everyone "$reports/old.diag"
}

write_manifest() { # 余下每个参数一行
    : > "$fx/manifest"
    for entry in "$@"; do
        printf '%s\n' "$entry" >> "$fx/manifest"
    done
}

# 跑被测脚本。$1 = 清单文件  $2 = 1 = 认调用者属主(自测开关)  $3(可选)= 替身命令所在的目录
run_script() {
    PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" \
        PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED="$2" \
        PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" \
        PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR="${3:-}" \
        PULSE_SYSTEM_TRASH_REEXEC="" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" "$1" "$uid" > "$out" 2> "$err"
    status=$?
    staging=$(awk -F'\t' '$1 == "STAGING" { print $2 }' "$out")
}

# 替身命令目录:生成一个 sh 脚本并给它执行权限。
stand_in() { # $1 = 目录  $2 = 命令名  $3(标准输入)= 脚本正文
    mkdir -p "$1"
    cat > "$1/$2"
    chmod +x "$1/$2"
}

assert_staging_cleaned() { # $1 = 标签:暂存目录一个不剩
    assert_eq "$1:暂存目录收干净了" "$(ls -A "$staging_parent" 2> /dev/null)" ""
}

assert_untouched() { # $1 = 标签:原处都在
    assert_exists "$1:原地不动" "$reports/old.diag"
    assert_exists "$1:原地不动" "$reports/old.ips"
}

# ── 1. 形状复核:哪些放行、哪些拒绝 ──
make_fixture
aged "$reports/tab${tab}name.diag" $((10 * 86400))
write_manifest \
    "$reports/old.diag" \
    "$reports/old.ips" \
    "$reports/almost.diag" \
    "$reports/young.diag" \
    "$reports/old report.diag" \
    "$reports/.hidden.diag" \
    "$reports/Link.diag" \
    "$reports/sub/nested.diag" \
    "relative/x.diag" \
    "$reports/../x" \
    "$other/old.diag" \
    "$reports/missing.diag" \
    "$reports/sub" \
    "$reports/tab${tab}name.diag"
run_script "$fx/manifest" 1

assert_status "形状复核:走完" 0
if [ -n "$staging" ]; then ok; else bad "形状复核" "应有 STAGING 行(至少移走了一条)"; fi
assert_eq "形状复核:逐项结果(跳过的与清单同序;交接后才是暂存目录与已移走的)" "$(cat "$out")" "$(
    line SKIPPED "$reports/almost.diag" too-young
    line SKIPPED "$reports/young.diag" too-young
    line SKIPPED "$reports/.hidden.diag" hidden-file
    line SKIPPED "$reports/Link.diag" symlink
    line SKIPPED "$reports/sub/nested.diag" not-direct-child
    line SKIPPED relative/x.diag not-absolute
    line SKIPPED "$reports/../x" contains-dotdot
    line SKIPPED "$other/old.diag" outside-registered-directory
    line SKIPPED "$reports/missing.diag" not-a-regular-file
    line SKIPPED "$reports/sub" not-a-regular-file
    printf 'STAGING\t%s\n' "$staging"
    line MOVED "$reports/old.diag" "$staging/old.diag"
    line MOVED "$reports/old.ips" "$staging/old.ips"
    line MOVED "$reports/old report.diag" "$staging/old report.diag"
)"
# 带制表符的条目没法进制表符分隔的结果行:不进标准输出,标准错误留一行。
assert_eq "形状复核:标准错误只有带制表符条目的那一行" "$(cat "$err")" "warning: unsupported-name (tab): $reports/tab?name.diag"

# 放行的:原处没了、在暂存目录里、归属改成了调用者(组从 12 变回调用者的组)。
for name in old.diag old.ips "old report.diag"; do
    assert_missing "放行项已离开原处" "$reports/$name"
    assert_exists "放行项进了暂存目录" "$staging/$name"
    assert_eq "放行项属主 = 调用者" "$(/usr/bin/stat -f %u "$staging/$name")" "$uid"
    assert_eq "放行项的组 = 调用者的组(改归属真的做了)" "$(/usr/bin/stat -f %g "$staging/$name")" "$gid"
done
# 交接:暂存目录归调用者、只有它进得来。
assert_eq "暂存目录属主 = 调用者" "$(/usr/bin/stat -f %u "$staging")" "$uid"
assert_eq "暂存目录权限 = 700" "$(/usr/bin/stat -f %Lp "$staging")" "700"
# 拒绝的:原地不动。
for name in almost.diag young.diag .hidden.diag Link.diag "tab${tab}name.diag"; do
    assert_exists "拒绝项原地不动" "$reports/$name"
done
assert_exists "子目录里的原地不动" "$reports/sub/nested.diag"
assert_exists "登记目录之外的原地不动" "$other/old.diag"
assert_exists "目录本身原地不动" "$reports/sub"

# 结果行可解析:制表符分隔;SKIPPED / MOVED 三段,STAGING 两段;首段只会是这三种。
if awk -F'\t' 'BEGIN { bad = 0 } ($1 == "STAGING" && NF != 2) || (($1 == "MOVED" || $1 == "SKIPPED") && NF != 3) || !($1 == "STAGING" || $1 == "MOVED" || $1 == "SKIPPED") { bad = 1 } END { exit bad }' "$out"; then
    ok
else
    bad "结果行格式" "存在段数或首段不对的结果行"
fi

# 改归属用的是 -h(只改链接本身,不跟着链接走):替身把收到的参数原样记下来再转交真的 chown。
make_fixture
stand_in "$fx/commands" chown <<'STANDIN'
#!/bin/sh
printf '%s\n' "$*" >> "$(dirname "$0")/chown-calls"
exec /usr/sbin/chown "$@"
STANDIN
write_manifest "$reports/old.diag"
run_script "$fx/manifest" 1 "$fx/commands"
assert_status "-h 标志:走完" 0
assert_eq "改归属带着 -h,属主:组 = 调用者" "$(head -n 1 "$fx/commands/chown-calls" | cut -d' ' -f 1-2)" "-h $uid:$gid"
assert_missing "-h 标志:登记的调用日志没留进暂存目录" "$staging/chown-calls"

# ── 2. 属主不是 root 或系统用户:拒绝(不带自测开关)──
make_fixture
write_manifest "$reports/old.diag" "$reports/old.ips"
run_script "$fx/manifest" 0

assert_status "属主复核:走完" 0
assert_eq "属主复核:逐项拒绝" "$(cat "$out")" "$(
    line SKIPPED "$reports/old.diag" owner-not-system
    line SKIPPED "$reports/old.ips" owner-not-system
)"
assert_untouched "属主不符"
assert_staging_cleaned "属主不符"

# ── 3. 硬链接不碰:别的路径还指着这个文件,改归属会连那份一起改 ──
make_fixture
ln "$reports/old.diag" "$reports/old-link.diag"
write_manifest "$reports/old.diag" "$reports/old-link.diag"
run_script "$fx/manifest" 1

assert_status "硬链接:走完" 0
assert_eq "硬链接:逐项拒绝" "$(cat "$out")" "$(
    line SKIPPED "$reports/old.diag" hard-linked
    line SKIPPED "$reports/old-link.diag" hard-linked
)"
assert_eq "硬链接:两处都还在,链接数仍是 2" "$(/usr/bin/stat -f %l "$reports/old.diag")" "2"
assert_exists "硬链接:第二个名字也在" "$reports/old-link.diag"
assert_staging_cleaned "硬链接"

# ── 3b. 绝不碰 root 文件的硬链接:冒充成一份过期报告放进登记目录,脚本必须原样留着 ──
# 首版脚本的提权路径就在这里:root「移过去再按路径改归属」,改到的是 inode 本身。
# 夹具硬链接到一个无关紧要的 root 文件 /etc/hosts——只增减链接,不改它的内容。链接数按
# 前后比,不写死(两个工作区同时跑检查时各有各的链接)。
make_fixture
hosts_links_before=$(/usr/bin/stat -f %l /etc/hosts)
hosts_group_before=$(/usr/bin/stat -f %g /etc/hosts)
ln /etc/hosts "$reports/root-file.diag"
write_manifest "$reports/root-file.diag" "$reports/old.diag"
run_script "$fx/manifest" 1

assert_status "root 文件的硬链接:走完" 0
assert_eq "root 文件的硬链接:只有真报告被移走" "$(cat "$out")" "$(
    line SKIPPED "$reports/root-file.diag" hard-linked
    printf 'STAGING\t%s\n' "$staging"
    line MOVED "$reports/old.diag" "$staging/old.diag"
)"
assert_exists "root 文件的硬链接:还留在登记目录里,没被拿走" "$reports/root-file.diag"
assert_eq "root 文件的属主没变" "$(/usr/bin/stat -f %u /etc/hosts)" "0"
assert_eq "root 文件的组没变" "$(/usr/bin/stat -f %g /etc/hosts)" "$hosts_group_before"
assert_eq "root 文件的链接数没变" "$(/usr/bin/stat -f %l /etc/hosts)" "$((hosts_links_before + 1))"
rm "$reports/root-file.diag"
assert_eq "清理夹具后 root 文件的链接数回到原值" "$(/usr/bin/stat -f %l /etc/hosts)" "$hosts_links_before"

# ── 4. 读不到文件的状态:不动 ──
# stat 替身:四项那一次回垃圾,其余转交真的 stat。
make_fixture
stand_in "$fx/commands" stat <<'STANDIN'
#!/bin/sh
[ "$2" = "%l %u %g %m" ] && echo "garbage" && exit 0
exec /usr/bin/stat "$@"
STANDIN
write_manifest "$reports/old.diag" "$reports/old.ips"
run_script "$fx/manifest" 1 "$fx/commands"
assert_status "读不到状态:走完" 0
assert_eq "读不到状态:逐项跳过" "$(cat "$out")" "$(
    line SKIPPED "$reports/old.diag" stat-failed
    line SKIPPED "$reports/old.ips" stat-failed
)"
assert_untouched "读不到状态"
assert_staging_cleaned "读不到状态"

# ── 5. 暂存目录里的类型判定:进了暂存目录的不是普通文件就放回 ──
# 原处的检查与移动之间,条目可以被换成符号链接。mv 替身模拟这一下:把真文件挪开,把一个
# 符号链接以同一个名字送进暂存目录。chown 替身记录调用——一次都不该有。
make_fixture
stand_in "$fx/commands" mv <<STANDIN
#!/bin/sh
if [ "\$#" -eq 2 ]; then
    case "\$2" in
        *"/pulse-system-trash."*)
            /bin/mv "\$1" "\$1.pulse-aside"
            exec /bin/mv "$reports/Link.diag" "\$2"
            ;;
    esac
fi
exec /bin/mv "\$@"
STANDIN
stand_in "$fx/commands" chown <<'STANDIN'
#!/bin/sh
echo called >> "$(dirname "$0")/chown-calls"
exec /usr/sbin/chown "$@"
STANDIN
write_manifest "$reports/old.diag"
run_script "$fx/manifest" 1 "$fx/commands"
assert_status "类型判定:走完" 0
assert_eq "类型判定:按「不是普通文件」跳过" "$(cat "$out")" "$(line SKIPPED "$reports/old.diag" not-a-regular-file)"
assert_missing "类型判定:没有调用过改归属" "$fx/commands/chown-calls"
if [ -L "$reports/old.diag" ]; then ok; else bad "类型判定" "换成符号链接的那份被放回了原处"; fi
assert_exists "类型判定:真文件只是被挪开,内容还在" "$reports/old.diag.pulse-aside"
assert_staging_cleaned "类型判定"

# ── 6. 改不了归属:放回原处,按跳过报 ──
make_fixture
stand_in "$fx/commands" chown <<'STANDIN'
#!/bin/sh
exit 1
STANDIN
write_manifest "$reports/old.diag" "$reports/old.ips"
run_script "$fx/manifest" 1 "$fx/commands"

assert_status "改不了归属:走完" 0
assert_eq "改不了归属:逐项跳过" "$(cat "$out")" "$(
    line SKIPPED "$reports/old.diag" ownership-not-changed
    line SKIPPED "$reports/old.ips" ownership-not-changed
)"
assert_untouched "改不了归属"
assert_eq "改不了归属:原属主与组原样" "$(/usr/bin/stat -f '%u:%g' "$reports/old.diag")" "$uid:12"
assert_staging_cleaned "改不了归属"

# ── 7. 交接失败(脚本级):已改过归属的先改回去,再放回原处 ──
# chown 替身:第一次(文件)转交真的 chown——归属真的被改了;第二次(暂存目录)失败。
# 单引号是有意的:要生成的是一段脚本。
# shellcheck disable=SC2016
make_fixture
stand_in "$fx/commands" chown <<STANDIN
#!/bin/sh
count_file="\$0-calls"
count=\$(cat "\$count_file" 2> /dev/null || echo 0)
count=\$((count + 1))
echo "\$count" > "\$count_file"
[ "\$count" -eq 1 ] && exec /usr/sbin/chown "\$@"
exit 1
STANDIN
write_manifest "$reports/old.diag"
run_script "$fx/manifest" 1 "$fx/commands"

assert_status "交接失败:通道不可用" 2
assert_channel_unavailable "交接失败"
assert_eq "交接失败:没有回传已移走" "$(cat "$out")" ""
assert_exists "交接失败:文件放回了原处" "$reports/old.diag"
assert_eq "交接失败:属主改回了原样、组回到了 12" "$(/usr/bin/stat -f '%u:%g' "$reports/old.diag")" "$uid:12"
assert_staging_cleaned "交接失败"

# ── 8. 同一个路径出现不止一次:第二次不碰,不盖掉已处理的那份 ──
# mv 替身:往暂存目录那一步改成复制(原处留着同名文件),于是清单的第二次原处「还在」。
make_fixture
stand_in "$fx/commands" mv <<'STANDIN'
#!/bin/sh
if [ "$#" -eq 2 ]; then
    case "$2" in
        *"/pulse-system-trash."*) exec /bin/cp -p "$1" "$2" ;;
    esac
fi
exec /bin/mv "$@"
STANDIN
write_manifest "$reports/old.diag" "$reports/old.diag"
run_script "$fx/manifest" 1 "$fx/commands"
assert_status "重复条目:走完" 0
assert_eq "重复条目:第一次移走,第二次按重复跳过" "$(cat "$out")" "$(
    line SKIPPED "$reports/old.diag" duplicate
    printf 'STAGING\t%s\n' "$staging"
    line MOVED "$reports/old.diag" "$staging/old.diag"
)"
assert_exists "重复条目:暂存目录里只有一份" "$staging/old.diag"

# ── 9. 放不回原处:如实报,不谎报「没动」 ──
# 原处在这一轮里又有了同名条目(mv 替身把「往暂存目录那一步」改成复制,原处留着),被拒的
# 条目放不回去。
make_fixture
stand_in "$fx/commands" mv <<'STANDIN'
#!/bin/sh
if [ "$#" -eq 2 ]; then
    case "$2" in
        *"/pulse-system-trash."*) exec /bin/cp -p "$1" "$2" ;;
    esac
fi
exec /bin/mv -n "$@"
STANDIN
write_manifest "$reports/young.diag"
run_script "$fx/manifest" 1 "$fx/commands"
assert_status "放不回原处:走完" 0
assert_eq "放不回原处:原因代码是 not-restored" "$(cat "$out")" "$(line SKIPPED "$reports/young.diag" not-restored)"
assert_eq "放不回原处:一条都没交接,标准输出里没有 STAGING" "$staging" ""
for leftover in "$staging_parent"/pulse-system-trash.*; do
    break
done
assert_exists "放不回原处:条目留在暂存目录里等下一次自愈" "$leftover/young.diag"

# ── 10. 自愈:上一次被打断留下的暂存目录,条目按原名放回 ──
make_fixture
mkdir -p "$staging_parent/pulse-system-trash.Stale" "$staging_parent/pulse-system-trash.Fresh"
aged "$staging_parent/pulse-system-trash.Stale/lost.diag" $((20 * 86400))
touch -t "$(date -r $((now - 1200)) +%Y%m%d%H%M.%S)" "$staging_parent/pulse-system-trash.Stale"
aged "$staging_parent/pulse-system-trash.Fresh/fresh.diag" 3600
write_manifest "$reports/old.diag"
run_script "$fx/manifest" 1
assert_status "自愈:走完" 0
assert_exists "自愈:旧暂存目录里的条目放回了登记目录" "$reports/lost.diag"
assert_missing "自愈:放空的旧暂存目录收掉" "$staging_parent/pulse-system-trash.Stale"
assert_exists "自愈:刚建的暂存目录不动" "$staging_parent/pulse-system-trash.Fresh/fresh.diag"
assert_eq "自愈:这一轮自己照常交接" "$(awk -F'\t' '$1 == "MOVED" { print $2 }' "$out")" "$reports/old.diag"
rm -rf "$staging_parent/pulse-system-trash.Fresh"

# ── 11. 空清单:什么都不动 ──
make_fixture
write_manifest
run_script "$fx/manifest" 1

assert_status "空清单:走完" 0
assert_eq "空清单:没有结果行" "$(cat "$out")" ""
assert_untouched "空清单"
assert_staging_cleaned "空清单"

# ── 12. 不靠 PATH 找命令:PATH 上摆满假的同名命令,脚本一个都不该用 ──
make_fixture
mkdir -p "$fx/fake-bin"
for command in stat mv chown chmod date mktemp id tr rmdir env; do
    printf '#!/bin/sh\necho used >> "%s/fake-commands-used"\nexit 1\n' "$fx" > "$fx/fake-bin/$command"
    chmod +x "$fx/fake-bin/$command"
done
write_manifest "$reports/old.diag"
PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" \
    PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
    PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" \
    PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR="" \
    PULSE_SYSTEM_TRASH_REEXEC="" PATH="$fx/fake-bin" /bin/sh "$script" "$fx/manifest" "$uid" > "$out" 2> "$err"
status=$?
assert_status "PATH 上全是假命令:照常走完" 0
assert_missing "PATH 上全是假命令:一个假命令都没被用" "$fx/fake-commands-used"
assert_missing "PATH 上全是假命令:文件照样离开原处" "$reports/old.diag"
staging=$(awk -F'\t' '$1 == "STAGING" { print $2 }' "$out")
assert_exists "PATH 上全是假命令:文件照样进了暂存目录" "$staging/old.diag"

# ── 13. 环境里导入的 shell 函数顶替不了内建命令 ──
# 调用方导出一个同名函数,内建 printf 会被顶替(bash 从环境导入函数)。脚本第一句在干净的
# 环境里重跑自己,所以照常工作;预先伪造「已重跑过」的标记也不管用。两种各跑一遍。
for marker in "" "yes"; do
    make_fixture
    write_manifest "$reports/old.diag"
    # shellcheck disable=SC2016
    cat > "$fx/launch-shadowed.sh" <<STANDIN
#!/bin/bash
printf() { echo "REPLACED printf" >> "$fx/replaced"; return 1; }
export -f printf
export PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1
export PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR=""
export PULSE_SYSTEM_TRASH_REEXEC="$marker"
exec /bin/sh "$script" "$fx/manifest" "$uid"
STANDIN
    chmod +x "$fx/launch-shadowed.sh"
    "$fx/launch-shadowed.sh" > "$out" 2> "$err"
    status=$?
    staging=$(awk -F'\t' '$1 == "STAGING" { print $2 }' "$out")
    assert_status "函数顶替(标记=[$marker]):照常走完" 0
    assert_missing "函数顶替(标记=[$marker]):内建 printf 没被顶替" "$fx/replaced"
    assert_exists "函数顶替(标记=[$marker]):文件照样进了暂存目录" "$staging/old.diag"
done

# ── 14. 脚本级失败:整批没动 ──
# 对照组:同一份夹具、入参齐全时走得通——后面的失败不是夹具自身的问题。
make_fixture
write_manifest "$reports/old.diag" "$reports/old.ips"
run_script "$fx/manifest" 1
assert_status "对照组:入参齐全时走完" 0

# 14a 入参:缺失 / 多一个
make_fixture
write_manifest "$reports/old.diag" "$reports/old.ips"
PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" > "$out" 2> "$err"
status=$?
assert_status "入参缺失:通道不可用" 2
assert_channel_unavailable "入参缺失"
assert_untouched "入参缺失"

PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
    PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR="" \
    PULSE_SYSTEM_TRASH_REEXEC="" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" "$fx/manifest" "$uid" "extra" > "$out" 2> "$err"
status=$?
assert_status "多一个入参:通道不可用" 2
assert_channel_unavailable "多一个入参"
assert_untouched "多一个入参"

# 14b 清单文件:不是绝对路径 / 不存在 / 是符号链接
make_fixture
write_manifest "$reports/old.diag"
(
    cd "$fx" || exit 1
    PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
        PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR="" \
        PULSE_SYSTEM_TRASH_REEXEC="" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" manifest "$uid" > "$out" 2> "$err"
)
status=$?
assert_status "相对路径的清单文件:通道不可用" 2
assert_channel_unavailable "相对路径的清单文件"
assert_untouched "相对路径的清单文件"

run_script "$fx/missing-manifest" 1
assert_status "清单文件不存在:通道不可用" 2
assert_untouched "清单文件不存在"

ln -s manifest "$fx/manifest-link"
run_script "$fx/manifest-link" 1
assert_status "清单文件是符号链接:通道不可用" 2
assert_untouched "清单文件是符号链接"

# 14c 调用者 uid:不是普通用户,或冒用另一个普通用户的身份。三处核对(清单属主 / 查得到
#    调用者)至少有一处对不上即可——黑盒只钉住「对不上就被拒」,不钉是哪一处。
make_fixture
write_manifest "$reports/old.diag" "$reports/old.ips"
for bogus_uid in 0 499 abc $((uid + 1)); do
    PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
        PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR="" \
        PULSE_SYSTEM_TRASH_REEXEC="" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" "$fx/manifest" "$bogus_uid" > "$out" 2> "$err"
    status=$?
    assert_status "调用者 uid = $bogus_uid:通道不可用" 2
    assert_channel_unavailable "调用者 uid = $bogus_uid"
    assert_untouched "调用者 uid = $bogus_uid"
done

# 14d 登记的目录:是符号链接 / 不存在(清单文件要在:少了它,脚本会停在「清单文件读不了」,
#     这两条就蒙混过去了)
make_fixture
write_manifest "$reports/old.diag" "$reports/old.ips"
ln -s reports "$fx/reports-link"
PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$fx/reports-link" PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
    PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR="" \
    PULSE_SYSTEM_TRASH_REEXEC="" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" "$fx/manifest" "$uid" > "$out" 2> "$err"
status=$?
assert_status "登记目录是符号链接:通道不可用" 2
assert_untouched "登记目录是符号链接"

PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="/nonexistent/reports" PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
    PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR="" \
    PULSE_SYSTEM_TRASH_REEXEC="" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" "$fx/manifest" "$uid" > "$out" 2> "$err"
status=$?
assert_status "登记目录不存在:通道不可用" 2
assert_untouched "登记目录不存在"

# 14e 暂存目录建不出来(清单文件同样要在)
make_fixture
write_manifest "$reports/old.diag" "$reports/old.ips"
PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
    PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$fx/no-such-parent" PULSE_SYSTEM_TRASH_TEST_COMMANDS_DIR="" \
    PULSE_SYSTEM_TRASH_REEXEC="" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" "$fx/manifest" "$uid" > "$out" 2> "$err"
status=$?
assert_status "暂存目录建不出来:通道不可用" 2
assert_untouched "暂存目录建不出来"

# ── 收尾 ──
echo "test-system-trash: $pass 通过,$fail 失败"
[ "$fail" -eq 0 ]
