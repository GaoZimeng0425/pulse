#!/bin/sh
# Pulse/Resources/SystemTrash/pulse-system-trash.sh 的行为测试(p7-cleaner/05)。
# 不提权、不要密码:合成夹具 + 只在非 root 生效的自测开关,把「哪些形状放行、哪些拒绝、
# 年龄复核、硬链接不碰、改归属、改不成就放回、脚本级失败整批没动、不靠 PATH 找命令」
# 逐条钉住。这是个以 root 身份移动文件的脚本,复核规则一改必须有测试红。全部在临时
# 目录里(暂存目录也指到临时目录里),整轮 <3s。须以普通用户运行(root 运行时脚本不认
# 自测开关)。
#
# 跑不了的一截(如实记):「root 属主的文件被放行」——普通用户建不出 root 属主的夹具,
# 自测开关让「属主 = 调用者」等价放行,非 root 属主被拒由不带开关的那轮钉住;真实提权
# 路径归用户目验。「改归属」本身测得到:夹具先把文件改到别的组,跑完必须回到调用者的组。
#
# Usage: sh scripts/test-system-trash.sh
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/Pulse/Resources/SystemTrash/pulse-system-trash.sh"
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
staging_parent="$fx/staging"
out="$fx/out.tsv"
err="$fx/err.log"
now=$(date +%s)
tab=$(printf '\t')

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
other="$fx/other"

write_manifest() { # 余下每个参数一行
    : > "$fx/manifest"
    for entry in "$@"; do
        printf '%s\n' "$entry" >> "$fx/manifest"
    done
}

# 跑被测脚本。$1 = 清单文件  $2 = 1 = 认调用者属主(自测开关)  $3(可选)= chown 替身的路径
run_script() {
    PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" \
        PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED="$2" \
        PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" \
        PULSE_SYSTEM_TRASH_TEST_CHOWN="${3:-}" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" "$1" "$uid" > "$out" 2> "$err"
    status=$?
    staging=$(awk -F'\t' '$1 == "STAGING" { print $2 }' "$out")
}

assert_staging_cleaned() { # $1 = 标签:暂存目录一个不剩(脚本没交接给任何人)
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
# 夹具硬链接到一个无关紧要的 root 文件 /etc/hosts——只增减链接,不改它的内容。
make_fixture
before_group=$(/usr/bin/stat -f %g /etc/hosts)
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
assert_eq "root 文件的组没变" "$(/usr/bin/stat -f %g /etc/hosts)" "$before_group"
rm "$reports/root-file.diag"
assert_eq "清理夹具后 root 文件的链接数回到 1" "$(/usr/bin/stat -f %l /etc/hosts)" "1"

# ── 4. 改不了归属:放回原处,按跳过报 ──
make_fixture
printf '#!/bin/sh\nexit 1\n' > "$fx/chown-fails"
chmod +x "$fx/chown-fails"
write_manifest "$reports/old.diag" "$reports/old.ips"
run_script "$fx/manifest" 1 "$fx/chown-fails"

assert_status "改不了归属:走完" 0
assert_eq "改不了归属:逐项跳过" "$(cat "$out")" "$(
    line SKIPPED "$reports/old.diag" ownership-not-changed
    line SKIPPED "$reports/old.ips" ownership-not-changed
)"
assert_untouched "改不了归属"
assert_eq "改不了归属:原属主与组原样" "$(/usr/bin/stat -f '%u:%g' "$reports/old.diag")" "$uid:12"
assert_staging_cleaned "改不了归属"

# ── 5. 交接失败(脚本级):已改过归属的先改回去,再放回原处,整批没动 ──
make_fixture
# 替身:第一次(文件)成功,第二次(暂存目录)失败。单引号是有意的:要生成的是一段脚本。
# shellcheck disable=SC2016
printf '#!/bin/sh\ncount_file="%s/chown-calls"\ncount=$(cat "$count_file" 2> /dev/null || echo 0)\ncount=$((count + 1))\necho "$count" > "$count_file"\n[ "$count" -eq 1 ]\n' "$fx" > "$fx/chown-handoff-fails"
chmod +x "$fx/chown-handoff-fails"
write_manifest "$reports/old.diag"
run_script "$fx/manifest" 1 "$fx/chown-handoff-fails"

assert_status "交接失败:通道不可用" 2
assert_channel_unavailable "交接失败"
assert_eq "交接失败:没有回传已移走" "$(cat "$out")" ""
assert_exists "交接失败:文件放回了原处" "$reports/old.diag"
assert_eq "交接失败:属主与组改回了原样" "$(/usr/bin/stat -f '%u:%g' "$reports/old.diag")" "$uid:12"
assert_staging_cleaned "交接失败"

# ── 6. 空清单:什么都不动 ──
make_fixture
write_manifest
run_script "$fx/manifest" 1

assert_status "空清单:走完" 0
assert_eq "空清单:没有结果行" "$(cat "$out")" ""
assert_untouched "空清单"
assert_staging_cleaned "空清单"

# ── 7. 不靠 PATH 找命令:PATH 上摆满假的同名命令,脚本一个都不该用 ──
make_fixture
mkdir -p "$fx/fake-bin"
for command in stat mv chown chmod date mktemp id tr rmdir; do
    printf '#!/bin/sh\necho used >> "%s/fake-commands-used"\nexit 1\n' "$fx" > "$fx/fake-bin/$command"
    chmod +x "$fx/fake-bin/$command"
done
write_manifest "$reports/old.diag"
PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" \
    PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
    PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" \
    PULSE_SYSTEM_TRASH_TEST_CHOWN="" PATH="$fx/fake-bin" /bin/sh "$script" "$fx/manifest" "$uid" > "$out" 2> "$err"
status=$?
assert_status "PATH 上全是假命令:照常走完" 0
assert_missing "PATH 上全是假命令:一个假命令都没被用" "$fx/fake-commands-used"
assert_missing "PATH 上全是假命令:文件照样离开原处" "$reports/old.diag"
staging=$(awk -F'\t' '$1 == "STAGING" { print $2 }' "$out")
assert_exists "PATH 上全是假命令:文件照样进了暂存目录" "$staging/old.diag"

# ── 8. 脚本级失败:整批没动 ──
# 对照组:同一份夹具、入参齐全时走得通——后面的失败不是夹具自身的问题。
make_fixture
write_manifest "$reports/old.diag" "$reports/old.ips"
run_script "$fx/manifest" 1
assert_status "对照组:入参齐全时走完" 0

# 8a 入参:缺失 / 多一个(多出来的入参会被忽略成「目标目录」之类的旧语义,一律拒)
make_fixture
write_manifest "$reports/old.diag" "$reports/old.ips"
PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" > "$out" 2> "$err"
status=$?
assert_status "入参缺失:通道不可用" 2
assert_channel_unavailable "入参缺失"
assert_untouched "入参缺失"

PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
    PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" PULSE_SYSTEM_TRASH_TEST_CHOWN="" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" "$fx/manifest" "$uid" "extra" > "$out" 2> "$err"
status=$?
assert_status "多一个入参:通道不可用" 2
assert_channel_unavailable "多一个入参"
assert_untouched "多一个入参"

# 8b 清单文件:不是绝对路径 / 不存在 / 是符号链接
make_fixture
write_manifest "$reports/old.diag"
(
    cd "$fx" || exit 1
    PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
        PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" PULSE_SYSTEM_TRASH_TEST_CHOWN="" \
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

# 8c 调用者 uid:不是普通用户,或冒用另一个普通用户的身份(清单文件的属主对不上)
make_fixture
write_manifest "$reports/old.diag" "$reports/old.ips"
for bogus_uid in 0 499 abc $((uid + 1)); do
    PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
        PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" PULSE_SYSTEM_TRASH_TEST_CHOWN="" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" "$fx/manifest" "$bogus_uid" > "$out" 2> "$err"
    status=$?
    assert_status "调用者 uid = $bogus_uid:通道不可用" 2
    assert_channel_unavailable "调用者 uid = $bogus_uid"
    assert_untouched "调用者 uid = $bogus_uid"
done

# 8d 登记的目录:是符号链接 / 不存在
make_fixture
ln -s reports "$fx/reports-link"
PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$fx/reports-link" PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
    PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" PULSE_SYSTEM_TRASH_TEST_CHOWN="" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" "$fx/manifest" "$uid" > "$out" 2> "$err"
status=$?
assert_status "登记目录是符号链接:通道不可用" 2
assert_untouched "登记目录是符号链接"

PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="/nonexistent/reports" PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
    PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$staging_parent" PULSE_SYSTEM_TRASH_TEST_CHOWN="" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" "$fx/manifest" "$uid" > "$out" 2> "$err"
status=$?
assert_status "登记目录不存在:通道不可用" 2
assert_untouched "登记目录不存在"

# 8e 暂存目录建不出来
make_fixture
PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
    PULSE_SYSTEM_TRASH_TEST_STAGING_PARENT="$fx/no-such-parent" PULSE_SYSTEM_TRASH_TEST_CHOWN="" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh "$script" "$fx/manifest" "$uid" > "$out" 2> "$err"
status=$?
assert_status "暂存目录建不出来:通道不可用" 2
assert_untouched "暂存目录建不出来"

# ── 收尾 ──
echo "test-system-trash: $pass 通过,$fail 失败"
[ "$fail" -eq 0 ]
