#!/bin/sh
# Pulse/Resources/SystemTrash/pulse-system-trash.sh 的行为测试(p7-cleaner/05)。
# 不提权、不要密码:合成夹具 + 只在非 root 生效的自测开关,把「哪些形状放行、哪些拒绝、
# 年龄复核、移动与归属、逐项结果、脚本级失败整批没动」逐条钉住。这是个以 root 身份移动
# 文件的脚本,复核规则一改必须有测试红。全部在临时目录里,整轮 <2s。须以普通用户运行
# (root 运行时脚本不认自测开关)。
#
# 跑不了的一截(如实记):「root 属主的文件被放行」与「改归属」本身——普通用户建不出 root
# 属主的夹具。自测开关让「属主 = 调用者」等价放行;非 root 属主被拒由不带开关的那轮钉住。
# 真实提权路径归用户目验。
#
# Usage: sh scripts/test-system-trash.sh
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/Pulse/Resources/SystemTrash/pulse-system-trash.sh"
uid=$(id -u)

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
        'channel-unavailable: '*) ok ;;
        *) bad "$1" "标准错误应说明通道不可用,实际: $(cat "$err")" ;;
    esac
}

# ── 夹具 ──
fx="$tmp/fx"
reports="$fx/reports"
trash="$fx/home/.Trash"
target="$trash/Pulse 系统级/stamp"
other="$fx/other"
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
    mkdir -p "$reports/sub" "$target" "$other"
    aged "$reports/old.diag" $((10 * 86400))
    aged "$reports/old.ips" $((30 * 86400))
    aged "$reports/almost.diag" $((7 * 86400 - 600)) # 差 10 分钟满 7 天
    aged "$reports/young.diag" 3600
    aged "$reports/old report.diag" $((10 * 86400))
    aged "$reports/.hidden.diag" $((10 * 86400))
    ln -s old.diag "$reports/Link.diag"
    aged "$reports/sub/nested.diag" $((20 * 86400))
    aged "$other/old.diag" $((20 * 86400))
}

write_manifest() { # 余下每个参数一行
    : > "$fx/manifest"
    for entry in "$@"; do
        printf '%s\n' "$entry" >> "$fx/manifest"
    done
}

# 跑被测脚本。$1 = 清单文件  $2 = 目标目录  $3 = 1 = 认调用者属主(自测开关);入参走全局。
run_script() {
    PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" \
        PULSE_SYSTEM_TRASH_TEST_TRASH_ROOT="$trash" \
        PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED="$3" \
        /bin/sh "$script" "$1" "$uid" "$2" > "$out" 2> "$err"
    status=$?
}

assert_untouched() { # $1 = 标签:原处都在、目标目录里什么都没进来
    assert_exists "$1:原地不动" "$reports/old.diag"
    assert_exists "$1:原地不动" "$reports/old.ips"
    assert_missing "$1:目标目录里什么都没进来" "$target/old.diag"
    assert_missing "$1:目标目录里什么都没进来" "$target/old.ips"
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
run_script "$fx/manifest" "$target" 1

assert_status "形状复核:走完" 0
expected="$(
    line MOVED "$reports/old.diag" "$target/old.diag"
    line MOVED "$reports/old.ips" "$target/old.ips"
    line SKIPPED "$reports/almost.diag" too-young
    line SKIPPED "$reports/young.diag" too-young
    line MOVED "$reports/old report.diag" "$target/old report.diag"
    line SKIPPED "$reports/.hidden.diag" hidden-file
    line SKIPPED "$reports/Link.diag" symlink
    line SKIPPED "$reports/sub/nested.diag" not-direct-child
    line SKIPPED relative/x.diag not-absolute
    line SKIPPED "$reports/../x" contains-dotdot
    line SKIPPED "$other/old.diag" outside-registered-directory
    line SKIPPED "$reports/missing.diag" not-a-regular-file
    line SKIPPED "$reports/sub" not-a-regular-file
)"
assert_eq "形状复核:逐项结果(与清单同序)" "$(cat "$out")" "$expected"
# 带制表符的条目没法进制表符分隔的结果行:不进标准输出,标准错误留一行。
assert_eq "形状复核:标准错误只有带制表符条目的那一行" "$(cat "$err")" "warning: unsupported-name (tab): $reports/tab?name.diag"

# 放行的:原处没了、废纸篓子目录里有、归属是调用者。
for name in old.diag old.ips "old report.diag"; do
    assert_missing "放行项已离开原处" "$reports/$name"
    assert_exists "放行项进了废纸篓子目录" "$target/$name"
    assert_eq "放行项归属 = 调用者" "$(stat -f %u "$target/$name")" "$uid"
done
# 拒绝的:原地不动。
for name in almost.diag young.diag .hidden.diag Link.diag "tab${tab}name.diag"; do
    assert_exists "拒绝项原地不动" "$reports/$name"
done
assert_exists "子目录里的原地不动" "$reports/sub/nested.diag"
assert_exists "登记目录之外的原地不动" "$other/old.diag"
assert_exists "目录本身原地不动" "$reports/sub"

# 结果行可解析:每行三段、制表符分隔,首段只会是 MOVED / SKIPPED。
if awk -F'\t' 'BEGIN { bad = 0 } NF != 3 || !($1 == "MOVED" || $1 == "SKIPPED") { bad = 1 } END { exit bad }' "$out"; then
    ok
else
    bad "结果行格式" "存在不是「三段、首段为 MOVED / SKIPPED」的行"
fi

# ── 2. 属主不是 root 或系统用户:拒绝(不带自测开关)──
make_fixture
write_manifest "$reports/old.diag" "$reports/old.ips"
run_script "$fx/manifest" "$target" 0

assert_status "属主复核:走完" 0
assert_eq "属主复核:逐项拒绝" "$(cat "$out")" "$(
    line SKIPPED "$reports/old.diag" owner-not-system
    line SKIPPED "$reports/old.ips" owner-not-system
)"
assert_exists "属主不符的原地不动" "$reports/old.diag"
assert_exists "属主不符的原地不动" "$reports/old.ips"
assert_missing "一个都没移走:空的目标目录被收掉" "$target"

# ── 3. 目标已存在则加序号,绝不覆盖 ──
make_fixture
printf 'keep me\n' > "$target/old.diag"
write_manifest "$reports/old.diag"
run_script "$fx/manifest" "$target" 1

assert_status "加序号:走完" 0
assert_eq "加序号:去向带序号" "$(cat "$out")" "$(line MOVED "$reports/old.diag" "$target/old.diag.1")"
assert_eq "加序号:原有的没被覆盖" "$(cat "$target/old.diag")" "keep me"
assert_exists "加序号:新来的落在带序号的名字上" "$target/old.diag.1"

# ── 4. 空清单:什么都不动,空的目标目录收掉 ──
make_fixture
write_manifest
run_script "$fx/manifest" "$target" 1

assert_status "空清单:走完" 0
assert_eq "空清单:没有结果行" "$(cat "$out")" ""
assert_exists "空清单:原地不动" "$reports/old.diag"
assert_missing "空清单:空的目标目录被收掉" "$target"

# ── 5. 脚本级失败:整批没动 ──
# 对照组:同一份夹具、入参齐全时走得通——后面的失败不是夹具自身的问题。
make_fixture
write_manifest "$reports/old.diag" "$reports/old.ips"
run_script "$fx/manifest" "$target" 1
assert_status "对照组:入参齐全时走完" 0

# 5a 入参缺失
make_fixture
write_manifest "$reports/old.diag" "$reports/old.ips"
/bin/sh "$script" > "$out" 2> "$err"
status=$?
assert_status "入参缺失:通道不可用" 2
assert_channel_unavailable "入参缺失"
assert_untouched "入参缺失"

# 5b 清单文件:不是绝对路径 / 不存在 / 是符号链接
make_fixture
write_manifest "$reports/old.diag"
(
    cd "$fx" || exit 1
    PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" PULSE_SYSTEM_TRASH_TEST_TRASH_ROOT="$trash" \
        PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 /bin/sh "$script" manifest "$uid" "$target" > "$out" 2> "$err"
)
status=$?
assert_status "相对路径的清单文件:通道不可用" 2
assert_channel_unavailable "相对路径的清单文件"
assert_untouched "相对路径的清单文件"

run_script "$fx/missing-manifest" "$target" 1
assert_status "清单文件不存在:通道不可用" 2
assert_channel_unavailable "清单文件不存在"
assert_untouched "清单文件不存在"

ln -s manifest "$fx/manifest-link"
run_script "$fx/manifest-link" "$target" 1
assert_status "清单文件是符号链接:通道不可用" 2
assert_channel_unavailable "清单文件是符号链接"
assert_untouched "清单文件是符号链接"

# 5c 调用者 uid:不是普通用户,或冒用另一个普通用户的身份(清单文件、废纸篓、目标目录
#    至少有一处不属于那个 uid——三处核对互为等价防线,黑盒只能钉住「对不上就被拒」)。
for bogus_uid in 0 499 abc $((uid + 1)); do
    PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$reports" PULSE_SYSTEM_TRASH_TEST_TRASH_ROOT="$trash" \
        PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
        /bin/sh "$script" "$fx/manifest" "$bogus_uid" "$target" > "$out" 2> "$err"
    status=$?
    assert_status "调用者 uid = $bogus_uid:通道不可用" 2
    assert_channel_unavailable "调用者 uid = $bogus_uid"
    assert_untouched "调用者 uid = $bogus_uid"
done

# 5d 登记的目录是符号链接
ln -s reports "$fx/reports-link"
PULSE_SYSTEM_TRASH_TEST_REPORTS_DIR="$fx/reports-link" PULSE_SYSTEM_TRASH_TEST_TRASH_ROOT="$trash" \
    PULSE_SYSTEM_TRASH_TEST_ALLOW_CALLER_OWNED=1 \
    /bin/sh "$script" "$fx/manifest" "$uid" "$target" > "$out" 2> "$err"
status=$?
assert_status "登记目录是符号链接:通道不可用" 2
assert_channel_unavailable "登记目录是符号链接"
assert_untouched "登记目录是符号链接"

# 5e 目标目录:不在废纸篓里(目录要真建出来,不然脚本会在后面一步「目录不存在」才停,
#    测不到「必须在废纸篓里」这条规则)/ 不存在 / 含 ..
make_fixture
mkdir -p "$other/stamp"
write_manifest "$reports/old.diag" "$reports/old.ips"
run_script "$fx/manifest" "$other/stamp" 1
assert_status "目标目录不在废纸篓里:通道不可用" 2
assert_channel_unavailable "目标目录不在废纸篓里"
assert_untouched "目标目录不在废纸篓里"

run_script "$fx/manifest" "$trash/Pulse 系统级/not-created" 1
assert_status "目标目录不存在:通道不可用" 2
assert_channel_unavailable "目标目录不存在"
assert_untouched "目标目录不存在"

run_script "$fx/manifest" "$trash/../escape" 1
assert_status "目标目录含 ..:通道不可用" 2
assert_channel_unavailable "目标目录含 .."
assert_untouched "目标目录含 .."

# ── 收尾 ──
echo "test-system-trash: $pass 通过,$fail 失败"
[ "$fail" -eq 0 ]
