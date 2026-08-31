#!/bin/bash
# posctrl.sh — prove each guard can actually go red. / 逐条证明守卫会红。
#
# WHY THIS FILE EXISTS / 为什么有这个文件
# ----------------------------------------------------------------------
# `quota-sentinel.test.sh` being green tells you that nothing is currently broken. It
# does not tell you that any of it would notice if something were. A guard that cannot
# fail is indistinguishable, on a green run, from a guard that is working — and every
# guard in this project exists because something once actually broke.
# 回归全绿只说明「此刻没坏」，不说明「坏了会被发现」。在一次绿色运行里，一条**不可能失败**
# 的守卫和一条正常工作的守卫长得一模一样——而本项目每一条守卫背后都有一次真实事故。
#
# So: for each guard, take a copy of the repository, break exactly the thing that guard
# is watching, re-run the suite against the copy, and require that the **named** case
# goes red. Not "the run failed" — that could be anything; the specific assertion has to
# be the one that fires.
# 因此：逐条守卫，复制一份仓库，**只**弄坏它盯着的那件事，对副本重跑回归，并要求**点名的**
# 那条用例变红。不是「这次跑挂了」——那可能是任何原因；必须是那一条断言响。
#
# ⚠️ Nothing here touches the working repository. Every mutation happens inside a
#    throwaway copy under $TMP, and the copy is what gets run.
# ⚠️ 本文件不碰工作仓：每一处改动都发生在 $TMP 下的一次性副本里，跑的也是那份副本。
#
# ⚠️ Read the negative control at the bottom before trusting any of it: an unmutated
#    copy must come out GREEN. Without that, "everything went red" would look like
#    perfect discriminating power while actually meaning the harness breaks every copy.
# ⚠️ 信任本文件之前先看末尾那条负控：**未改动的副本必须全绿**。没有它，「全都红了」
#    看起来像分辨力满分，实际可能只是说明这套脚手架把每一份副本都弄坏了。
#
# Usage / 用法:
#   bash test/posctrl.sh            run every ablation / 跑全部消融
#   bash test/posctrl.sh <id>...    run only these / 只跑这几条

set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/quota-sentinel-posctrl.XXXXXX") || {
  printf 'aborting: could not create a temporary directory under %s\n' "${TMPDIR:-/tmp}" >&2
  exit 3; }
# ⚠️ Check the value too, not just the exit status. An unchecked `mktemp` that fails
#    leaves TMP empty, and every "$TMP/x" below then becomes "/x" — an absolute path in
#    the filesystem root. The suite does not crash: it runs, writes its files there, and
#    reports a plausible-looking `PASS 172  FAIL 15`. ⭐ The scaffolding failing is then
#    indistinguishable from the code under test failing, which is the more expensive of
#    the two ways to be wrong. (Measured 2026-08-28: 53 files created under `/`.)
#    The `/*/*` shape rejects both "" and "/".
# ⚠️ 不只看退出码，还要看值。没检查的 mktemp 失败之后 TMP 是空串，下面每个 "$TMP/x"
#    都变成 "/x"——文件系统根目录下的绝对路径。套件不会崩，它照跑、把文件写在那里，
#    然后报出一个看着很像回事的 `PASS 172  FAIL 15`。⭐ 于是**脚手架坏了**和**被测代码
#    坏了**长得一模一样，而前者是两种错法里更贵的那一种。（2026-08-28 实测：`/` 下建了
#    53 个文件。）`/*/*` 这个形状同时排除空串与 "/"。
[[ -d "$TMP" && "$TMP" == /*/* ]] || {
  printf 'aborting: TMP is not a usable directory (%s); refusing to run\n' "${TMP:-<empty>}" >&2
  exit 3; }
trap 'rm -rf "$TMP"' EXIT
WANT=("$@")

OK=0; BAD=0
# For these ablations the correct behaviour is to ABORT, so they additionally require zero
# PASS/FAIL counter lines in the output.
# 这些消融的正确表现是「中止」，额外要求输出里零 PASS/FAIL 计数行。
MUST_ABORT="tmp-mktemp-failure tmp-value-unusable"
declare -a ROWS=()

# ablate <id> <guard being proved> <layer> <expected text in the FAIL line> <mutator...>
# The mutator runs with $C set to the copy's root and may edit anything inside it.
ablate() {
  local id="$1" guard="$2" layer="$3" expect="$4"; shift 4
  if (( ${#WANT[@]} )); then
    local want found=0 w
    for w in "${WANT[@]}"; do [[ "$w" == "$id" ]] && found=1; done
    (( found )) || return 0
  fi
  local C="$TMP/$id"
  rm -rf "$C"; mkdir -p "$C"
  cp -r "$ROOT/lib" "$ROOT/test" "$ROOT/quota-sentinel" "$ROOT/account-probe" "$ROOT/account-switch" "$C/" 2>/dev/null
  ( C="$C"; "$@" ) || { printf 'ERROR %-22s the mutation itself failed to apply\n' "$id"; BAD=$((BAD+1)); return 0; }
  local out rc
  out=$(cd "$C" && bash "$C/test/quota-sentinel.test.sh" "$layer" 2>&1); rc=$?
  local hit=""
  # ⚠️ here-string, never `printf … | grep -Fq`. This line ADJUDICATES whether each
  #    ablation went red, and under `set -o pipefail` (set at the top of this file) the
  #    very mechanism these ablations certify would corrupt the verdict: `grep -Fq` exits
  #    on its first match, `printf` dies of SIGPIPE, the pipeline reports 141, and a
  #    genuinely RED ablation gets recorded as MISS. Measured on this exact shape:
  #    0–7.8% depending on machine load, worst when the expected FAIL line appears early.
  # ⚠️ 用 here-string，绝不用 `printf … | grep -Fq`。**这一行是给每条消融判红没红的那一行**，
  #    而本文件开着 pipefail ⇒ 这些消融要证明的那个机制，恰好会污染它自己的裁决：
  #    真红的消融被记成 MISS。同一形状实测漏判 0–7.8%（随负载），命中越靠前越容易漏。
  if grep -Fq -- "$expect" <<<"$out"; then hit=1; fi
  # ⚠️ For some ablations the correct behaviour is to ABORT, not "one assertion goes red".
  #    For those, an exit code plus a keyword is not enough -- before the hardening the
  #    exit code was already non-zero, so an expectation written only as "exit code is
  #    non-zero" passes either way. The extra requirement: **not one PASS/FAIL may be
  #    produced**.
  # ⚠️ 有些消融的正确表现是「中止」而不是「某条断言变红」。对这些，光有退出码和关键字还不够
  #    ——未加固时退出码本来就是非 0。额外要求：**一条 PASS/FAIL 都不许产生**。
  case " $MUST_ABORT " in
    *" $id "*)
      if grep -qE '^  (PASS|FAIL) |^PASS [0-9]+ ' <<<"$out"; then
        hit=""; printf '        (%s 要求「中止且零断言」，但输出里出现了断言计数行)\n' "$id"
      fi ;;
  esac
  if (( rc != 0 )) && [[ -n "$hit" ]]; then
    printf 'RED   %-22s %s\n' "$id" "$guard"
    ROWS+=("$id|$guard|RED (rc=$rc)")
    OK=$((OK+1))
  else
    printf 'MISS  %-22s %s\n' "$id" "$guard"
    printf '        expected a failure mentioning: %s\n' "$expect"
    printf '        run exit code: %s ; matched: %s\n' "$rc" "${hit:-no}"
    printf '        tail: %s\n' "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    ROWS+=("$id|$guard|MISS")
    BAD=$((BAD+1))
  fi
}

# ── mutators / 改动手法 ────────────────────────────────────────────────
m_sed()  { local f="$1" from="$2" to="$3"
           grep -Fq -- "$from" "$C/$f" || { echo "anchor not found in $f: $from" >&2; return 1; }
           python3 - "$C/$f" "$from" "$to" <<'PY'
import sys
p,a,b=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p).read(); assert a in s
open(p,'w').write(s.replace(a,b,1))
PY
         }
m_drop() { local f="$1" pat="$2"
           grep -qE -- "$pat" "$C/$f" || { echo "nothing to drop in $f: $pat" >&2; return 1; }
           grep -vE -- "$pat" "$C/$f" > "$C/$f.new" && mv "$C/$f.new" "$C/$f"; }
m_append(){ printf '%s\n' "$2" >> "$C/$1"; }
m_sed_all(){ local f="$1" from="$2" to="$3"
           grep -Fq -- "$from" "$C/$f" || { echo "anchor not found in $f: $from" >&2; return 1; }
           python3 - "$C/$f" "$from" "$to" <<'EDIT'
import sys
p,a,b=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p).read(); assert a in s
open(p,'w').write(s.replace(a,b))
EDIT
         }
# ⚠️ After editing the frozen control group, the copy's declared checksum has to be
#    recomputed -- otherwise the hash guard fires first and the run never reaches the
#    detector assertion we are trying to prove. That is not a workaround, it is the
#    documented boundary of what a checksum proves: it catches an edit, it cannot catch
#    an edit that was accompanied by a matching hash update. These ablations deliberately
#    play the second role, so that the DETECTOR assertions get exercised too.
# ⚠️ 改完冻结对照组必须把副本里声明的哈希一起重算——否则哈希闸先响，跑不到我们要证明的
#    那条判据。这不是绕过，正是「哈希能证明什么」的边界：它抓得住「被改过」，抓不住
#    「改了并且顺手把哈希也改对了」。这几条消融刻意扮演后者，好让**判据本身**也被验到。
m_refreeze(){
  local f="$C/test/fixtures/legacy-detectors.sh" new
  new=$(bash -c 'source "$1"; printf "%s\n" "$QS_LEGACY_SRC" | sha256sum | cut -d" " -f1' _ "$f")
  python3 - "$f" "$new" <<'REFREEZE'
import sys,re
p,h=sys.argv[1],sys.argv[2]
s=open(p).read()
s=re.sub(r'QS_LEGACY_SHA256=[0-9a-f]{64}', 'QS_LEGACY_SHA256='+h, s)
open(p,'w').write(s)
REFREEZE
}
# m_frozen <from> <to> — edit the frozen control group AND update its declared hash,
# so the run gets past the integrity guard and reaches the detector assertion.
m_frozen(){ m_sed test/fixtures/legacy-detectors.sh "$1" "$2" && m_refreeze; }
# m_tmp_badparent / m_tmp_badvalue — break ONLY the "obtain a temp directory" step and
# **keep both gates in place**.
# ⭐ The first version removed the gates outright, so the copy ran happily, wrote files into
#   `/`, and the ablation scored MISS. Removing a guard shows "what it looks like with no
#   guard", not "whether the guard fires". An ablation mutates the TRIGGERING CONDITION,
#   never the guard itself.
# m_switch_noreadback — remove BOTH identity checks after a switch: removing only one leaves
# the other still catching it, so the ablation goes green while the guard it certifies has
# quietly lost half of itself.
# m_tmp_badparent / m_tmp_badvalue — 只弄坏「取得临时目录」这一步，**保留那两道闸**。
# ⭐ 第一版我把闸整个拆了，于是副本照跑、把文件写进 `/`，而消融被判 MISS ——
#   拆掉守卫得到的是「没有守卫时的样子」，不是「守卫会不会响」。消融要动的是**触发条件**，
#   不是守卫本身。（那一版实测又在 `/` 下留了 54 项，已逐项清掉；见交付报告。）
# m_switch_noreadback — 把切号后的**两条**身份校验一起拿掉。只拿掉一条时另一条仍抓得住，
# 消融会绿，而它要证明的那道守卫其实已经少了一半。「消融这道守卫」指的是整道。
m_switch_noreadback(){
  m_sed lib/switch.sh \
    'if [[ "$now_email" != "$to" || -z "$now_uuid" ]]; then' \
    'if false; then' || return 1
  m_sed lib/switch.sh \
    'if [[ -n "$before_email" && "$before_email" != "$to"' \
    'if false && [[ -n "$before_email" && "$before_email" != "$to"' || return 1
}

m_tmp_badparent(){   # mktemp 失败 ⇒ 第一道闸（退出码）响
  m_sed test/quota-sentinel.test.sh \
    'TMP=$(mktemp -d "${TMPDIR:-/tmp}/quota-sentinel-test.XXXXXX")' \
    'TMP=$(mktemp -d "/nonexistent-parent-dir/quota-sentinel-test.XXXXXX" 2>/dev/null)'
}
m_tmp_badvalue(){    # mktemp「成功」但给出不可用的值 ⇒ 第二道闸（值）响
  m_sed test/quota-sentinel.test.sh \
    'TMP=$(mktemp -d "${TMPDIR:-/tmp}/quota-sentinel-test.XXXXXX")' \
    'TMP=$(printf /)'
}

# m_second_sink / m_stdout_sink — 给落账函数**加一条真实的第二出口**，帧照样从别处出去。
# ⭐ 动的是触发条件（多了一个出口），不是断言：断言一个字没改。
# ⚠️ 用专用 mutator 而不是 m_sed：要插入的是**带换行的多行文本**，从 shell 传过去会被
#    展开或截断；锚点与插入体都写在 python 里就没有这一层。
# m_second_sink / m_stdout_sink — add a REAL second exit to the logging function, so the
# frame leaves by another route. ⭐ The triggering condition is mutated (one more exit),
# never the assertion. A dedicated mutator, not m_sed, because the inserted text is
# multi-line and would not survive the shell.
_m_insert_sink(){
  python3 - "$C/lib/state.sh" "$1" <<'MUT'
import sys
p, sink = sys.argv[1], sys.argv[2]
anchor = '  quota_panel_observations_prune_if_due "$observed" || true\n'
s = open(p).read()
assert s.count(anchor) == 1, "anchor not unique in lib/state.sh"
open(p, 'w').write(s.replace(anchor, sink + anchor, 1))
MUT
}
# ① 另一个文件：正是 2026-08-31 review 用来证伪「任何口子」那句声称的那条注入。
# ① Another file: exactly the injection the 2026-08-31 review used to disprove
#    the "through any route" claim.
m_second_sink(){ _m_insert_sink '  printf '"'"'%s\n'"'"' "$frame" >> "$QUOTA_LOG"\n'; }
# ② stdout：写文件是一种出口，打印出来是另一种。断言把 stdout/stderr 也收了，这条证明那一格。
# ② stdout: printing is a second kind of exit. The assertion captures stdout/stderr; this
#    ablation is what proves that half is not decoration.
m_stdout_sink(){ _m_insert_sink '  printf '"'"'%s\n'"'"' "$frame"\n'; }

# ══ 1. the frozen control group / 冻结对照组 ══════════════════════════════
ablate frozen-control-edited \
  "冻结对照组被改动时整套回归拒绝开跑（哈希断言）" --fast \
  "the frozen control group has been modified" \
  m_sed test/fixtures/legacy-detectors.sh \
    "USAGE_MENU_FOOTER_REGEX='Enter to confirm.*Esc to cancel'" \
    "USAGE_MENU_FOOTER_REGEX='Enter to confirm.*Esc to CANCEL'"

# ══ 2–4. the three incident reproductions / 三次事故的复现 ═══════════════
# 让旧判据也认得出新文案 ⇒「28 天哑掉」那条复现不出来，用例必须自己报「没复现原缺陷」
ablate p1-menu-wording \
  "P1 选单文案事故：对照组必须在新文案上失效" --fast \
  "对照组应当在新文案上失效" \
  m_frozen \
    "USAGE_MENU_OPT2_REGEX='2\\.[[:space:]]+Switch to usage credits'" \
    "USAGE_MENU_OPT2_REGEX='2\\.[[:space:]]+'"

# Make the legacy banner test unable to match a user message => the self-trigger incident
# can no longer be reproduced.
# 让旧横幅判据抓不到用户消息 ⇒ 自激事故复现不出来
ablate p3-banner-selftrigger \
  "P3 横幅自激事故：对照组必须被用户消息触发" --fast \
  "对照组没被触发" \
  m_frozen \
    'USAGE_BANNER_REGEX="You.{0,3}ve hit your [A-Za-z0-9 -]*limit"' \
    'USAGE_BANNER_REGEX="__never_matches_anything__"'

# Give the legacy parser a time zone it CAN resolve => the 8-hour offset can no longer be
# reproduced.
# 给旧解析器一个能解析的时区 ⇒ 8 小时偏差复现不出来
ablate p5-timezone-offset \
  "P5 缺时区 8 小时偏差：对照组必须复现它" --fast \
  "对照组未复现 8 小时偏差" \
  m_frozen \
    '[[ -n "$tz" ]] || tz=$(date +%Z)' \
    '[[ -n "$tz" ]] || tz=CST-8'

# 兜底时区自检：把 quota_tz_spec_usable 退回 2026-08-31 之前那版「只要能取到 %z 就放行」，
# 也就是让 `+0000` 重新算合法值。那正是裸缩写的降级结果 ⇒ 事故 (a) 原样复活。
# ⚠️ 这条消融动的是**触发条件**（哪些规格算可用），不是把守卫整个拆掉：函数仍在、仍被调用、
#    仍会对取不到偏移量的情况返回失败——只是恢复了那条恒真的判据。
ablate tz-spec-bare-abbrev \
  "兜底 TZ 是裸缩写时必须判解析失败，不许静默当 UTC" --fast \
  "被当成可用时区" \
  m_sed lib/config.sh \
    '  [[ -z "$spec" ]] && return 0' \
    '  return 0'

# ⚠️ 上面那条消融动的是**冻结对照组**，证明的是「对照组会复现 8 小时偏差」。它不覆盖
#    出厂渲染函数 `lib/state.sh :: quota_fmt_ts()`——2026-08-31 实测：把 quota_fmt_ts
#    改回 `TZ=$QUOTA_TZ_LABEL date -d @ts`（事故 (a) 的写法，本机把 08:26 渲染成
#    00:26），对照组那条消融照常绿、整套回归也照常 PASS 197 FAIL 0。
#    ⭐ 「守卫存在」与「守卫被证明会红」是两件事，这一格补的是后者。
ablate fmtts-zonedb-render \
  "渲染时刻必须是 UTC 渲染 + 偏移量算术，不许在渲染时查时区库" --fast \
  "差 8 小时正是事故 (a) 的形状" \
  m_sed lib/state.sh \
    'date -u -d "@$(( ts + QUOTA_TZ_OFFSET_SEC ))" "+$fmt"' \
    'TZ="$QUOTA_TZ_LABEL" date -d "@$ts" "+$fmt"'

# ══ 4b. 跨主体累加 / cross-subject accumulation ═════════════════════════
# 事故：累加两个窗口的增量算换算常数，首次实测算出 −0.434（物理上不可能，两个窗口都
# 只会涨）。根因是样本里混进了监控还挂在**上一个账号**时的读数。守卫是
# `lib/state.sh :: quota_ratio_update()` 里的 `l_acct == acct`。
# ⚠️ 2026-08-31 之前这个函数在整套回归里**只被打桩、从未被真实调用**：把它整个掏空成
#    `return 0` 之后套件仍然 PASS 197 FAIL 0 ⇒ 守卫在纸面上存在、在任何机器上恒绿。
ablate ratio-cross-subject \
  "换算常数的增量只能在同一主体内累加，跨账号必须断开" --fast \
  "跨账号的差值被累加进了同一个常数" \
  m_sed lib/state.sh \
    '"$l_acct" == "$acct" && ' \
    ''

# ══ 5. the construction-time leak assertion / 构造期泄漏断言 ═════════════
ablate state-dir-leak \
  "构造期断言：任何 QUOTA_* 路径指进真状态目录就中止" --fast \
  "point at real files outside the sandbox" \
  m_append lib/config.sh 'QUOTA_POSCTRL_LEAK_PROBE="${XDG_STATE_HOME:-$HOME/.local/state}/quota-sentinel/posctrl-probe"'

# ══ 6. the tmux gate / tmux 隔离闸 ═══════════════════════════════════════
ablate tmux-gate-blind \
  "隔离闸必须抓得住 send-keys（2026-08-19 动了生产会话）" --fast \
  "闸抓不住 send-keys" \
  m_sed_all test/quota-sentinel.test.sh \
    '>> "$TMUX_VIOLATIONS"' \
    '>> /dev/null'

# ══ 7. extraction integrity / 抽取完整性 ═════════════════════════════════
ablate config-symbol-missing \
  "被读到的配置变量必须真的有定义（缺了会在 set -u 下杀进程）" --fast \
  "set -u 下会当场退出" \
  m_drop lib/config.sh '^QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL='

# ⭐ 这一条守的是**长命进程**的 argv：statusLine 归属四值一旦改回位置参数，就会躺进
#    monitor CLI 的 `--settings`，在整个会话期间对任意用户可读。消融手法就是把它改回去。
# ⭐ This one guards a LONG-LIVED process argv: revert the statusLine ownership values to
#    positional arguments and they land inside the monitor CLI `--settings`, readable by
#    any user for the whole session. The ablation is exactly that reversion.
# ⚠️ 用专用 mutator 而不是 m_sed：要替换的两行同时含 `$self` `%q` 与单双引号，
#    从 shell 里传过去必然被展开或被截断。锚点写在 python 里就没有这一层。
# ⚠️ A dedicated mutator, not m_sed: both lines contain `$self`, `%q` and mixed quotes,
#    so passing them through the shell would expand or truncate them. Anchoring inside
#    python removes that layer entirely.
m_statusline_positional() {
  python3 - "$C/lib/reading.sh" <<'MUT'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
a = '''  printf -v ingest '%q shadow-statusline-ingest --owner-file %q' "$self" "$owner_file"'''
b = '''  printf -v ingest '%q shadow-statusline-ingest %q %q %q %q' \\
    "$self" "$email" "$uuid" "$generation" "$launch_id"'''
assert s.count(a) == 1, "anchor count %d" % s.count(a)
open(p, "w", encoding="utf-8").write(s.replace(a, b))
MUT
}
ablate statusline-addr-in-argv \
  "monitor 启动命令不得带账号身份（长命进程 argv）" --all \
  "启动命令仍带账号身份" \
  m_statusline_positional

# ── 账号地址不进 argv：三条，覆盖三种不同的坏法 ──────────────────────
# ⭐ 消融动的是**触发条件**，不是守卫本身：把地址放回 --arg、把 env 前缀拿掉、
#    把某个名字的前缀全删光 —— 三种真实的改坏方式，而不是「把检查删掉再看它不响」。
# ⭐ Each ablation breaks the TRIGGERING CONDITION, not the guard: put an address back
#    on --arg, drop one env prefix, delete every prefix for one name. Three ways this
#    really breaks -- not "delete the check and observe that it stays quiet".
ablate addr-back-in-argv \
  "账号地址不得走 jq --arg（不进 jq 进程的命令行）" --fast \
  "账号地址又进了 jq 命令行" \
  m_append lib/detect.sh '_posctrl_addr() { jq -cn --arg e "$email" '"'"'$e'"'"'; }'

# 🔴 这一条证明的是「静态检查够不到的那一格由行为断言接住」。掉一个前缀，jq 拿到 null
#    而不是地址 ⇒ 点名的**行为**断言必须红。改动过程中这一格真的掉过两次，两次都是被
#    它抓住的、没有任何静态检查抓到；本条把那条路固化成可复跑的消融。
# 🔴 This proves the layer BELOW the static check. Drop one prefix and jq sees null
#    instead of an address, so the NAMED behavioural assertion has to go red. That
#    really happened twice while this change was made, caught by this and by no static
#    check; this freezes the path.
ablate argv-env-prefix-dropped \
  "掉一个 env 前缀 → 地址变 null → 行为断言接住（静态检查够不到的那一格）" --fast \
  "guard 后另读身份重新打开 TOCTOU" \
  m_sed lib/state.sh \
    'if ! QS_JQ_E="$email" quota_state_merge ' \
    'if ! quota_state_merge '

ablate env-pairing-broken \
  "某个名字的 env 前缀被全删光 → 名字级配对判据必须红" --fast \
  "jq env 传参配对断了" \
  m_sed_all lib/state.sh 'QS_JQ_AE="$actual_email" ' ''

# 🔴 构造期闸的**第二谓词**（凭据那一族）。谓词①只比状态目录前缀，对 $HOME 下的
#    QUOTA_CLAUDE_JSON / QUOTA_CREDENTIALS_FILE 结构上是瞎的 —— 而那两个正是真凭据文件。
#    消融动的是**触发条件**：把改指那一行撤掉，让它退回 $HOME 下的真路径。
# 🔴 The construct-time gate's SECOND predicate (the credential family). Predicate ① only
#    compares the state-directory prefix and is structurally blind to QUOTA_CLAUDE_JSON /
#    QUOTA_CREDENTIALS_FILE under $HOME -- which are the real credential files.
#    The ablation mutates the TRIGGERING CONDITION: drop the redirect so the value falls
#    back to the real path under $HOME.
ablate credential-path-unguarded \
  "构造期闸必须拦住指向真凭据文件的路径（谓词②）" --fast \
  "point at real files outside the sandbox" \
  m_drop test/quota-sentinel.test.sh '^\[\[ "\$\{QUOTA_CLAUDE_JSON:-\}"'

# ⚠️ `|| true` is load-bearing, not sloppiness. Without it this ablation's RESULT depended
#    on whether the machine had a readable ~/.claude.json: the injected call runs at source
#    time, quota_account_guard fails closed when it cannot read an identity, `source` then
#    returns non-zero, the suite aborts with "cannot load lib/state.sh", and the NAMED
#    assertion never runs -- scored MISS. Measured: empty $HOME -> MISS, $HOME with a
#    synthetic .claude.json -> RED. ⭐ An ablation must mutate ONLY its triggering condition
#    (here: "is the call written inside `$( )`"); breaking file loading as a side effect
#    makes the result depend on the environment instead of on the guard.
# ⚠️ `|| true` 是承重的，不是随手加的。没有它，这条消融的**结果**取决于机器上有没有一个
#    读得到的 ~/.claude.json：注入的调用在 source 期执行，quota_account_guard 读不到身份时
#    fail closed，`source` 于是返回非零，套件以「cannot load lib/state.sh」中止，
#    **点名的那条断言根本没跑到** ⇒ 判 MISS。实测：空 $HOME → MISS；
#    有合成 .claude.json 的 $HOME → RED。⭐ 消融只该动它的触发条件
#    （这里是「这个调用有没有写在 `$( )` 里」）；顺带把文件加载弄坏，
#    会让结果取决于环境而不是取决于守卫。
ablate outparam-in-subshell \
  "靠全局回传的函数不许写在命令替换里（bash 语言陷阱）" --fast \
  "这些调用在子 shell 里跑" \
  m_append lib/state.sh 'posctrl_probe=$(quota_account_guard "posctrl-injected" || true)'

# ══ 8. the decision gates / 决策闸 ═══════════════════════════════════════
ablate decide-stale-open \
  "决策对陈旧台账 fail closed" --slow \
  "拿超期读数切号" \
  m_sed lib/switch.sh \
    'if (( age < 0 || age > QUOTA_FETCH_MAX_AGE )); then' \
    'if false; then'

ablate blocked-no-throttle \
  "「无处可切」不得每拍刷日志与刷流水账" --slow \
  "每拍重试会把两者都刷满" \
  m_sed lib/switch.sh \
    'if [[ "$blocked_ts" =~ ^[0-9]+$ ]] && (( now - blocked_ts < QUOTA_SWITCH_MIN_INTERVAL )); then' \
    'if false; then'

# ══ 9. the switch itself / 切号本身 ══════════════════════════════════════
ablate switch-no-readback \
  "切号后必须回读身份，退出码 0 不算证据" --slow \
  "只看退出码就宣称切成了" \
  m_switch_noreadback

ablate switch-fence-not-moved \
  "切号成功后身份 fence 必须挪到新账号（否则永久 fail closed）" --slow \
  "下一拍守卫会判 account-drift" \
  m_sed lib/switch.sh \
    '      .account_guard.expected_email = $ENV.QS_JQ_E' \
    '      .account_guard.expected_email_disabled_by_posctrl = $ENV.QS_JQ_E'

# ══ 10. candidate selection / 候选选择 ═══════════════════════════════════
ablate roster-exclusion-off \
  "退役与暂停的账号不得进候选" --slow \
  "已退役/已暂停的账号仍在候选里" \
  m_sed lib/reading.sh \
    "jq -Rc 'split(\" \") | map(select(length > 0))'" \
    "jq -Rc 'split(\" \") | map(select(length > 99))'"

ablate switch-line-not-enforced \
  "恰好在切换线上的候选不得被接纳（否则切过去立刻再切走）" --fast \
  "正好在切换线上的候选被接纳了" \
  m_sed lib/switch.sh \
    '>= QUOTA_SWITCH_PCT_FIVE )) && continue' \
    '>= 100000 )) && continue'

# ══ 9b. temp-directory acquisition / 临时目录取得 ═══════════════════════
# ⚠️ The expectation here is deliberately NOT just "exit code is non-zero" -- before the
#    hardening the exit code was already 1 (15 assertions failed). What is required is
#    **abort AND not one PASS/FAIL produced** (see MUST_ABORT).
#    ⭐ A "non-zero" expectation passes either way, i.e. goes green whether or not the fix
#      is present.
# ⚠️ 这两条的期望值刻意不只是「退出码非 0」——未加固时退出码本来就是 1（15 条断言失败）。
#    要求的是**中止且一条 PASS/FAIL 都不产生**（见 MUST_ABORT）。
ablate tmp-mktemp-failure \
  "mktemp 失败时必须中止（第一道闸：退出码）" --fast \
  "could not create a temporary directory" \
  m_tmp_badparent

ablate tmp-value-unusable \
  "mktemp 给出不可用的值时必须中止（第二道闸：值）——否则文件会写进文件系统根目录" --fast \
  "refusing to run" \
  m_tmp_badvalue

# ══ 10b. the pipefail/SIGPIPE shape / pipefail 与 SIGPIPE ═══════════════
# 把一处匹配改回 `printf | grep -q` 的写法：结构判据必须抓到它。
# ⚠️ 这里刻意只验**结构判据**会红，不验那条 200 次行为判据——后者是统计判据，
#    在一次消融里恰好 200 次全对的概率不是 0（按实测 7.6% 约 1e-7，但那是概率不是保证）。
#    ⭐ 用一条概率判据去证明另一条判据「会红」，等于把一个可判定的问题换成一个赌注。
ablate pipeline-grepq \
  "判据里不许出现管道末端的 grep -q（pipefail 会把命中报成没命中）" --fast \
  "这些管道会把命中报成没命中" \
  m_sed lib/detect.sh \
    'grep -qE "$QUOTA_MENU_OPT1_REGEX" <<<"$t20" || return 1' \
    "printf '%s' \"\$t20\" $(printf '%s' '| grep') -qE \"\$QUOTA_MENU_OPT1_REGEX\" || return 1"

# ══ 11. reading-side gates / 读数侧的闸 ══════════════════════════════════
ablate compare-log-heartbeat \
  "对账日志只在内容变化时记，不逐行心跳" --slow \
  "心跳会把真正的变化埋掉" \
  m_sed lib/reading.sh \
    '[[ "$_cmp_sig" == "$_cmp_prev" ]] && return 0' \
    '[[ "$_cmp_sig" == "__never__" ]] && return 0'

# ══ 12. the observation file's DEFAULT / 面板观测的默认值 ════════════════
# ⭐ 四条消融动的都是**触发条件**（默认值、写入条件、开关传参、传参方式），
#    没有一条去动断言本身。四种都是真实的坏法，不是「把检查删掉再看它不响」。
# ⭐ All four ablations mutate a TRIGGERING CONDITION (the default, the write condition,
#    how the switch reaches jq, how the frame is passed) — none of them touches an
#    assertion. All four are ways this really breaks, not "delete the check and observe
#    that it stays quiet".
# ⚠️ 期望文本刻意写成**点名那条断言的 FAIL 行**，不是「退出码非 0」：本仓的消融里
#    「退出码非 0」在未加固时本来就成立，写成那样等于恒真。
# ⚠️ The expectation is deliberately the NAMED assertion's FAIL line, never "exit code is
#    non-zero" — the latter already held before the hardening, so it would be vacuous.

# ① 有人把默认值翻回来（打包者、发行版补丁、"我这台调试要用"）
# ① Somebody flips the default back (a packager, a distro patch, "I need it on this box")
ablate panel-text-default-on \
  "默认必须不落整屏原文（默认值被翻回 1）" --fast \
  "默认就把可见屏原文送了出去" \
  m_sed lib/config.sh \
    'QUOTA_PANEL_TEXT_CAPTURE="${QUOTA_PANEL_TEXT_CAPTURE:-0}"' \
    'QUOTA_PANEL_TEXT_CAPTURE="${QUOTA_PANEL_TEXT_CAPTURE:-1}"'

# ② 写入条件在某次合并/回同步里掉了（基线那份就是无条件写的，所以这是最像会发生的一种）
# ② The write condition is lost in a merge or a re-sync with the baseline — the baseline
#    writes it unconditionally, which makes this the most likely regression of the four.
ablate panel-text-unconditional \
  "写入条件掉了 → 默认又落原文（基线形态回归）" --fast \
  "默认就把可见屏原文送了出去" \
  m_sed lib/state.sh \
    'if $capture==1 then .panel_text = $ENV.QS_JQ_FRAME else . end' \
    'if true then .panel_text = $ENV.QS_JQ_FRAME else . end'

# ③ 逃生口坏掉：开关到不了 jq。⭐ 只测「默认不存」的话，一个**永远不存**的实现也全绿——
#    而那不是安全的默认，那是功能没了。这一条守的就是「开关是真开关」。
# ③ The escape hatch dies: the switch never reaches jq. ⭐ Testing only "the default does
#    not store it" is also passed by an implementation that can NEVER store it — which is
#    not a safe default, it is a removed feature. This ablation guards the other half.
ablate panel-text-optin-dead \
  "打开开关必须真的拿回原文（开关传不到 jq）" --fast \
  "打开 QUOTA_PANEL_TEXT_CAPTURE 之后拿不回可见屏原文" \
  m_sed lib/state.sh \
    '--arg status "$status" --arg sha "$sha" --argjson capture "$capture"' \
    '--arg status "$status" --arg sha "$sha" --argjson capture 0'

# ④ 帧回到 jq 的命令行。⚠️ 这一条与①②答的**不是同一问**：即使一个字都没落盘，
#    整屏内容也已经在那个 jq 进程的 world-readable cmdline 上广播过一次了。
# ④ The frame goes back onto jq's command line. ⚠️ NOT the same question as ① and ②:
#    even with nothing written to disk, the whole screen has already been broadcast once
#    on that jq process's world-readable cmdline.
ablate frame-back-in-argv \
  "整屏内容不得进命令行（帧被放回 --arg）" --fast \
  "整屏内容又进了命令行" \
  m_sed lib/state.sh \
    '--arg status "$status" --arg sha "$sha" --argjson capture "$capture"' \
    '--arg status "$status" --arg frame "$frame" --arg sha "$sha" --argjson capture "$capture"'

# ⑤⑥ 「任何口子」那句声称的两条腿。🩸 这条判据的**第一版**只 grep 一个文件，而注释写的是
#    「任何口子」——2026-08-31 review 注入一条真实的第二出口，整套 --fast 仍 PASS 106/FAIL 0。
#    ⭐ 判据的射程与它的自我描述一旦分叉，绿色读起来仍然像那句大话被验过了。
#    这两条把那次反例固化成可复跑的消融：扩宽之后，两种出口都必须让点名的那条断言变红。
# ⑤⑥ The two legs of the "through any route" claim. 🩸 The FIRST version of this assertion
#    grepped a single file while the comment said "any route"; the 2026-08-31 review
#    injected a real second sink and the whole --fast run stayed PASS 106 / FAIL 0.
#    These freeze that counterexample into re-runnable ablations.
ablate frame-second-sink \
  "整屏原文不得从第二个文件出去（review 那条反例的固化）" --fast \
  "默认就把可见屏原文送了出去" \
  m_second_sink

ablate frame-to-stdout \
  "整屏原文不得从 stdout 出去（断言收 stdout/stderr 那一格不是摆设）" --fast \
  "默认就把可见屏原文送了出去" \
  m_stdout_sink

echo
echo "── 三列对照表 / guard -> ablation -> observed ──"
printf '%s\n' "${ROWS[@]}" | awk -F'|' '{printf "  %-24s %-58s %s\n", $1, $2, $3}'
echo
# ── negative control / 负控 ──────────────────────────────────────────────
# ⚠️ Without this line, "every ablation went red" is equally consistent with "this
#    harness breaks any copy it makes". Copy the repo, change nothing, and require GREEN.
# ⚠️ 没有这一条，「每条消融都红了」与「这套脚手架把任何副本都弄坏了」同样说得通。
#    复制一份、什么都不改、要求全绿。
NC="$TMP/negative-control"
mkdir -p "$NC"
cp -r "$ROOT/lib" "$ROOT/test" "$ROOT/quota-sentinel" "$ROOT/account-probe" "$ROOT/account-switch" "$NC/" 2>/dev/null
if nc_out=$(cd "$NC" && bash "$NC/test/quota-sentinel.test.sh" 2>&1); then
  echo "NEG-CTL  未改动的副本全绿：$(printf '%s' "$nc_out" | tail -1)"
else
  echo "NEG-CTL  ❌ 未改动的副本就已经红了 —— 上面每一条 RED 都不作数"
  printf '%s\n' "$nc_out" | grep -E '^  FAIL' | head -5
  BAD=$((BAD+1))
fi

echo
printf 'ablations proved red: %d   not proved: %d\n' "$OK" "$BAD"
(( BAD == 0 )) || exit 1
