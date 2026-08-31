#!/bin/bash
# quota-sentinel regression / 判据回归
#
# This suite is organised around one idea that is worth stating before anything else:
# **a guard that has never gone red proves nothing when it is green.** So wherever a
# guard exists because something actually broke, the suite also asserts that the
# broken behaviour is still reachable and still detected — either by running the
# frozen pre-fix detector (test/fixtures/legacy-detectors.sh) or by a positive control
# that feeds an input the guard MUST reject and fails the run if the guard accepts it.
# 本套件的组织方式先说一句：**一条从来没红过的守卫，绿了也不说明问题。**因此凡是因为
# 真出过事才存在的守卫，套件都同时断言那个坏行为仍然可达、仍然被抓到——要么跑冻结的
# 修复前判据（test/fixtures/legacy-detectors.sh），要么用一条正控：喂一个守卫**必须
# 拒绝**的输入，守卫一旦接受就判红。
#
# Layers / 分层:
#   bash test/quota-sentinel.test.sh            all / 全量
#   bash test/quota-sentinel.test.sh --fast     detectors and short stubs / 纯判据与短打桩
#   bash test/quota-sentinel.test.sh --slow     state machines and switching / 状态机与切号
#   bash test/quota-sentinel.test.sh --shadow   shadow sampling only / 仅影子采样
#
# Exit: 0 = all green, 1 = a case failed, 2 = bad usage, 3 = the suite was about to
# write into the real state directory (see the construction-time assertion below).

set -uo pipefail

TEST_LAYER=all
case $# in
  0) ;;
  1)
    case "$1" in
      --all)                TEST_LAYER=all ;;
      --fast)               TEST_LAYER=fast ;;
      --slow|--integration) TEST_LAYER=slow ;;
      --shadow)             TEST_LAYER=shadow ;;
      *) printf 'usage: %s [--all|--fast|--slow|--shadow]\n' "$0" >&2; exit 2 ;;
    esac
    ;;
  *) printf 'usage: %s [--all|--fast|--slow|--shadow]\n' "$0" >&2; exit 2 ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIX="$ROOT/test/fixtures"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/quota-sentinel-test.XXXXXX") || {
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

PASS=0; FAIL=0
pass() { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

# ── Control group: the detectors as they were BEFORE the rewrite ──────────────
# Upstream this was fetched live from the private repository's history with a pinned
# SHA and `|| exit 1`. That history is not here, so the text is frozen in a fixture
# and its checksum is asserted on every run: an edited control group is the one
# failure mode that produces no error and no symptom, it just quietly stops being a
# control. See the fixture header for what the checksum does and does not prove.
# 对照组：重构**之前**那版判据。上游是钉死 SHA 从私有仓历史现取的，本仓没有那段历史，
# 于是冻进夹具，并在每次运行校验哈希——被改过的对照组是唯一一种不报错、无症状的失效，
# 它只是悄悄地不再是对照组。哈希证明什么、不证明什么见夹具头部。
# shellcheck source=test/fixtures/legacy-detectors.sh
source "$FIX/legacy-detectors.sh" || { echo "cannot load the frozen control group" >&2; exit 1; }
_legacy_now=$(printf '%s\n' "$QS_LEGACY_SRC" | sha256sum | cut -d' ' -f1)
if [[ "$_legacy_now" != "$QS_LEGACY_SHA256" ]]; then
  echo "the frozen control group has been modified" >&2
  echo "  expected sha256 $QS_LEGACY_SHA256" >&2
  echo "  actual   sha256 $_legacy_now" >&2
  echo "  Every 'the old detector got this wrong' assertion below compares against that" >&2
  echo "  text. With it changed, this suite only tests the new code against itself." >&2
  exit 1
fi
unset _legacy_now

# ── Subject under test / 被测 ────────────────────────────────────────────────
# ⚠️ Point the state root at $TMP **before** sourcing. Almost every writable path in
#    the tool is written as "${VAR:-$QS_STATE_DIR/...}", so redirecting the root once
#    redirects all of them, **including paths added later**. The per-variable
#    reassignments below are kept as a second line of defence, but they cannot be the
#    only one: relying on somebody remembering to add a line per new path is exactly
#    what failed upstream on 2026-08-21, when a newly added switch-ledger path had no
#    such line and the regression wrote 14 fabricated switch records into the
#    **production** ledger.
# ⚠️ **在 source 之前**把状态根指到 $TMP。工具里几乎所有可写路径都写成
#    "${VAR:-$QS_STATE_DIR/…}"，改一次根就全部落到 TMP，**包括以后新加的**。下面逐个
#    改指 TMP 的赋值保留作双保险，但不能只靠它：靠人记得给每个新路径补一行，正是上游
#    2026-08-21 出事的原因——当天新加的切号台账路径没人补，回归把 14 条假切号记录写进了
#    **生产**台账。
QS_STATE_DIR="$TMP/state"
mkdir -p "$QS_STATE_DIR" "$QS_STATE_DIR/lock"
QS_REAL_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/quota-sentinel"

# ⚠️ Pin the zone before anything resolves an offset. Several cases below assert a
#    wall-clock rendering ("this parses to 15:10 local"), and the offset is resolved
#    from the host at load time — so on a UTC machine those same assertions would
#    compare against different numbers and fail for a reason that has nothing to do
#    with the code. `CST-8` is the POSIX fixed-offset spelling (sign inverted: UTC+8);
#    it needs no zoneinfo database, so it behaves identically on a host with tzdata
#    and inside a stripped sandbox without it.
#    ⚠️ Pinning makes the suite deterministic, and that also means it stops being able
#    to notice "this only works at +8". One case below therefore re-runs a parse under
#    TZ=UTC and asserts the result MOVES, which is what proves the offset is resolved
#    rather than hard-coded.
# ⚠️ 在任何东西解析偏移量之前钉死时区。下面若干条断言的是墙上时间（「解析成本地 15:10」），
#    而偏移量是加载时从宿主取的——在 UTC 机器上同样的断言会跟不同的数字比，然后以一个与
#    代码无关的理由失败。`CST-8` 是 POSIX 固定偏移写法（符号与偏移相反，即 UTC+8），
#    不查 zoneinfo，因此在有 tzdata 的宿主和被剥光的沙箱里表现一致。
#    ⚠️ 钉死带来确定性，同时也意味着它不再能发现「这东西只在 +8 能用」。所以下面另有一条
#    在 TZ=UTC 下重跑解析、断言结果**会变**的用例——那才是「偏移量是解析出来的、不是写死的」
#    的证据。
export TZ="${QS_TEST_TZ:-CST-8}"

# ⚠️ Recorded BEFORE lib/config.sh is sourced, because afterwards the variable exists
#    either way and "the default" and "what the operator exported" are indistinguishable.
#    One group below asserts a DEFAULT (that the visible screen is not stored), so it has
#    to be able to say "you are not testing the default" out loud instead of quietly
#    testing something else.
# ⚠️ 必须在 source lib/config.sh **之前**取：之后这个变量无论如何都存在，「默认值」与
#    「跑测试的人 export 的值」就分不开了。下面有一组断言的是**默认行为**（可见屏不落盘），
#    它必须能当场说「你测的不是默认值」，而不是安静地去测了别的东西。
QS_TEST_PANEL_CAPTURE_PRESET="${QUOTA_PANEL_TEXT_CAPTURE+set}"

QS_SOURCE="${QS_SOURCE:-$ROOT}"
# shellcheck source=lib/config.sh
source "$QS_SOURCE/lib/config.sh"   || { echo "cannot load lib/config.sh" >&2; exit 1; }
# shellcheck source=lib/reading.sh
source "$QS_SOURCE/lib/reading.sh"  || { echo "cannot load lib/reading.sh" >&2; exit 1; }
# shellcheck source=lib/monitor.sh
source "$QS_SOURCE/lib/monitor.sh"  || { echo "cannot load lib/monitor.sh" >&2; exit 1; }
# shellcheck source=lib/detect.sh
source "$QS_SOURCE/lib/detect.sh"   || { echo "cannot load lib/detect.sh" >&2; exit 1; }
# shellcheck source=lib/switch.sh
source "$QS_SOURCE/lib/switch.sh"   || { echo "cannot load lib/switch.sh" >&2; exit 1; }
# shellcheck source=lib/state.sh
source "$QS_SOURCE/lib/state.sh"    || { echo "cannot load lib/state.sh" >&2; exit 1; }
# The CLI itself, for the display-layer commands. It guards its own dispatch with
# `[[ "${BASH_SOURCE[0]}" == "$0" ]]`, so sourcing it defines the functions without
# running a command.
# CLI 本身，为的是展示层那几个命令。它自己用 BASH_SOURCE/$0 守住了 dispatch，
# source 它只会定义函数，不会执行命令。
# shellcheck source=quota-sentinel
source "$QS_SOURCE/quota-sentinel"  || { echo "cannot load the CLI" >&2; exit 1; }

QUOTA_LOG="$TMP/quota.log"
QUOTA_STATE="$TMP/quota-state.json"
QUOTA_SHADOW_OAUTH_STATE="$TMP/quota-oauth-shadow-state.json"
QUOTA_SHADOW_OAUTH_EVENTS="$TMP/quota-oauth-shadow-events.jsonl"
QUOTA_SHADOW_OAUTH_LOCK="$TMP/quota-oauth-shadow.lock"
QUOTA_SHADOW_PIDFILE="$TMP/quota-shadow-poller.pid"
QUOTA_SHADOW_STATUSLINE_STATE="$TMP/quota-statusline-shadow-state.json"
QUOTA_SHADOW_STATUSLINE_EVENTS="$TMP/quota-statusline-shadow-events.jsonl"
QUOTA_SHADOW_STATUSLINE_LOCK="$TMP/quota-statusline-shadow.lock"
QUOTA_SHADOW_SCHEDULE_STATE="$TMP/quota-shadow-schedule.json"
QUOTA_SHADOW_SCHEDULE_LOCK="$TMP/quota-shadow-schedule.lock"
QUOTA_SOURCE_EVENTS="$TMP/quota-source-samples.jsonl"
QUOTA_SOURCE_EVENTS_LOCK="$TMP/quota-source-samples.lock"
QUOTA_PANEL_OBSERVATIONS="$TMP/quota-panel-observations.jsonl"
QUOTA_PANEL_OBSERVATIONS_LOCK="$TMP/quota-panel-observations.lock"
QUOTA_PANEL_PRUNE_STAMP="$TMP/quota-panel-observations.prune-ts"
QUOTA_MONITOR_OP_LOCK="$TMP/quota-monitor-op.lock"
QUOTA_SWITCH_LEDGER="$TMP/switches.jsonl"
QUOTA_SNAPSHOT_FILE="$TMP/account-quota-snapshot.json"

# ⚠️ Construction-time assertion: no QUOTA_* path may point into the real state
#    directory. This does not ask "did the test write there" — it asks "could it".
#    Whether a write happens depends on which branch runs, which is probabilistic;
#    whether a path points at the wrong root is structural, decidable right here, and
#    therefore cannot be missed. It is at the top and not at the end on purpose: by the
#    time a run has finished, a misdirected path has already been writing for several
#    hundred cases.
# ⚠️ 构造期断言：任何 QUOTA_* 路径都不许指进真的状态目录。这条不看「测试有没有真的写」，
#    只看「有没有可能写」——写没写要看运行时走没走到，是概率问题；指没指对是构造问题，
#    当场可判，也就不会漏。放在开头而不是收尾：一旦指错，等跑完再报时已经污染了几百条用例。
# 🔴 TWO predicates, and the second one exists because the first was structurally blind.
#    Predicate ① compares against $QS_REAL_STATE_DIR. That covers the state directory
#    family and **nothing else** -- and the two most dangerous paths in this project,
#    QUOTA_CLAUDE_JSON and QUOTA_CREDENTIALS_FILE, live under $HOME and NOT under
#    $HOME/.local/state/quota-sentinel. So ① could never warn about them, while README's
#    "What it touches" table marks both **write**.
#    ⭐ This is the G-9 incident repeating on a different object: the fix back then was to
#    replace "enumerate them one by one" with a STRUCTURAL check -- but the structural
#    check's PREDICATE still only covered one family, so the credential family was still
#    being guarded by enumeration (by each case remembering to export its own fixture).
# 🔴 **两个谓词，第二个存在是因为第一个结构上是瞎的。**
#    谓词①比的是 $QS_REAL_STATE_DIR，它覆盖状态目录那一族、**别的什么都不覆盖**——
#    而本项目最危险的两个路径 QUOTA_CLAUDE_JSON 与 QUOTA_CREDENTIALS_FILE 在 $HOME 下、
#    **不在** $HOME/.local/state/quota-sentinel 下 ⇒ ①永远不会对它们报警，
#    而 README「它会动你哪些文件」表里这两个都标着 **write**。
#    ⭐ 这是 G-9 那次事故换了个对象重演：当年的修法是把「逐个列举」换成**结构判据**，
#    但那条结构判据的**谓词**只覆盖了一族，凭据那一族仍然靠逐个列举（靠每条用例自己
#    记得 export 夹具）在守。
#
# 先把两个凭据路径显式改指到夹具，再判——否则它们在 source 期就是 $HOME 下的真文件。
# Redirect both credential paths to fixtures FIRST; otherwise at source time they are the
# real files under $HOME.
# ⚠️ Unconditional, not `${VAR:-default}`: lib/config.sh has already resolved both from the
#    real $HOME by the time we get here, so a `:-` default would never apply. Anything the
#    caller legitimately pre-pointed under $TMP is preserved by the guard below, which
#    re-checks every value afterwards.
# ⚠️ 无条件赋值，不用 `${VAR:-默认}`：走到这里时 lib/config.sh 已经把这两个从真实 $HOME
#    解析出来了，`:-` 默认值根本不会生效。调用方本来就指到 $TMP 下的那种情况由下面那道闸
#    重新逐个复核，不会被这里盖掉语义。
[[ "${QUOTA_CLAUDE_JSON:-}"      == "$TMP"/* ]] || export QUOTA_CLAUDE_JSON="$TMP/identity.json"
[[ "${QUOTA_CREDENTIALS_FILE:-}" == "$TMP"/* ]] || export QUOTA_CREDENTIALS_FILE="$TMP/credentials.json"

_leaks=""
for _v in $(compgen -v | grep '^QUOTA_'); do
  _val="${!_v:-}"
  # ⚠️ 一个变量可能同时命中两个谓词（真状态目录通常也在 $HOME 下）；只列一次，
  #    否则失败文案里同一个名字出现两遍，读的人会以为是两个不同的问题。
  # ⚠️ One variable can match BOTH predicates (the real state dir is usually under $HOME
  #    too). List it once -- a name appearing twice reads as two separate problems.
  _hit=""
  # ① points into the real state directory / ① 指进真状态目录
  [[ "$_val" == "$QS_REAL_STATE_DIR"* ]] && _hit=1
  # ② under $HOME but not under $TMP -- the credential family has exactly this shape
  # ② 落在 $HOME 下却不在 $TMP 下 —— 凭据那一族正是这个形状
  [[ -n "$_val" && "$_val" == "$HOME"/* && "$_val" != "$TMP"/* ]] && _hit=1
  [[ -n "$_hit" ]] && _leaks="$_leaks $_v=$_val"
done
if [[ -n "$_leaks" ]]; then
  printf 'aborting: these paths point at real files outside the sandbox and running on would touch them:%s\n' "$_leaks" >&2
  printf '  fix: give it a value under $TMP, or make sure it derives from $QS_STATE_DIR (already redirected here)\n' >&2
  exit 3
fi
unset _leaks _v _val _hit

# ════════════════════════════════════════════════════════════════════════
# Global tmux gate: deny every real tmux call by default
# 全局 tmux 闸：默认拦住一切真实 tmux 调用
# ════════════════════════════════════════════════════════════════════════
# ⚠️ 2026-08-19 incident: the regression reached into **production sessions** and
#    pressed Esc on two live rate-limit dialogs. The action itself matched production
#    behaviour and touched nothing paid, but **that the tests were able to touch
#    production at all** is the incident. Root cause: each case stubbed tmux for
#    itself, with **no global backstop**; several functions reach for real panes, and
#    they were only ever entered through two paths that happened to be stubbed. The
#    isolation was implicit, unwritten, and unguarded — so when one of those side
#    paths became a main path, the tests walked straight in.
# ⚠️ 2026-08-19 事故：本回归伸手动了**生产会话**，给两个撞了限流框的对话按了 Esc。动作
#    本身与生产行为一致、没碰付费选项，但**测试有能力动生产**这件事本身就是事故。根因：
#    此前每条用例各自临时打桩 tmux，**没有全局兜底**；有几个函数会摸真实 pane，而它们
#    原本只从两条碰巧打了桩的路进入，于是**碰巧**安全——那是隐式的、没写下来、也没人守的
#    隔离。那条岔路一变成大路，测试就走了进去。
#
# ⇒ Deny by default: any tmux call that was not explicitly stubbed cannot reach tmux.
#   Cases that need specific behaviour still stub it themselves; _stub_restore restores
#   to this gate, not to the real tmux.
#
# ⚠️ The gate itself has to be verified, or it is an ornament nobody checks. Violations
#   are recorded in TMUX_VIOLATIONS; one case at the end asserts the log is empty, and
#   another deliberately triggers one, to prove the first assertion can go red.
TMUX_VIOLATIONS="$TMP/tmux-violations.log"
: > "$TMUX_VIOLATIONS"
# ⚠️ It must be a **reinstallable** function, not a one-off definition at the top of
#    the file. Upstream had 6 `unset -f tmux` teardowns; unset deletes the function
#    outright, so from that line until the next redefinition `tmux` was **the real
#    tmux** — that is the seam the 2026-08-19 leak went through, and after the last
#    unset the whole remainder of the file was bare. Those teardowns all call this
#    function instead.
_tmux_guard_install() {
  tmux() {
    case "${1:-}" in
      ls|list-sessions)  return 1 ;;   # "cannot ask" — the code must treat this as unknown, not as "no sessions"
      capture-pane)      printf '' ;;  # blank screen: no detector matches, nothing is misjudged
      has-session)       return 1 ;;
      display-message)   printf '' ;;
      send-keys|kill-session|new-session|rename-session|set-buffer|paste-buffer|respawn-pane)
        # These change somebody else's state — the genuinely dangerous class. Record and refuse.
        printf '%s %s\n' "$1" "${*:2}" >> "$TMUX_VIOLATIONS"
        return 1 ;;
      *) printf '%s %s\n' "UNSTUBBED:$1" "${*:2}" >> "$TMUX_VIOLATIONS"; return 1 ;;
    esac
  }
}
_tmux_guard_install

# ⚠️ Stubs must nest. If one block's save lands inside another block's save/restore
#    span, the **stub** gets saved as if it were the original, and from then on every
#    restore installs a stub — the contamination spreads hundreds of lines away and
#    surfaces as a completely unrelated case failing. Upstream fell into this twice in
#    one day (2026-08-24): once by deleting somebody else's restore while moving a
#    block, once by inserting a new block inside somebody else's span. Both took a long
#    time to trace back to the scaffolding.
#    ⇒ Point fixes cannot stop this, because it depends on **where** the block is
#      inserted, and that differs every time. Per-function counted stack instead:
#      the Nth save goes to orig.$f.N, restore pops level N.
# ⚠️ 打桩必须支持**嵌套**……（同上，2026-08-24 一天内栽两次，两次都花了很久才定位到脚手架）
declare -A _stub_depth=()
_stub_save() {
  local f n
  for f in "$@"; do
    n=$(( ${_stub_depth[$f]:-0} + 1 )); _stub_depth[$f]=$n
    declare -f "$f" > "$TMP/orig.$f.$n" 2>/dev/null || : > "$TMP/orig.$f.$n"
  done
}
_stub_restore() {
  local f n
  for f in "$@"; do
    n=${_stub_depth[$f]:-0}
    (( n > 0 )) || continue          # never touch what was not saved, or the real function gets unset
    if [[ -s "$TMP/orig.$f.$n" ]]; then . "$TMP/orig.$f.$n"; else unset -f "$f" 2>/dev/null || true; fi
    rm -f "$TMP/orig.$f.$n"; _stub_depth[$f]=$(( n - 1 ))
  done
}

read_fx() { cat "$FIX/$1"; }
ready_composer_frame() { printf '%s\n' '────────────────────────' $'❯\302\240'; }

# ════════════════════════════════════════════════════════════════════════
# Fast layer — detectors and short stubs / 快层：纯判据与短打桩
# ════════════════════════════════════════════════════════════════════════
run_fast_tests() {
echo "── 状态落盘：atomic rename 失败不能冒充成功 ──"
QUOTA_STATE="$TMP/state-rename-fail.json"
echo '{}' > "$QUOTA_STATE"
if (
  mv() { return 1; }
  quota_state_merge '.probe = true'
); then
  fail "mv 失败后 quota_state_merge 仍返回 0，at-most-once ledger 是假成功"
else
  pass "atomic rename 失败会向调用方报错，不会放行后续不可撤回动作"
fi

echo "── 选单入口：客户端 改了选项文案之后还认不认得出 ──"
# Measured background: the client changed option 2 from "Switch to usage credits" to
# "Upgrade your plan". The legacy test anchored that line verbatim, so from then on
# menu-detected was **0 for 28 days straight**, while the banner branch ran 165+ times in
# the same period -- so the system as a whole still looked like it was working. Sessions
# that hit the limit just waited for a human to clear the dialog.
# ⭐ A predicate going from "can match" to "can never match" looks EXACTLY like
#   "nothing happened in that period" in the logs.
# 实测背景：客户端把选项 2 从 "Switch to usage credits" 改成 "Upgrade your plan"，
# 旧判据逐字锚这行 → 此后 28 天 menu-detected 恒为 0，同期横幅分支跑了 165+ 次
# （所以整体看起来一直在工作），撞限会话只能等人手动清掉对话框。
if legacy_call usage_menu_present "$(read_fx menu-new-wording.txt)"; then
  fail "对照组应当在新文案上失效（它却命中了，说明本用例没复现原缺陷）"
else
  pass "对照组在新文案上确实进不去（复现了 28 天哑掉的那条）"
fi
if quota_menu_present "$(read_fx menu-new-wording.txt)"; then
  pass "新判据认得出新文案选单"
else
  fail "新判据仍认不出新文案选单"
fi

echo "── 选单入口：旧文案不得回归 ──"
if legacy_call usage_menu_present "$(read_fx menu-old-wording.txt)" && quota_menu_present "$(read_fx menu-old-wording.txt)"; then
  pass "新旧判据在旧文案上都命中（无回归）"
else
  fail "旧文案上新旧判据不一致"
fi

echo "── 选单入口：scrollback 里的死选单不得误判 ──"
if quota_menu_present "$(read_fx menu-in-scrollback.txt)"; then
  fail "新判据把 scrollback 里的死选单当成了活选单"
else
  pass "新判据不吃 scrollback 死选单（末 10 行有空 ❯ = 客户端 闲置）"
fi

echo "── 横幅入口：用户在对话里提到横幅文案（2026-08-11 活体自激）──"
# Hit live: a user QUOTED a rate-limit banner in conversation as an illustration, and the
# watcher immediately judged that session to be rate-limited -- it opened an episode,
# probed it, and sent three false "quota restored" messages. Another session that was busy
# ANALYSING rate-limit logs got pulled into the queue the same way.
# ⭐ The investigator becomes the event source: the more carefully someone works ON this
#   problem, the more likely the system is to decide they are HAVING it.
# 当天实撞：用户在对话里引用了一句撞限横幅作说明，监控当场把本会话判成撞限，
# 建 episode、探活、并连发三次伪「额度已恢复」；同期另一个正在分析撞限日志的
# 会话也被同样抓进队列。
if legacy_call usage_banner_active "$(read_fx self-trigger-user-message.txt)"; then
  pass "对照组确实会被用户消息触发（复现了当天的自激）"
else
  fail "对照组没被触发，本用例没复现原缺陷"
fi
if quota_banner_present "$(read_fx self-trigger-user-message.txt)" >/dev/null; then
  fail "新判据仍会被用户消息触发"
else
  pass "新判据拒绝：横幅落在 ❯ 用户输入行上，不是 客户端 渲染的横幅"
fi

echo "── 横幅入口：用户正在 composer 里打这段字 ──"
if legacy_call usage_banner_active "$(read_fx banner-in-composer.txt)"; then
  pass "对照组确实会被 composer 里的半截输入触发"
else
  fail "对照组没被触发，本用例没复现原缺陷"
fi
if quota_banner_present "$(read_fx banner-in-composer.txt)" >/dev/null; then
  fail "新判据仍被 composer 输入触发"
else
  pass "新判据拒绝 composer 输入"
fi

echo "── 横幅入口：真横幅必须照常认出（不得因收紧而漏判）──"
strength=$(quota_banner_present "$(read_fx banner-strict.txt)")
if [[ "$strength" == "strict" ]]; then
  pass "真横幅（⎿ 子行）判为 strict，无需交叉验证即可采信"
else
  fail "真横幅被漏判或降级（got=${strength:-none}）"
fi

echo "── 横幅入口：已被后续输出盖过的旧横幅 ──"
if quota_banner_present "$(read_fx banner-stale-covered.txt)" >/dev/null; then
  fail "新判据把已被新 ● 块盖过的旧横幅当成活的"
else
  pass "新判据拒绝陈旧横幅"
fi

echo "── reset 时间：缺时区时的 8 小时偏差 ──"
# The legacy implementation fell back to tz=$(date +%Z). On the machine in question that
# returned a bare abbreviation, which glibc treated as UTC+0 -- everything shifted by 8
# hours, and nothing reported an error. Hit live: the same "resets 3:10pm" was recorded
# once as 15:10 and once as 23:10.
# 旧实现兜底用 tz=$(date +%Z)，那台机器返回一个裸缩写，glibc 把它当 UTC+0 → 整体偏
# 8 小时，且不报错。实测活体撞出：同一句 "resets 3:10pm" 一次记成 15:10 一次记成 23:10。
old_epoch=$(legacy_call parse_usage_reset_epoch "$(read_fx reset-no-timezone.txt)" || echo "")
new_epoch=$(quota_parse_reset_epoch "$(read_fx reset-no-timezone.txt)" || echo "")
old_hm=$([[ -n "$old_epoch" ]] && date -d "@$old_epoch" '+%H:%M' || echo "-")
new_hm=$([[ -n "$new_epoch" ]] && date -d "@$new_epoch" '+%H:%M' || echo "-")
if [[ "$old_hm" == "23:10" ]]; then
  pass "对照组确实把 3:10pm 解析成本地 23:10（复现 8 小时偏差）"
else
  fail "对照组未复现 8 小时偏差（got=$old_hm，期望 23:10）"
fi
if [[ "$new_hm" == "15:10" ]]; then
  pass "新判据解析成本地 15:10（TZ=CST-8 固定偏移 + %z 自检）"
else
  fail "新判据解析错误（got=$new_hm，期望 15:10）"
fi

echo "── 兜底时区自检：裸缩写必须判解析失败，不许静默当成 UTC ──"
# 这条守卫的契约（写在 lib/detect.sh 的函数抬头）是：「自检 %z 能解析成偏移量，
# **绝不把静默回退 UTC 的值写进状态**」。而 2026-08-31 之前的实现是
# `[[ $(… '+%z') =~ ^[+-][0-9]{4}$ ]]`——它**接受 `+0000`**，而裸缩写恰恰退化成 `+0000`
# （本机实测 `TZ=CST date +%z` → `+0000`）⇒ 那条判据对它本该拒绝的那个输入**恒真**，
# 整条删掉套件照样全绿。⭐ 与 G-8 同一形状：纸面上存在、任何机器上恒绿。
# ⚠️ 判据是**规格的形态**不是偏移量的数值：写死「必须 +0800」会把本次抽取刚去掉的站点
#    事实又写回来，且让工具在别的时区全线失灵。`+0000` 在真 UTC 宿主上合法，
#    在「裸缩写没被解析」时非法——只有形态分得开这两者。
for _tzs in "" "Asia/Shanghai" "CST-8" "UTC" "GMT"; do
  if quota_tz_spec_usable "$_tzs"; then
    pass "可用的 TZ 规格被接受：${_tzs:-<空=本机时区>}"
  else
    fail "合法的 TZ 规格被误拒：${_tzs:-<空=本机时区>}（%z=$(quota_tz_date "$_tzs" '+%z' 2>/dev/null)）"
  fi
done
for _tzs in CST EDT PST XYZ; do
  if quota_tz_spec_usable "$_tzs"; then
    fail "裸缩写 $_tzs 被当成可用时区（glibc 把它静默当 UTC+0，正是事故 (a)）"
  else
    pass "裸缩写 $_tzs 被拒（它的 %z 是 +0000，那是降级不是时区）"
  fi
done
unset _tzs
# 端到端：契约说的是「不写进状态」，所以最终判据打在解析结果上，不只打在谓词上。
_tz_saved="$QUOTA_FALLBACK_TZ"
QUOTA_FALLBACK_TZ=CST
if _bad_epoch=$(quota_parse_reset_epoch "$(read_fx reset-no-timezone.txt)"); then
  fail "QUOTA_FALLBACK_TZ=CST 时仍解析出 epoch（本地 $(date -d "@$_bad_epoch" '+%H:%M')，真值 15:10）——静默偏掉一个偏移量的值进了状态"
else
  pass "QUOTA_FALLBACK_TZ 是裸缩写时整帧判解析失败（旧实现会在这里返回 23:10）"
fi
QUOTA_FALLBACK_TZ="$_tz_saved"
unset _tz_saved _bad_epoch

echo "── reset 时间：带时区时新旧应一致（无回归）──"
o=$(legacy_call parse_usage_reset_epoch "$(read_fx reset-with-timezone.txt)" || echo "")
n=$(quota_parse_reset_epoch "$(read_fx reset-with-timezone.txt)" || echo "")
if [[ -n "$o" && "$o" == "$n" ]]; then
  pass "带 (Asia/Shanghai) 时新旧解析一致（$(date -d "@$n" '+%H:%M')）"
else
  fail "带时区时新旧解析不一致（old=$o new=$n）"
fi

echo "── ISO 解析：客户端 写进 .claude.json 的形态 ──"
iso_epoch=$(quota_iso_epoch "2026-08-11T08:10:00.492913+00:00" || echo "")
if [[ "$(date -d "@$iso_epoch" '+%H:%M')" == "16:10" ]]; then
  pass "ISO 带偏移直读为本地 16:10（不经任何本地时区推断）"
else
  fail "ISO 解析错误（got=$(date -d "@${iso_epoch:-0}" '+%H:%M')）"
fi

echo "── 新鲜度闸：陈旧读数必须判「未知」而不是拿来决策 ──"
export QUOTA_CLAUDE_JSON="$TMP/stale.json"
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"stale@example.com"},
 "cachedUsageUtilization":{"fetchedAtMs":1000000000000,"accountUuid":"u",
  "utilization":{"five_hour":{"utilization":100,"resets_at":null},
                 "seven_day":{"utilization":100,"resets_at":null}}}}
JSON
if quota_snapshot >/dev/null 2>&1; then
  pass "陈旧文件仍能读出快照（读数层本身不做判断）"
else
  fail "读数层读不出快照"
fi
if quota_snapshot_fresh "$(date +%s)" >/dev/null 2>&1; then
  fail "新鲜度闸没拦住 2001 年的陈旧读数"
else
  pass "新鲜度闸拦下陈旧读数（100% 但过期 → 判未知，不动作）"
fi
unset QUOTA_CLAUDE_JSON

echo "── 账号守卫：切号回读之后再被并发覆盖也不得静默跟随 ──"
export QUOTA_CLAUDE_JSON="$TMP/account-guard.json"
QUOTA_STATE="$TMP/account-guard-state.json"; QUOTA_CACHE_MTIME=""
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"target@x","accountUuid":"uuid-target"},
 "cachedUsageUtilization":{"accountUuid":"uuid-target"}}
JSON
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
if declare -F quota_account_guard >/dev/null 2>&1 \
   && quota_account_guard "test-before-overwrite" >/dev/null 2>&1; then
  pass "目标邮箱 + oauth UUID + usage UUID 一致时守卫放行"
else
  fail "账号身份一致时守卫未放行（或守卫尚不存在）"
fi

# On the first upgrade there is no expected field yet -- but the current file still must
# not be taken as the baseline unconditionally: state.account holds the most recent panel
# attribution. The two already differing is precisely the signature of "the account
# changed with no corresponding successful switch event".
# 首次升级还没有 expected 字段时，也不能无条件采当前文件为基线：旧 state.account 是
# 最近一次面板归属。两者已不同时，正是「账号变了但没有对应切号成功事件」的签名。
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x"}
JSON
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"old@x","accountUuid":"uuid-old"},
 "cachedUsageUtilization":{"accountUuid":"uuid-old"}}
JSON
if quota_account_guard "test-first-baseline-mismatch" >/dev/null 2>&1; then
  fail "首次建 fence 时无视 state.account 差异，把无成功事件的旧账号收编成基线"
elif [[ "$(quota_state_get '.phase' '')" == "account_drift" \
     && -z "$(quota_state_get '.account_guard.expected_email' '')" ]]; then
  pass "首次建 fence 会用 state.account 否证静默漂移，不盲目采当前文件"
else
  fail "首次基线差异虽失败，但没有留下可诊断的 account_drift"
fi

# Restore the persistent expected value for the cases that follow.
# 恢复后续用例的持久 expected。
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON

# The one-shot read-back blind spot: the first check has already passed, and only THEN
# does another client process overwrite the whole config file with its old in-memory
# snapshot. The guard has to compare against the persistent expected identity; it must not
# adopt the new value as a baseline and follow it.
# 一次性回读盲区：第一次检查已经通过，随后另一个客户端进程才把整份配置文件用旧内存
# 快照盖回。守卫必须拿持久 expected 身份对照，不能把新值当基线跟走。
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"old@x","accountUuid":"uuid-old"},
 "cachedUsageUtilization":{"accountUuid":"uuid-old"}}
JSON
if declare -F quota_account_guard >/dev/null 2>&1 \
   && quota_account_guard "test-after-overwrite" >/dev/null 2>&1; then
  fail "回读后被覆盖成旧账号，守卫仍放行"
elif [[ "$(quota_state_get '.phase' '')" == "account_drift" \
     && "$(quota_state_get '.account_guard.expected_email' '')" == "target@x" ]]; then
  pass "回读后再被覆盖会进入 account_drift，且不把旧账号收编成新基线"
else
  fail "账号漂移虽返回失败，但没有留下 account_drift + 原 expected 身份"
fi

# ⚠️ 语义修订（2026-08-12 13:00 停摆事故后反转本断言）：usage_uuid 是 /usage 的**缓存**，
# 切号后为空或滞留旧账号是正常状态——把它当身份会死锁（guard 要它一致才放行，它要跑
# /usage 才刷新，跑 /usage 要先过 guard），实测停摆 3 小时。身份只看 oauthAccount；
# 「面板数值可能属于旧账号」由 monitor owner guard + 陈旧帧判据把关，不在这里。
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"target@x","accountUuid":"uuid-target"},
 "cachedUsageUtilization":{"accountUuid":"uuid-old"}}
JSON
if quota_account_guard "test-split-identity" >/dev/null 2>&1; then
  pass "usage 缓存滞留旧账号（正常滞后）→ 守卫放行，不再制造 3 小时死锁"
else
  fail "usage 缓存滞后仍被当身份卡死（13:00 停摆事故的机制原样复活）"
fi

# ABA: the shared file reads A both before and after the panel, but the monitor restarted
# under B in between. Checking only the file's expected value goes green both times and
# still records a B-monitor's panel numbers against A -- monitor_account has to be part of
# the attribution evidence too.
# ABA：共享文件在 panel 前后都呈 A，但 monitor 曾在中间按 B 重启。只核文件 expected
# 会两次都绿，仍会把 B-monitor 的面板值记给 A；必须把 monitor_account 也纳入归属证据。
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x","monitor_account":"old@x",
 "monitor_uuid":"uuid-target","monitor_session_created":100,
 "monitor_launch_id":"launch-100",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"target@x","accountUuid":"uuid-target"},
 "cachedUsageUtilization":{"accountUuid":"uuid-target"}}
JSON
if declare -F quota_monitor_owner_guard >/dev/null 2>&1 && (
  quota_session_created() { printf '100\n'; }
  quota_monitor_live_launch_id() { printf 'launch-100\n'; }
  ! quota_monitor_owner_guard "test-monitor-aba" >/dev/null 2>&1
); then
  pass "panel 后文件虽回到 expected，monitor_account 不同仍会阻断 ABA 错归"
else
  fail "没有把 monitor_account 纳入 panel 归属判据，ABA 可把 B 的额度记给 A"
fi

# 同名 monitor 死后重建也是新 owner 事件；若只看旧 email/UUID，旧标记会被新 tmux
# 代际冒用。必须把启动时的 session_created 一起钉住。
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x","monitor_account":"target@x",
 "monitor_uuid":"uuid-target","monitor_session_created":100,
 "monitor_launch_id":"launch-100",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
if (
  quota_session_created() { printf '200\n'; }
  quota_monitor_live_launch_id() { printf 'launch-100\n'; }
  ! quota_monitor_owner_guard "test-monitor-generation" >/dev/null 2>&1
); then
  pass "同名 monitor 的 session_created 变化会让旧 owner 证明失效"
else
  fail "monitor 同名重建后仍沿用旧 owner，面板归属缺少会话代际证明"
fi
}


# ════════════════════════════════════════════════════════════════════════
# Extraction integrity — guards that only this repository can fail
# 抽取完整性——只有本仓会栽的那几条
# ════════════════════════════════════════════════════════════════════════
# These have no upstream counterpart. They exist because splitting one 5124-line
# script into lib/*.sh created a failure mode the original could not have: a symbol
# can now be *read* in one file and *defined* in none, and under `set -u` that is not
# a warning, it is an immediate process exit on whichever branch first touches it.
# 这几条上游没有对应物。它们存在是因为「把 5124 行拆成 lib/*.sh」造出了原文件不可能有的
# 失效形态：一个符号可以在某个文件里被**读**、却在任何文件里都没被**定义**，而在 `set -u`
# 下那不是警告，是第一个碰到它的分支上整个进程当场退出。
run_extraction_tests() {

echo "── 抽取完整性：被读到的配置变量必须真的有定义 ──"
# 🔴 Found by this migration, 2026-08-28. lib/state.sh:424 read
#    QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL; lib/config.sh never defined it (upstream did,
#    at sentinel-quota:576). The branch that reads it is the external-drift branch —
#    the one whose whole purpose is to notice that somebody else changed the account —
#    so the tool exited on exactly the event it was built to report.
# 🔴 本次迁移查出（2026-08-28）：lib/state.sh:424 读 QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL，
#    而 lib/config.sh 从没定义过它（上游定义在 sentinel-quota:576）。读它的那个分支正是
#    外部漂移分支——其存在的全部意义就是「发现别人改了账号」——于是工具恰恰死在它被造出来
#    要报告的那件事上。
_undefined_reads() {
  # Every ALL-CAPS name read as $NAME / ${NAME}, minus every name that is assigned
  # somewhere or carries a `:-` default at its point of use, minus the ambient
  # environment.
  # ⚠️ This is a static check and says so out loud: it cannot see names built by
  #    expansion (`${prefix}_SUFFIX`), it does not follow `eval`, and it treats a name
  #    as defined if ANY file assigns it. It answers "is this symbol defined
  #    somewhere", not "is every branch safe".
  # ⚠️ 这是静态检查，且把话说明白：拼接出来的名字（`${prefix}_SUFFIX`）看不见，不跟
  #    `eval`，只要**任一**文件赋过值就算已定义。它答的是「这个符号有没有定义」，
  #    不是「每条分支都安全」。
  # ⚠️ `R`, `P` and `ENV` in the exclusion list below are NOT bash variables: they
  #    are jq program text (`as $R`, `as $P`, and jq's builtin `$ENV`) that this
  #    grep-based scanner cannot tell apart from a shell expansion. Excluding a name
  #    costs coverage, so `ENV` does not get excluded for free -- the check immediately
  #    below ("jq env-passing") re-establishes, in both directions, exactly the property
  #    that `--arg` used to give for the values now passed through `$ENV`.
  # ⚠️ 下面排除列表里的 `R`/`P`/`ENV` 都不是 bash 变量，而是 jq 程序文本
  #    （`as $R`、`as $P`、以及 jq 内建的 `$ENV`），而这个基于 grep 的扫描器分不出
  #    它们和 shell 展开的区别。**排掉一个名字就是丢掉一块覆盖面**，所以 `ENV` 不是白排的：
  #    紧跟着的「jq env 传参」那条判据会**双向**把 `--arg` 原本给的那个性质重新立起来。
  local reads assigned
  # ⚠️ Two shapes, and the second is the one that matters here: inside `(( ... ))`
  #    bash reads a variable with **no `$` sigil**, and that is exactly how the missing
  #    symbol was written (`>= QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL`). A checker that only
  #    looks for `$NAME` is structurally blind to the very defect it was written for —
  #    which is what the positive control below caught on the first run.
  # ⚠️ 两种形态，而这里要紧的是第二种：`(( ... ))` 里读变量**不带 `$`**，那正是缺失的
  #    那个符号的写法。只找 `$NAME` 的检查器对它要抓的那个缺陷结构上是瞎的——下面的正控
  #    第一次跑就把这件事抓了出来。
  reads=$( { grep -ohE '\$\{?[A-Z][A-Z0-9_]*' "$@" | tr -d '${'
             grep -ohE '\(\([^)]*\)\)' "$@" | grep -oE '\b[A-Z][A-Z0-9_]{2,}\b'
           } | sort -u)
  assigned=$( { grep -ohE '(^|[^A-Za-z0-9_])[A-Z][A-Z0-9_]*=' "$@" | grep -oE '[A-Z][A-Z0-9_]*'
                grep -ohE '\$\{[A-Z][A-Z0-9_]*:[-?=+]' "$@" | grep -oE '[A-Z][A-Z0-9_]*'
              } | sort -u)
  comm -23 <(printf '%s\n' "$reads") <(printf '%s\n' "$assigned") \
    | grep -vxE 'HOME|PATH|TMPDIR|PWD|SHELL|TERM|LANG|LC_ALL|TZ|IFS|RANDOM|UID|EUID|HOSTNAME|SECONDS|LINENO|COLUMNS|LINES|OSTYPE|FUNCNAME|BASH_SOURCE|BASH_REMATCH|XDG_STATE_HOME|HTTPS_PROXY|HTTP_PROXY|NO_PROXY|ALL_PROXY|R|P|ENV' \
    || true
}
# ⚠️ `account-probe` belongs in this list: it is bash, it sets its own `set -uo pipefail`,
#    and it is one of the two extracted CLIs — so it is exposed to exactly the defect this
#    check exists to catch. Scanning it together with lib/*.sh currently yields nothing
#    (it sources lib/config.sh), but a symbol read ONLY by it and defined nowhere would be
#    structurally invisible without this. Coverage, not today's result, is the point.
# ⚠️ `account-probe` 必须在这张单子里：它是 bash、自己设了 `set -uo pipefail`、
#    是两个被抽取 CLI 中的一个 ⇒ 它正好暴露在这条判据要抓的那个缺陷面前。今天与
#    lib/*.sh 合扫结果为空（它 source 了 lib/config.sh），但一个**只被它读、且哪儿都没定义**
#    的符号，在没有这一项时对本判据结构上不可见。要紧的是覆盖面，不是今天的结果。
undef=$(_undefined_reads "$QS_SOURCE"/lib/*.sh "$QS_SOURCE/quota-sentinel" "$QS_SOURCE/account-probe")
if [[ -z "$undef" ]]; then
  pass "lib/*.sh 与 CLI 里没有「读了但谁都没定义」的配置变量"
else
  fail "这些名字被读到却没有任何定义，set -u 下会当场退出：$(printf '%s' "$undef" | tr '\n' ' ')"
fi

# Positive control: point the SAME check at a config with one line deliberately removed;
# it must go red. Without this the green above proves nothing -- it could equally mean the
# check saw nothing at all.
# 正控：把同一个检查指向一份**故意抠掉一行**的 config，必须变红。否则上面那条绿了也
# 不说明问题——它可能只是没看见任何东西。
mkdir -p "$TMP/posctrl-lib"
cp "$QS_SOURCE"/lib/*.sh "$TMP/posctrl-lib/"
grep -v '^QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL=' "$QS_SOURCE/lib/config.sh" > "$TMP/posctrl-lib/config.sh"
undef_pc=$(_undefined_reads "$TMP/posctrl-lib"/*.sh)
if grep -qx 'QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL' <<<"$undef_pc"; then
  pass "正控：删掉那一行定义之后，同一个检查确实抓得到（判据会红）"
else
  fail "正控没红：这个检查抓不到「读了没定义」，上面那条绿是没有分辨力的绿"
fi


echo "── jq env 传参：账号地址不进命令行，且两侧必须配对 ──"
# WHY / 为什么有这一组
# --------------------------------------------------------------------------
# An account address handed to jq as `--arg e "$email"` is on that jq process's command
# line, and `/proc/<pid>/cmdline` is world-readable. The reading loop runs these on every
# beat, so the exposure was continuous rather than switch-only. The values now travel in
# the environment instead (`QS_JQ_E="$email" jq … '$ENV.QS_JQ_E'`), because
# `/proc/<pid>/environ` is readable only by the same UID.
# ⭐ What this buys is narrower than it sounds and the README says so: on a box where you
#    are root anyway, root could always read `environ`. The honest claim is
#    "no longer readable by ANY user", not "the address is no longer exposed".
# 把账号地址用 `--arg e "$email"` 交给 jq，它就在那个 jq 进程的命令行上，而
# `/proc/<pid>/cmdline` 是世界可读的。读数主轮**每一拍**都在跑这些 ⇒ 暴露是持续的，
# 不只在切号期间。现在改走环境变量，因为 `/proc/<pid>/environ` 只有同 UID 读得到。
# ⭐ 买到的东西比听起来窄，README 里也这么写：在一台你本来就是 root 的机器上，root
#    一直都读得到 `environ`。准确说法是「**不再对任意用户可读**」，不是「地址不再暴露」。
#
# 🔴 Two directions, and the second one is the silent one.
#    A → every `$ENV.QS_JQ_X` read has a `QS_JQ_X=` prefix in the same file. Without it
#        jq yields `null`, not `""` -- a DIFFERENT value from what `--arg` gave.
#    B → every `QS_JQ_X=` prefix has a `$ENV.QS_JQ_X` reader in the same file. A prefix
#        left behind after its expression was rewritten breaks nothing and shows nothing;
#        it just quietly puts the address back into the environment for no reason.
#    ⭐ Direction A fails loudly (`.accounts[null]` errors). Direction B fails silently,
#      which is why checking only A would be checking only the half that already screams.
# 🔴 两个方向，而**第二个是无声的那个**：
#    A → 每个 `$ENV.QS_JQ_X` 读取，同文件里都得有 `QS_JQ_X=` 前缀。缺了 jq 拿到的是
#        `null` 而不是 `""`——与 `--arg` 给的**不是同一个值**。
#    B → 每个 `QS_JQ_X=` 前缀，同文件里都得有 `$ENV.QS_JQ_X` 读取。表达式改写后遗留的
#        前缀不会坏任何事、也不会显出任何症状，它只是白白把地址又放回环境里。
#    ⭐ A 是响的（`.accounts[null]` 会报错），B 是哑的；只查 A 等于只查了本来就会叫的那一半。
# 口径与**它答不了什么**，写在这里，别让读的人自己猜。
# SCOPE, and what this CANNOT answer -- stated rather than left to be assumed.
#
# 判的是「名字级」：某个 `$ENV.QS_JQ_X` 在本文件里有没有对应的 `QS_JQ_X=` 前缀。
# ⚠️ 它**判不了**「这一个调用点的前缀掉了没有」——同一个名字常有多个调用点各设各的前缀，
#    拿掉其中一个，名字仍然在，本判据一声不吭。
# ⭐ 那一格不是没人管，是**换了一层管**：前缀掉了，jq 拿到的是 `null` 而不是地址，
#    于是回归里那条具体的行为断言会红。这不是推测——本次改动过程中真的掉过两次前缀
#    （lib/state.sh 的面板落盘、以及同一处的 `.account = $e`），两次都是被回归里
#    「guard 后另读身份」与「网络耗时被从档位中扣掉」这两条断言当场抓住的，
#    不是被任何静态检查抓住的。posctrl 的 `argv-env-prefix-dropped` 把这条路固化成
#    可复跑的消融：拿掉一个前缀，点名的那条回归断言必须变红。
#
# This is a NAME-level check: does every `$ENV.QS_JQ_X` read in a file have a matching
# `QS_JQ_X=` prefix somewhere in that file?
# ⚠️ It CANNOT answer "did THIS call site lose its prefix" -- one name is typically set by
#    several call sites, so dropping one leaves the name present and this check silent.
# ⭐ That gap is covered one layer down, not left open: without the prefix jq sees `null`
#    instead of an address, and a specific behavioural assertion in the suite goes red.
#    Not a prediction -- during this change the prefix really was dropped twice, and both
#    times it was the behavioural assertions that caught it, never a static check.
#    `posctrl.sh`'s `argv-env-prefix-dropped` freezes that path into a re-runnable
#    ablation: drop one prefix, and the NAMED regression assertion has to go red.
_env_pairing_violations() {
  local dir="$1" f base refs prefixes n
  for f in "$dir"/lib/*.sh "$dir/quota-sentinel" "$dir/account-probe"; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    refs=$(grep -ohE '\$ENV\.QS_JQ_[A-Z0-9_]+' "$f" | sed 's/^\$ENV\.//' | sort -u)
    prefixes=$(grep -ohE '(^|[^A-Za-z0-9_])QS_JQ_[A-Z0-9_]+=' "$f" \
               | grep -oE 'QS_JQ_[A-Z0-9_]+' | sort -u)
    for n in $refs;     do grep -qx "$n" <<<"$prefixes" || echo "$base: 读 \$ENV.$n 但本文件没有任何 $n= 前缀 (A)"; done
    for n in $prefixes; do grep -qx "$n" <<<"$refs"     || echo "$base: 设了 $n= 前缀但本文件没人读 \$ENV.$n (B)"; done
  done
}
_ep=$(_env_pairing_violations "$QS_SOURCE")
if [[ -z "$_ep" ]]; then
  pass "jq env 传参两侧配对（读有前缀、前缀有人读）"
else
  fail "jq env 传参配对断了：$(printf '%s' "$_ep" | tr '\n' '; ')"
fi

# One control per direction. Doing only A misses the always-reject / always-accept half.
# 正控，两个方向各一个。只做 A 会漏掉恒拒/恒过的那一半。
mkdir -p "$TMP/ep-a/lib" "$TMP/ep-b/lib"
cp "$QS_SOURCE"/lib/*.sh "$TMP/ep-a/lib/"; cp "$QS_SOURCE"/lib/*.sh "$TMP/ep-b/lib/"
# A: remove EVERY prefix for that name in the file while leaving the expression that
#    reads it (a name-level check can only recognise this shape).
# A：把该名字在本文件里的**全部**前缀拿掉，留着读它的表达式（名字级判据只认得这一种）
sed -i 's/QS_JQ_AE="\$actual_email" //' "$TMP/ep-a/lib/state.sh"
# B: add a prefix that nothing reads.
# B：加一个谁都不读的前缀
sed -i 's/^  QS_JQ_A="\$acct" quota_state_merge /  QS_JQ_NOBODY="x" QS_JQ_A="\$acct" quota_state_merge /' "$TMP/ep-b/lib/state.sh"
_ep_a=$(_env_pairing_violations "$TMP/ep-a"); _ep_b=$(_env_pairing_violations "$TMP/ep-b")
if grep -q '(A)' <<<"$_ep_a" && grep -q '(B)' <<<"$_ep_b"; then
  pass "正控：A 向（读了没前缀）与 B 向（前缀没人读）都各自抓得到"
else
  fail "正控没红（A=[${_ep_a}] B=[${_ep_b}]）：这条配对判据没有分辨力"
fi

# ── 静态面：账号地址不得再出现在 jq 的 --arg 上 ──
# ⚠️ 口径与边界写在这里，别让读的人自己猜：本判据按**变量名**认地址，认的是下面这张表。
#    换句话说它答的是「已知这些持有地址的变量，有没有谁又被放回 --arg」，
#    **不**答「argv 里有没有地址」——后者由 tools/credential-argv-control.sh 在**运行时**
#    采样 `ps` 来答，那一条不依赖任何变量名表。两条判据的盲区不重叠，这是刻意的。
# ⚠️ This check recognises an address BY VARIABLE NAME, from the table below. It answers
#    "did any known address-bearing variable get put back on a --arg", NOT "is there an
#    address in argv" -- that second question is answered at RUNTIME by
#    tools/credential-argv-control.sh sampling `ps`, which needs no name table. The two
#    have deliberately non-overlapping blind spots.
# 🔴 两种形态，第二种是这次实撞出来的：
#    ① `--arg e "$email"`                       —— 值走 jq 的参数
#    ② `quota_state_get ".accounts[\"$email\"]"` —— 地址被插进 jq 的**程序文本**
#    ⭐ 只查 ① 的那一版是绿的，而 ② 就在同一个文件里活着，是**运行时穷举通道**抓到的。
#      「遍历到没到」有正控，「模式集全不全」没有——补上第二种，正是补后一问。
# 🔴 Two shapes, and the second one really bit here:
#    ① `--arg e "$email"`                        -- the value is a jq argument
#    ② `quota_state_get ".accounts[\"$email\"]"`  -- the address is interpolated into the
#                                                   jq PROGRAM TEXT
#    ⭐ The version that checked only ① was green while ② was alive in the same file; the
#      runtime exhaustive channel is what caught it. "Did the sweep reach it" has a
#      control; "is the pattern set complete" does not -- adding ② answers that one.
_addr_in_argv() {
  local dir="$1" f
  local vars='email|expected_email|actual_email|before_email|after_email|em|acct|current|to|from|target|cur|HOST_ACCOUNT|QUOTA_RETIRED_ACCOUNTS|QUOTA_DISABLED_ACCOUNTS'
  # ⚠️ 先把整行注释滤掉再匹配。不滤的话，**写下「不许这么写」的那句注释本身**会被报成违规
  #    —— 实撞：lib/reading.sh 里那两行解释「不能用 `.accounts[\"$email\"]`」的注释，
  #    把这条判据打红了。⭐ 排查者变成了事件源；判据该按「哪一行会被执行」判，
  #    不是按「哪一行提到了它」判。
  # ⚠️ Whole-line comments are stripped BEFORE matching. Without that, the very comment
  #    saying "do not write this" is reported as a violation -- measured: the two lines in
  #    lib/reading.sh explaining why `.accounts[\"$email\"]` is wrong turned this check red.
  #    ⭐ The check must judge what EXECUTES, not what MENTIONS it.
  for f in "$dir"/lib/*.sh "$dir/quota-sentinel" "$dir/account-probe"; do
    [[ -f "$f" ]] || continue
    awk -v F="$(basename "$f")" '!/^[[:space:]]*#/ { print F ":" NR ": " $0 }' "$f"
  done | grep -E -- "(--arg [A-Za-z_][A-Za-z0-9_]* \"\\$\{?($vars)[\":}])|(\\[\\\\?\"\\$\{?($vars)[^A-Za-z0-9_])" \
       | cut -c1-140 || true
}

_aia=$(_addr_in_argv "$QS_SOURCE")
if [[ -z "$_aia" ]]; then
  pass "没有账号地址进 jq 命令行（两种形态：--arg 值、插进程序文本）"
else
  fail "账号地址又进了 jq 命令行：$(printf '%s' "$_aia" | tr '\n' '; ')"
fi
# 正控**两种形态各一个**。只造 ① 的正控，就正好复现这次的失败：判据对 ② 恒绿，
# 而正控只证明了 ① 那一半有牙。
# One control PER SHAPE. A control for ① only is exactly how this failed: the check was
# permanently green on ②, and the control only ever proved ① had teeth.
mkdir -p "$TMP/aia/lib" "$TMP/aia2/lib"
cp "$QS_SOURCE"/lib/*.sh "$TMP/aia/lib/"; cp "$QS_SOURCE"/lib/*.sh "$TMP/aia2/lib/"
printf '\n_posctrl_addr() { jq -cn --arg e "$email" %s; }\n' "'\$e'" >> "$TMP/aia/lib/detect.sh"
printf '\n_posctrl_addr2() { quota_state_get ".accounts[\\"$email\\"].five" ""; }\n' >> "$TMP/aia2/lib/detect.sh"
_aia_pc1=$(_addr_in_argv "$TMP/aia"); _aia_pc2=$(_addr_in_argv "$TMP/aia2")
if [[ -n "$_aia_pc1" && -n "$_aia_pc2" ]]; then
  pass "正控：① 地址进 --arg 与 ② 地址插进 jq 程序文本，两种形态都抓得到"
else
  fail "正控没红（①=[${_aia_pc1:-空}] ②=[${_aia_pc2:-空}]）：该形态上这条判据没有分辨力"
fi

# ── 静态面：整屏内容也不得进命令行 ──
# 🔴 G-10 挪走的是账号**地址**；而**地址所在的那张屏**当时还在从旁边走过去。
#    基线的 `quota_panel_log_observation` 用 `--arg frame "$frame"` 把 `capture-pane -p`
#    抓来的**整个可见 pane** 交给 jq ⇒ 整屏内容躺在那个 jq 进程的 `/proc/<pid>/cmdline`
#    里，**世界可读**，每 10 秒一拍，而且**与它最终有没有落盘无关**。
#    ⭐ 这就是「只关掉落盘」的那个修法会留下的洞：磁盘干净了，命令行还在广播。
# 🔴 G-10 moved the account ADDRESSES off command lines; the SCREEN those addresses appear
#    on was still going past it. The baseline handed `capture-pane -p`'s whole visible
#    pane to jq as `--arg frame "$frame"`, so the entire screen sat in that jq process's
#    world-readable `/proc/<pid>/cmdline`, once every 10 seconds — and that happened
#    whether or not anything was ever written to disk.
#    ⭐ That is precisely the hole a disk-only fix would leave: a clean file, and a
#      command line still broadcasting.
# ⚠️ 口径与 `_addr_in_argv` 相同、局限也相同：按**变量名**认，认的是下面这张表。
#    它答的是「已知持有整屏的变量有没有被放上命令行」，不答「argv 里有没有屏内容」。
# ⚠️ Same scope and same limit as `_addr_in_argv`: it recognises BY VARIABLE NAME, from
#    the table below. It answers "did a known screen-bearing variable get put on a command
#    line", not "is there screen content in argv".
_frame_in_argv() {
  local dir="$1" f
  local vars='frame|QUOTA_PANEL_FRAME_LAST'
  for f in "$dir"/lib/*.sh "$dir/quota-sentinel" "$dir/account-probe"; do
    [[ -f "$f" ]] || continue
    awk -v F="$(basename "$f")" '!/^[[:space:]]*#/ { print F ":" NR ": " $0 }' "$f"
  done | grep -E -- "--arg[a-z]* [A-Za-z_][A-Za-z0-9_]* \"\\$\{?($vars)[\":}]" \
       | cut -c1-140 || true
}
_fia=$(_frame_in_argv "$QS_SOURCE")
if [[ -z "$_fia" ]]; then
  pass "没有整屏内容进 jq 命令行（帧改走 \$ENV.QS_JQ_FRAME）"
else
  fail "整屏内容又进了命令行：$(printf '%s' "$_fia" | tr '\n' '; ')"
fi
mkdir -p "$TMP/fia/lib"
cp "$QS_SOURCE"/lib/*.sh "$TMP/fia/lib/"
printf '\n_posctrl_frame() { jq -cn --arg f "$frame" %s; }\n' "'\$f'" >> "$TMP/fia/lib/detect.sh"
_fia_pc=$(_frame_in_argv "$TMP/fia")
if [[ -n "$_fia_pc" ]]; then
  pass "正控：把帧放回 --arg 之后这条判据确实抓得到（它会红）"
else
  fail "正控没红：帧放回 --arg 也扫不出来，上面那条绿没有分辨力"
fi

echo "── 靠全局变量回传结果的函数，不许被命令替换调用 ──"
# ⭐ The upstream case guards a BASH LANGUAGE trap that has nothing to do with that
#    environment, which is why it came across: when a caller writes `n=$(some_fn ...)`,
#    the command substitution runs in a SUBSHELL, so assignments the function makes to
#    globals never reach the parent shell. Upstream the symptom looked like a single `?`
#    in a log; the actual consequence was far worse -- the counter was permanently 0, so
#    the "delivery failed -> a human is needed" alarm **could never fire**, and a real
#    failure was reported as "skipped this round, no action needed".
#    The note upstream records this as the FIFTH time that trap was hit.
# ⭐ 上游用例 #100 守的是一个 bash 语言级陷阱，与那套环境毫无关系，所以搬过来：
#    调用方写 `n=$(some_fn ...)` 时，命令替换在**子 shell** 里跑，函数里对全局变量的
#    赋值传不回父 shell。上游那次的症状看着只是日志里一个 `?`，实际后果严重得多——
#    计数恒为 0，于是「投递失败 → 需要人工介入」那条告警**永远不会触发**，真失败被报成
#    「本轮跳过，无需人工」。注释里记着「本仓第 5 次踩」。
# 🔴 本仓同样有一批靠全局回传的函数（QUOTA_GUARD_EMAIL / QUOTA_PANEL_LAST /
#    QUOTA_LAST_ERROR / QUOTA_REFRESH_SEQ …），踩法一模一样。上游那条用例测的是某一个
#    具体调用点；这里改成**结构判据**，覆盖全部调用点、也覆盖以后新写的：
#    凡是会写这些全局的函数，都不许出现在 `$( )` 里面。
_outparam_violations() {
  local dir="$1" outs='QUOTA_GUARD_EMAIL|QUOTA_GUARD_UUID|QUOTA_LAST_ERROR|QUOTA_PANEL_LAST|QUOTA_PANEL_FRAME_LAST|QUOTA_PANEL_STATUS_LAST|QUOTA_REFRESH_SEQ'
  local files fn setters=""
  files=$(ls "$dir"/lib/*.sh "$dir"/quota-sentinel 2>/dev/null)
  # Which functions write these globals: attribute by "the most recent function
  # definition above", in a single awk pass.
  # 哪些函数会写这些全局：按「上一处函数定义」归属，awk 一趟扫完
  setters=$(awk -v outs="$outs" '
      /^[a-z_][a-z0-9_]*\(\)/ { fn=$0; sub(/\(\).*/,"",fn) }
      fn != "" && $0 ~ ("(^|[^A-Za-z0-9_])(" outs ")=") { print fn }
    ' $files | sort -u)
  [[ -n "$setters" ]] || { echo "NO-SETTERS-FOUND"; return 0; }
  for fn in $setters; do
    grep -nE '\$\([^)]*\b'"$fn"'\b' $files | sed "s/^/${fn}: /"
  done
}
_ops=$(_outparam_violations "$QS_SOURCE")
if [[ -z "$_ops" ]]; then
  pass "没有任何靠全局回传的函数被写在命令替换里"
elif [[ "$_ops" == "NO-SETTERS-FOUND" ]]; then
  fail "一个写这些全局的函数都没找到 —— 这个判据此刻什么也没在守"
else
  fail "这些调用在子 shell 里跑，全局回传会丢：$(printf '%s' "$_ops" | tr '\n' ' ')"
fi
# ⚠️ Positive control: the check has to actually be able to go red. Make a copy with a
#    violating call injected and scan it again.
#    ⭐ Without this, the "zero hits" above is indistinguishable from "the scanner never
#      looked at these files at all".
# ⚠️ 正控：判据必须真的会红。造一份注入了违规调用的副本再扫一次。
#    ⭐ 没有这一条，上面那个「零命中」与「扫描器根本没看这些文件」长得一模一样。
mkdir -p "$TMP/cmdsub-pc/lib"
cp "$QS_SOURCE"/lib/*.sh "$TMP/cmdsub-pc/lib/"
cp "$QS_SOURCE/quota-sentinel" "$TMP/cmdsub-pc/"
printf '%s\n' 'probe_value=$(quota_account_guard "injected-violation")' >> "$TMP/cmdsub-pc/lib/state.sh"
# ⚠️ Assign to a variable first and test that; do **not** write
#    `_outparam_violations … | grep -q …`. This file has `pipefail` on, and `grep -q`
#    closes the pipe the instant it matches, so the upstream greps take SIGPIPE and exit
#    non-zero, making the whole pipeline non-zero -- **a match gets reported as no match**.
#    This control failed exactly that way on its first run, presenting as "the injected
#    violation cannot be detected", which looks like the check itself being useless.
# ⚠️ 先落到变量再判，**不要**写成 `_outparam_violations … | grep -q …`：本文件开着
#    `pipefail`，而 `grep -q` 命中就立刻关掉管道，上游那些 grep 拿到 SIGPIPE 退非零，
#    整条管道于是非零 —— **命中会被报成没找到**。这条正控第一次跑就栽在这里，
#    表现成「注入了违规也扫不出来」，看着像判据本身没用。
_ops_pc=$(_outparam_violations "$TMP/cmdsub-pc")
if [[ "$_ops_pc" == *quota_account_guard* ]]; then
  pass "正控：注入一处违规调用之后判据确实抓到了（它会红）"
else
  fail "正控没红：注入了违规调用也扫不出来，上面那条绿没有分辨力"
fi


echo "── 判据里不许出现「管道末端是 grep -q」──"
# 🔴 本仓在 `set -o pipefail` 下运行，而 `grep -q` 一命中就退出；上游还在往一根已关闭的
#    管道里写，于是被 SIGPIPE 打死，**整条管道回报 141，尽管模式明明命中了**。调用方读到
#    的是「没匹配」。⭐ 后果不是「偶尔慢一点」：一个屏上明明有选单的判据会间歇性地报
#    「没有选单」——与当年「文案改了就哑掉 28 天」同一种后果，只是这次看起来像负载抖动。
#    实测（抽取出来的同一份代码、空闲机器）：800 次调用错 61 次（7.6%）；连续 10 轮
#    --fast 里 9 轮至少错一次。改法是把匹配写成 here-string：重定向不是管道，
#    没有东西会 SIGPIPE，pipefail 也就无从传播。
# _pipeline_grepq <files…> — 报出「在 pipefail 下、管道末端是 grep -q」的行。
#
# ⚠️ 判「在不在 pipefail 下」有一条明确规则，写出来免得靠猜：
#   · **有 shebang** ⇒ 独立脚本，**只有它自己 set 了 pipefail 才算**在这个作用域里。
#     （`tools/cleanroom-assert.sh` 正是这一格：它有同样的写法，但**没开 pipefail**，
#       所以那行是安全的，不该被判红，也不该被顺手改掉。）
#   · **没有 shebang** ⇒ 被 source 的库，pipefail 由 source 它的那个进程决定 ⇒ **一律算**。
#     （`lib/*.sh` 自己都没 set，是 `quota-sentinel` 设的。）
# ⚠️ 这条规则的**边界**：一个既有 shebang、又被别处 source 的文件会被判错。本仓没有这种
#    文件；有了就要改这条规则，而不是给它开个例外。
# ⚠️ The rule for "is this file under pipefail" is stated rather than guessed:
#    a shebang means standalone (in scope only if it sets pipefail itself); no shebang
#    means it is sourced, and inherits pipefail from whoever sources it (always in scope).
#    Known limit: a file that has a shebang AND is also sourced elsewhere is misjudged.
#    None exist here; if one appears, change the rule rather than granting it an exception.
_pipeline_grepq() {
  local f under=()
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    # Exclude the frozen fixture BY PATH: it is the pre-fix original, so a hit there is
    # correct and editing it would be the mistake.
    # By path -- not by "its own comment says it is frozen", which would let any file
    # exempt itself by claiming to be one.
    # 冻结件按**路径**排除：它是修复前的原文，在那里命中是对的，改它才是错。
    # 按路径排除，不按「它注释里说自己是冻结件」排除。
    [[ "$f" == */test/fixtures/legacy-detectors.sh ]] && continue
    # (This line used to be `head -c2 … | grep -qF`. After the scope was widened, **the
    #  check caught itself** -- which is exactly what it should do. The fix was to stop
    #  using a pipe here, NOT to grant itself an exemption.)
    # （这一行原本写成 `head -c2 … | grep -qF`——扩作用域之后**判据抓到了它自己**。
    #   那正是它该干的事：改成不用管道，而不是给自己开例外。）
    if [[ "$(head -c2 "$f")" == '#!' ]]; then
      grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*o?[[:space:]]+pipefail|^[[:space:]]*set[[:space:]]+-o[[:space:]]+pipefail' "$f" || continue
    fi
    under+=("$f")
  done
  (( ${#under[@]} )) || { echo "NO-FILES-IN-SCOPE"; return 0; }
  # Only `grep -q` AT THE END OF A PIPE: `| grep -q…`. Here-strings and standalone
  # `grep -q` are not in scope.
  # ⚠️ **State the boundary out loud**: the same SIGPIPE mechanism applies to other
  #    early-exiting pipe ends such as `| head -n1` and `| grep -m1`. They are not listed
  #    because at the few places this repo uses them **the exit code is not consumed**
  #    (only the output is), so listing them would manufacture a permanently red check.
  #    ⇒ This check answers "the grep -q family", NOT "every pipeline that can SIGPIPE".
  #    Written down so that a later reader does not mistake the silence for coverage.
  # 只挑「管道末端」的 grep -q：`| grep -q…`。here-string 与独立的 grep -q 不在此列。
  # ⚠️ 判据的**边界要说出来**：同一个 SIGPIPE 机制也适用于 `| head -n1`、`| grep -m1`
  #    这类会提前退出的末端。它们没被列进来，是因为本仓里那几处的**退出码没有被消费**
  #    （只取输出），列进来只会造出恒红。⇒ 这条判据答的是「grep -q 这一族」，
  #    不是「所有会 SIGPIPE 的管道」。写下来，免得后来者把沉默当成覆盖。
  grep -nE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' "${under[@]}" 2>/dev/null \
    | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true
}
_pg=$(_pipeline_grepq \
        "$QS_SOURCE"/lib/*.sh "$QS_SOURCE/quota-sentinel" "$QS_SOURCE/account-probe" \
        "$QS_SOURCE"/test/*.sh "$QS_SOURCE"/tools/*.sh)
if [[ "$_pg" == "NO-FILES-IN-SCOPE" ]]; then
  fail "作用域筛完一个文件都不剩 —— 这条判据此刻什么也没在守（规则或路径错了）"
elif [[ -z "$_pg" ]]; then
  pass "作用域内（lib/、CLI、account-probe、test/、tools/，按上面那条规则筛过）没有「管道末端 grep -q」"
else
  fail "这些管道会把命中报成没命中：$(printf '%s' "$_pg" | tr '\n' ' ')"
fi
# Positive control: inject one into a copy; the check has to catch it.
# 正控：往副本里注入一处，判据必须抓到。
mkdir -p "$TMP/pipegrep-pc"
cp "$QS_SOURCE"/lib/*.sh "$TMP/pipegrep-pc/"
# ⚠️ The violating line is assembled at run time from fragments, so that THIS file does
#    not itself contain the pattern the check hunts for. Otherwise the check goes red on
#    its own source — permanently — and a permanently red check trains people to walk
#    past red. Do not "tidy" this back into one literal.
# ⚠️ 违规那行是运行时拼出来的，好让**本文件自己**不含被查的那个形状。否则这条判据会在
#    自己的源码上恒红，而恒红的判据会训练出「看到红也照过」。别把它「整理」回一整条字面量。
_pg_bad='| grep'; _pg_bad="$_pg_bad -q needle"
printf '%s\n' "quota_posctrl_probe() { printf '%s' \"\$1\" $_pg_bad; }" >> "$TMP/pipegrep-pc/detect.sh"
_pg_pc=$(_pipeline_grepq "$TMP/pipegrep-pc"/*.sh)
if [[ "$_pg_pc" == *"grep -q needle"* ]]; then
  pass "正控：注入一处管道末端 grep -q 之后判据确实抓到了（它会红）"
else
  fail "正控没红：注入了也扫不出来，上面那条绿没有分辨力"
fi

echo "── 同一帧反复喂给判据，结果必须每次一样 ──"
# The one above is a STRUCTURAL check; this one is a BEHAVIOURAL check. They guard the
# same thing but **answer different questions**: the structural one answers "is that
# spelling still anywhere in the code", the behavioural one answers "is this predicate
# stable right now".
# Keep only the structural one and any uncertainty from ANY OTHER source goes unnoticed.
# ⚠️ 200 iterations comes from the measured 7.6% error rate: the chance of missing a real
#    regression to the old spelling is about 1e-7.
# 上面那条是结构判据；这条是行为判据。两条守的是同一件事，但**答的是不同的问题**：
# 结构判据答「代码里还有没有这种写法」，行为判据答「此刻这个判据稳不稳」。
# 只留结构判据的话，任何**别的**来源的不确定性都不会被发现。
# ⚠️ 200 次是按实测的 7.6% 错误率定的：真回归到旧写法时漏掉的概率约 1e-7。
_menu_frame=$(read_fx menu-new-wording.txt)
_stable_bad=0
for _i in $(seq 1 200); do
  quota_menu_present "$_menu_frame" || _stable_bad=$((_stable_bad+1))
done
if (( _stable_bad == 0 )); then
  pass "同一帧连喂 200 次，选单判据 200 次都认得出（没有间歇性漏判）"
else
  fail "200 次里有 $_stable_bad 次没认出同一帧 —— 判据不稳定，绿也不能当数"
fi
# Positive control: feed a frame that must NOT match, 200 times, and require zero matches
# -- otherwise an "always true" implementation would pass the check above just as well.
# 正控：换一帧**不该命中**的，必须 200 次都不命中；否则上面那条用「恒真」实现也全绿。
_nomenu_frame=$(read_fx menu-in-scrollback.txt)
_stable_false=0
for _i in $(seq 1 200); do
  quota_menu_present "$_nomenu_frame" && _stable_false=$((_stable_false+1))
done
if (( _stable_false == 0 )); then
  pass "正控：不该命中的那帧连喂 200 次也 200 次都不命中（上一条不是恒真）"
else
  fail "不该命中的帧有 $_stable_false 次命中了"
fi

echo "── 账号守卫：外部漂移分支不得因为一个未定义变量而杀死进程 ──"
# The branch above is only reachable when the state file and the config file disagree
# about which account is logged in, which is why no earlier test walked into it. This
# one constructs that disagreement on purpose and asserts the guard **returns** —
# a non-zero return is correct, a dead shell is not.
export QUOTA_CLAUDE_JSON="$TMP/drift-exit.json"
QUOTA_STATE="$TMP/drift-exit-state.json"
QUOTA_SWITCH_LEDGER="$TMP/drift-exit-ledger.jsonl"
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"other@x","accountUuid":"uuid-other"},
 "cachedUsageUtilization":{"accountUuid":"uuid-other"}}
JSON
drift_out=$( set -u; quota_account_guard "test-drift-survives" 2>&1; printf 'RC=%s' "$?" )
if [[ "$drift_out" == *"RC=1"* && "$drift_out" != *"unbound"* && "$drift_out" != *"未绑定"* ]]; then
  pass "漂移分支正常返回 1，没有因未绑定变量而退出"
else
  fail "漂移分支没有干净返回（这正是缺定义时的表现）：$drift_out"
fi
# Positive and negative control in one: unset that variable, take the same path again,
# and the breakage has to be visible.
# 负控/正控合一：把那个变量 unset 掉再走同一条路，必须看到它坏。
drift_bad=$( set -u; unset QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL; quota_account_guard "test-drift-unset" 2>&1; printf 'RC=%s' "$?" )
if [[ "$drift_bad" == *"unbound"* || "$drift_bad" == *"未绑定"* ]]; then
  pass "正控：把它 unset 之后同一条路确实坏掉（上面那条不是恒真）"
else
  fail "正控没红：unset 之后仍然一切正常，说明上面那条断言不测任何东西（got=$drift_bad）"
fi
QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL=300
unset QUOTA_CLAUDE_JSON

echo "── 时区偏移必须是解析出来的，不是写死的 +8 ──"
# Upstream hard-coded +8 in the human-readable time layer; extraction replaced that with
# resolving it from the host. The whole suite is pinned to TZ=CST-8, which makes the
# assertions reproducible -- but that same pinning makes "hard-coded +8" and "resolved to
# +8" look identical.
# ⇒ Re-run the same parse under a DIFFERENT zone: the result must **change with it**.
# 上游把 +8 写死在可读时间那一层；抽取时换成从宿主解析。整套回归钉在 TZ=CST-8 下跑，
# 那让断言可复现，但同时也会让「写死 +8」和「解析到 +8」长得一模一样。
# ⇒ 换一个时区重跑同一个解析：结果必须**跟着变**。
iso_at_plus8=$(quota_iso_epoch "2026-08-11T08:10:00.492913+00:00" || echo "")
hm_plus8=$(TZ=CST-8 date -d "@${iso_at_plus8:-0}" '+%H:%M')
hm_utc=$(TZ=UTC date -d "@${iso_at_plus8:-0}" '+%H:%M')
if [[ "$hm_plus8" == "16:10" && "$hm_utc" == "08:10" ]]; then
  pass "同一 epoch 在 +8 与 UTC 下分别渲染成 16:10 / 08:10（偏移量真的参与了运算）"
else
  fail "渲染不随时区变化，说明某处把偏移写死了（+8=$hm_plus8 utc=$hm_utc）"
fi

echo "── 渲染时刻：必须是「UTC 渲染 + 偏移量算术」，不许在渲染时查时区库 ──"
# G-4 事故 (a)/(b) 的守卫是 `lib/state.sh :: quota_fmt_ts()`，但在 2026-08-31 之前
# **整套回归一次都没有调用过它**：把它改回 `TZ=$QUOTA_TZ_LABEL date -d @ts`（正是那次
# 事故的写法，本机实测把 08:26 渲染成 00:26）之后，套件仍然 PASS 197 FAIL 0。
# ⭐ 这就是本仓自己反复写下的那句话的又一个实例：**一条从来没红过的守卫，绿了也不说明问题**。
# ⚠️ 三条里只有后两条有分辨力。第①条（换进程 TZ 结果不变）对**修复前那版也成立**——
#    因为它查的是写死的 label——所以单独用它是恒真的。留着它是因为它盯的是另一件事
#    （渲染不受调用方环境影响），但它不能替代②③。
_fmt_e=1756600000                       # 2026-08-31 08:26:40 +0800 / 00:26:40 UTC
_fmt_utc=$(TZ=UTC   quota_fmt_ts "$_fmt_e" '%H:%M')
_fmt_p8=$(TZ=CST-8  quota_fmt_ts "$_fmt_e" '%H:%M')
_fmt_z=$(QUOTA_TZ_OFFSET_SEC=0 quota_fmt_ts "$_fmt_e" '%H:%M')
if [[ "$_fmt_utc" == "$_fmt_p8" ]]; then
  pass "渲染不随调用方进程 TZ 变化（渲染时没查时区库）"
else
  fail "渲染随进程 TZ 变了（TZ=UTC → $_fmt_utc，TZ=CST-8 → $_fmt_p8），说明渲染时查了时区库"
fi
if [[ "$_fmt_utc" == "08:26 +0800" ]]; then
  pass "epoch 按 QUOTA_TZ_OFFSET_SEC=+8 渲染成 08:26（不是 UTC 的 00:26）"
else
  fail "渲染时刻错了（got=$_fmt_utc，期望 08:26 +0800）——差 8 小时正是事故 (a) 的形状"
fi
if [[ "$_fmt_z" != "$_fmt_utc" ]]; then
  pass "改 QUOTA_TZ_OFFSET_SEC 会改变渲染结果（偏移量真的参与了算术）"
else
  fail "把偏移量改成 0 渲染结果不变（$_fmt_z），说明渲染没用它，而是查了别的东西"
fi
unset _fmt_e _fmt_utc _fmt_p8 _fmt_z

echo "── 换算常数：增量只能在同一主体内累加，跨账号必须断开 ──"
# G-7 事故：累加两个窗口的增量算换算常数，首次实测算出 −0.434（物理上不可能，两个窗口
# 都只会涨）。根因是样本里混进了监控还挂在**上一个账号**时的读数，值在两个账号的数之间
# 来回跳。守卫是 `lib/state.sh :: quota_ratio_update()` 里的 `l_acct == acct`。
# ⚠️ 2026-08-31 之前这个函数在整套回归里**只被打桩、从未被真实调用**：把它整个掏空成
#    `quota_ratio_update() { return 0; }` 之后，套件仍然 PASS 197 FAIL 0。
# ⭐ 期望值写成「哪几个数」而不是「有没有报错」：跨主体累加不报错，它只是把一个物理上
#    不可能的常数安静地写进账里。
_ru_state="$QUOTA_STATE"
QUOTA_STATE="$TMP/ratio-subject.json"; echo '{}' > "$QUOTA_STATE"
_ru(){ jq -r '"\(.ratio.five_total // 0)/\(.ratio.week_total // 0)"' "$QUOTA_STATE"; }
quota_ratio_update 1000 ratioA@x 10 5
_ru_1=$(_ru)
quota_ratio_update 1010 ratioA@x 30 9
_ru_2=$(_ru)
quota_ratio_update 1020 ratioB@x 80 90     # 换账号：这一步一个增量都不许进账
_ru_3=$(_ru)
quota_ratio_update 1030 ratioB@x 85 92
_ru_4=$(_ru)
if [[ "$_ru_1" == "0/0" && "$_ru_2" == "20/4" ]]; then
  pass "同一账号内累加增量（10→30 记 +20，5→9 记 +4；首帧只立基线不累加）"
else
  fail "同账号累加错了（首帧=$_ru_1 期望 0/0；第二帧=$_ru_2 期望 20/4）"
fi
if [[ "$_ru_3" == "20/4" ]]; then
  pass "换到另一个账号那一帧不累加（跨主体差值不进账，−0.434 那次的根因）"
else
  fail "跨账号的差值被累加进了同一个常数（got=$_ru_3，期望仍是 20/4）"
fi
if [[ "$_ru_4" == "25/6" ]]; then
  pass "换账号之后以新账号为基线继续累加（断开的是跨主体那一步，不是整条链）"
else
  fail "换账号后没能重新建立基线继续累加（got=$_ru_4，期望 25/6）"
fi
QUOTA_STATE="$_ru_state"
unset _ru_state _ru_1 _ru_2 _ru_3 _ru_4
unset -f _ru
}

# ── monitor lifecycle / monitor 生命周期 ──
run_monitor_tests() {
echo "── monitor 重启：保留 tmux/pane，只在原 shell 内替换 客户端 ──"
# 活体已证明 `/exit` 后 tmux session/window/pane 与 shell PID 都不变，而 Claude 子进程
# 会换新。旧实现直接 kill-session，会改变 session_created，随后 poller 又按代际不匹配
# 重启第二次。这里先把编排钉死：已有 monitor 只能 exit→launch→bind，不能 kill/new。
MONITOR_RESTART_TRACE="$TMP/monitor-restart-trace"
: > "$MONITOR_RESTART_TRACE"
_stub_save quota_monitor_alive quota_monitor_exit_to_shell quota_monitor_launch_in_pane \
           quota_monitor_bind_owner quota_monitor_ensure quota_account_guard \
           quota_session_created quota_monitor_live_launch_id quota_monitor_shell_ready \
           quota_monitor_single_pane_id
quota_monitor_alive() { return 0; }
quota_monitor_single_pane_id() { printf '%%1\n'; }
quota_monitor_shell_ready() { return 1; }
quota_monitor_exit_to_shell() { printf 'exit\n' >> "$MONITOR_RESTART_TRACE"; return 0; }
quota_monitor_launch_in_pane() {
  QUOTA_MONITOR_STARTED_LAUNCH_ID='launch-new'
  QUOTA_MONITOR_STARTED_EMAIL='target@x'
  QUOTA_MONITOR_STARTED_UUID='uuid-target'
  printf 'launch\n' >> "$MONITOR_RESTART_TRACE"; return 0
}
quota_monitor_bind_owner() {
  printf 'bind:%s:%s:%s\n' "$2" "$3" "$4" >> "$MONITOR_RESTART_TRACE"; return 0
}
quota_monitor_ensure() { printf 'ensure\n' >> "$MONITOR_RESTART_TRACE"; return 0; }
quota_account_guard() {
  QUOTA_GUARD_EMAIL='target@x'; QUOTA_GUARD_UUID='uuid-target'; return 0
}
quota_session_created() { printf '100\n'; }
quota_monitor_live_launch_id() { printf 'launch-new\n'; }
tmux() {
  case "${1:-}" in
    kill-session) printf 'kill-session\n' >> "$MONITOR_RESTART_TRACE" ;;
    new-session)  printf 'new-session\n' >> "$MONITOR_RESTART_TRACE" ;;
  esac
  return 0
}
if quota_monitor_restart 'target@x' 'uuid-target' >/dev/null 2>&1 \
   && [[ "$(tr '\n' ' ' < "$MONITOR_RESTART_TRACE")" == \
         "exit launch bind:target@x:uuid-target:launch-new " ]]; then
  pass "已有 monitor 在原 pane 内 /exit→新 客户端→owner 绑定，不杀/重建 tmux"
else
  fail "monitor restart 仍破坏 tmux 或没有原子绑定：$(tr '\n' ' ' < "$MONITOR_RESTART_TRACE")"
fi

: > "$MONITOR_RESTART_TRACE"
quota_monitor_shell_ready() { return 0; }
if quota_monitor_restart 'target@x' 'uuid-target' >/dev/null 2>&1 \
   && [[ "$(tr '\n' ' ' < "$MONITOR_RESTART_TRACE")" == \
         "launch bind:target@x:uuid-target:launch-new " ]]; then
  pass "monitor 已退回 shell 时直接拉起新 客户端，不会再向 shell 发送 /exit"
else
  fail "shell 恢复路径仍先发 /exit 或遗漏绑定：$(tr '\n' ' ' < "$MONITOR_RESTART_TRACE")"
fi

: > "$MONITOR_RESTART_TRACE"
quota_account_guard() { return 1; }
if ! quota_monitor_restart 'target@x' 'uuid-target' >/dev/null 2>&1 \
   && [[ ! -s "$MONITOR_RESTART_TRACE" ]]; then
  pass "显式 expected 在重启前重新核验账号；漂移时不碰 monitor UI"
else
  fail "账号已漂移仍执行了 monitor 重启：$(tr '\n' ' ' < "$MONITOR_RESTART_TRACE")"
fi
_tmux_guard_install   # 不留裸奔窗口：清桩即重装闸
_stub_restore quota_monitor_alive quota_monitor_exit_to_shell quota_monitor_launch_in_pane \
              quota_monitor_bind_owner quota_monitor_ensure quota_account_guard \
              quota_session_created quota_monitor_live_launch_id quota_monitor_shell_ready \
              quota_monitor_single_pane_id

# Once tmux stops being recreated, session_created no longer changes, so a separate client
# launch id is required. Otherwise an older statusLine callback, or an older client's
# screen in the same pane, can pass itself off as the new process's owner proof.
# tmux 不再重建后 session_created 不变，必须另有客户端 launch id。否则同 pane 里的旧
# statusLine 回调/旧客户端画面可以冒用新进程 owner 证明。
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x","monitor_account":"target@x",
 "monitor_uuid":"uuid-target","monitor_session_created":100,
 "monitor_launch_id":"launch-old",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
if declare -F quota_monitor_live_launch_id >/dev/null 2>&1 && (
  quota_session_created() { printf '100\n'; }
  quota_monitor_live_launch_id() { printf 'launch-new\n'; }
  ! quota_monitor_owner_guard "test-monitor-cc-generation" >/dev/null 2>&1
); then
  pass "tmux 代际相同但 客户端 launch id 不同 → 旧进程 owner 证明失效"
else
  fail "只看 session_created，原 pane 内换 客户端 后无法区分新旧进程"
fi

# restart 已经负责启动并绑定，prepare_owner 不得紧接着再 bind/再触发一次换代。
PREPARE_TRACE="$TMP/monitor-prepare-restart-trace"
: > "$PREPARE_TRACE"
_stub_save quota_account_guard quota_monitor_alive quota_monitor_restart \
           quota_monitor_bind_owner quota_session_created quota_monitor_live_launch_id \
           quota_monitor_shell_ready quota_monitor_panel_open quota_monitor_ready \
           quota_monitor_single_pane_id
quota_account_guard() { QUOTA_GUARD_EMAIL='target@x'; QUOTA_GUARD_UUID='uuid-target'; return 0; }
quota_monitor_alive() { return 0; }
quota_monitor_single_pane_id() { printf '%%1\n'; }
quota_monitor_shell_ready() { return 1; }
quota_monitor_panel_open() { return 0; }
quota_monitor_ready() { return 1; }
quota_monitor_restart() { printf 'restart\n' >> "$PREPARE_TRACE"; return 0; }
quota_monitor_bind_owner() { printf 'bind\n' >> "$PREPARE_TRACE"; return 0; }
quota_session_created() { printf '100\n'; }
quota_monitor_live_launch_id() { printf 'launch-new\n'; }
cat > "$QUOTA_STATE" <<'JSON'
{"monitor_account":"old@x","monitor_uuid":"uuid-old",
 "monitor_session_created":100,"monitor_launch_id":"launch-old"}
JSON
if quota_monitor_prepare_owner >/dev/null 2>&1 \
   && [[ "$(tr '\n' ' ' < "$PREPARE_TRACE")" == "restart " ]]; then
  pass "owner/cc 代际变化只做一次 restart；restart 内已绑定，外层不重复"
else
  fail "prepare_owner 在 restart 后仍重复 bind/换代：$(tr '\n' ' ' < "$PREPARE_TRACE")"
fi

: > "$PREPARE_TRACE"
quota_monitor_shell_ready() { return 0; }
cat > "$QUOTA_STATE" <<'JSON'
{"monitor_account":"target@x","monitor_uuid":"uuid-target",
 "monitor_session_created":100,"monitor_launch_id":"launch-new"}
JSON
if quota_monitor_prepare_owner >/dev/null 2>&1 \
   && [[ "$(tr '\n' ' ' < "$PREPARE_TRACE")" == "restart " ]]; then
  pass "owner/launch 虽匹配但 客户端 已回 shell → prepare_owner 仍只恢复一次"
else
  fail "tmux 活着掩盖了已退出的 客户端：$(tr '\n' ' ' < "$PREPARE_TRACE")"
fi
_stub_restore quota_account_guard quota_monitor_alive quota_monitor_restart \
              quota_monitor_bind_owner quota_session_created quota_monitor_live_launch_id \
              quota_monitor_shell_ready quota_monitor_panel_open quota_monitor_ready \
              quota_monitor_single_pane_id

echo "── monitor 原 pane 换代：/exit 必须回 shell，pane 身份变化一律拒绝 ──"
MONITOR_FAKE_PHASE="$TMP/monitor-fake-phase"
MONITOR_FAKE_LAUNCH="$TMP/monitor-fake-launch"
MONITOR_FAKE_TRACE="$TMP/monitor-fake-trace"
printf 'old\n' > "$MONITOR_FAKE_PHASE"; printf 'launch-old\n' > "$MONITOR_FAKE_LAUNCH"; : > "$MONITOR_FAKE_TRACE"
_stub_save quota_identity_read quota_monitor_new_launch_id quota_log
quota_identity_read() { printf 'target@x\037uuid-target\037uuid-target\n'; }
quota_monitor_new_launch_id() { printf 'launch-new\n'; }
quota_log() { printf 'log:%s\n' "$1" >> "$MONITOR_FAKE_TRACE"; }
tmux() {
  local phase last format pane='%71'
  phase=$(cat "$MONITOR_FAKE_PHASE")
  last="${!#}"
  case "${1:-}" in
    has-session) return 0 ;;
    list-panes)
      if [[ "${MONITOR_FAKE_MULTI_PANE:-0}" == '1' ]]; then
        printf '%%71\n%%72\n'
      else
        printf '%%71\n'
      fi
      return 0
      ;;
    display-message)
      format=$last
      if [[ "$format" == *'pane_current_command'* ]]; then
        [[ "$phase" == "shell" || "$phase" == "failed" ]] \
          && printf 'bash\n' || printf 'claude\n'
      elif [[ "$format" == *'pane_id'* ]]; then
        [[ "${MONITOR_FAKE_SWAP_PANE:-0}" == "1" && "$phase" == "shell" ]] && pane='%72'
        printf '4242|%s|9001\n' "$pane"
      elif [[ "$format" == *"$QUOTA_MONITOR_LAUNCH_OPTION"* ]]; then
        cat "$MONITOR_FAKE_LAUNCH"
      else
        printf '4242\n'
      fi
      return 0
      ;;
    capture-pane)
      case "$phase" in
        exit-typed) printf '%s\n' '────────────────' '❯ /exit' ;;
        *) ready_composer_frame ;;
      esac
      return 0
      ;;
    set-option)
      printf '%s\n' "$last" > "$MONITOR_FAKE_LAUNCH"
      printf 'set-launch:%s\n' "$last" >> "$MONITOR_FAKE_TRACE"
      return 0
      ;;
    send-keys)
      if [[ " $* " == *' -l '* ]]; then
        if [[ "$last" == '/exit' ]]; then
          printf 'exit-typed\n' > "$MONITOR_FAKE_PHASE"
          printf 'literal:/exit\n' >> "$MONITOR_FAKE_TRACE"
        elif [[ "$phase" == "shell" ]]; then
          printf 'launch-typed\n' > "$MONITOR_FAKE_PHASE"
          printf 'literal:launch\n' >> "$MONITOR_FAKE_TRACE"
        fi
      elif [[ "$last" == 'C-u' && "$phase" == 'shell' ]]; then
        printf 'clear-shell-line\n' >> "$MONITOR_FAKE_TRACE"
      elif [[ "$last" == 'Enter' ]]; then
        if [[ "$phase" == 'exit-typed' && "${MONITOR_FAKE_EXIT_STUCK:-0}" != '1' ]]; then
          printf 'shell\n' > "$MONITOR_FAKE_PHASE"
          printf 'enter:exit\n' >> "$MONITOR_FAKE_TRACE"
        elif [[ "$phase" == 'launch-typed' ]]; then
          if [[ "${MONITOR_FAKE_LAUNCH_FAIL:-0}" == '1' ]]; then
            printf 'failed\n' > "$MONITOR_FAKE_PHASE"
          else
            printf 'new\n' > "$MONITOR_FAKE_PHASE"
          fi
          printf 'enter:launch\n' >> "$MONITOR_FAKE_TRACE"
        fi
      fi
      return 0
      ;;
    kill-session|new-session)
      printf '%s\n' "$1" >> "$MONITOR_FAKE_TRACE"
      return 0
      ;;
  esac
  return 0
}
sleep() { :; }
SAVED_MONITOR_EXIT_SEC=$QUOTA_MONITOR_EXIT_SEC
SAVED_MONITOR_READY_SEC=$QUOTA_MONITOR_READY_SEC
QUOTA_MONITOR_EXIT_SEC=1
if quota_monitor_exit_to_shell >/dev/null 2>&1 \
   && quota_monitor_launch_in_pane >/dev/null 2>&1 \
   && [[ "$(cat "$MONITOR_FAKE_PHASE")" == 'new' ]] \
   && [[ "$(cat "$MONITOR_FAKE_LAUNCH")" == 'launch-new' ]] \
   && [[ "$(tr '\n' ' ' < "$MONITOR_FAKE_TRACE")" == *'clear-shell-line literal:launch '* ]] \
   && ! grep -qE '^(kill-session|new-session)$' "$MONITOR_FAKE_TRACE"; then
  pass "原 pane 内先清 shell 残留，再完成 /exit→新 客户端；tmux 容器身份保持"
else
  fail "原 pane 换代时序失败：$(tr '\n' ' ' < "$MONITOR_FAKE_TRACE")"
fi

printf 'old\n' > "$MONITOR_FAKE_PHASE"; : > "$MONITOR_FAKE_TRACE"
MONITOR_FAKE_EXIT_STUCK=1 QUOTA_MONITOR_EXIT_SEC=0
if quota_monitor_exit_to_shell >/dev/null 2>&1; then
  fail "/exit 未回 shell 仍继续换代"
elif ! grep -q 'literal:launch' "$MONITOR_FAKE_TRACE"; then
  pass "/exit 未回 shell → fail closed，不发送新 客户端 启动命令"
else
  fail "/exit 失败后仍向旧 客户端 塞了启动命令"
fi
unset MONITOR_FAKE_EXIT_STUCK

printf 'old\n' > "$MONITOR_FAKE_PHASE"; : > "$MONITOR_FAKE_TRACE"
MONITOR_FAKE_SWAP_PANE=1 QUOTA_MONITOR_EXIT_SEC=1
if quota_monitor_exit_to_shell >/dev/null 2>&1; then
  fail "/exit 前后 pane_id 变化仍被当成原 pane 成功"
else
  pass "pane_id/pane_pid/session 任一变化 → 拒绝在未知 pane 启动 客户端"
fi
unset MONITOR_FAKE_SWAP_PANE

printf 'shell\n' > "$MONITOR_FAKE_PHASE"; : > "$MONITOR_FAKE_TRACE"
MONITOR_FAKE_LAUNCH_FAIL=1 QUOTA_MONITOR_READY_SEC=0
if quota_monitor_launch_in_pane >/dev/null 2>&1; then
  fail "启动命令立即失败回 shell仍被旧 composer 冒充 ready"
else
  pass "新 客户端 未离开 shell → 即使屏上残留 composer 形文字也拒绝绑定"
fi
unset MONITOR_FAKE_LAUNCH_FAIL
QUOTA_MONITOR_READY_SEC=$SAVED_MONITOR_READY_SEC

printf 'old\n' > "$MONITOR_FAKE_PHASE"; : > "$MONITOR_FAKE_TRACE"
MONITOR_FAKE_MULTI_PANE=1
if quota_monitor_exit_to_shell >/dev/null 2>&1; then
  fail "专用 monitor 多出 pane 后仍按漂移的 session target 发送 /exit"
elif ! grep -q 'literal:/exit' "$MONITOR_FAKE_TRACE"; then
  pass "monitor session 非唯一单 pane → fail closed，不向未知 active pane 发键"
else
  fail "多 pane 闸在发送 /exit 之后才生效"
fi
unset MONITOR_FAKE_MULTI_PANE

_stub_save quota_account_guard quota_session_created
quota_account_guard() { QUOTA_GUARD_EMAIL='target@x'; QUOTA_GUARD_UUID='uuid-target'; return 0; }
quota_session_created() { printf '4242\n'; }
QUOTA_STATE="$TMP/monitor-bind-launch-state.json"; QUOTA_CACHE_MTIME=""
printf '%s\n' '{"monitor_launch_id":"launch-old"}' > "$QUOTA_STATE"
printf 'launch-hijacked\n' > "$MONITOR_FAKE_LAUNCH"
if ! quota_monitor_bind_owner bind-test target@x uuid-target launch-new \
      target@x uuid-target >/dev/null 2>&1 \
   && [[ "$(quota_state_get '.monitor_launch_id' '')" == 'launch-old' ]]; then
  pass "owner 只绑定本次 launch 返回的 ID；并发改写 tmux option 时拒绝落盘"
else
  fail "bind 接受了非本次启动的任意 live launch id"
fi

printf 'launch-new\n' > "$MONITOR_FAKE_LAUNCH"
if ! quota_monitor_bind_owner bind-test target@x uuid-target launch-new \
      transient-b@x uuid-b >/dev/null 2>&1 \
   && [[ "$(quota_state_get '.monitor_launch_id' '')" == 'launch-old' ]]; then
  pass "凭据 A→B→A 时拒绝把 B 启动的 客户端 绑定成 A（launch-time 身份闭环）"
else
  fail "bind 只核最终文件，接受了启动瞬间属于 B 的 monitor"
fi
_stub_restore quota_account_guard quota_session_created

QUOTA_MONITOR_EXIT_SEC=$SAVED_MONITOR_EXIT_SEC
unset -f sleep; _tmux_guard_install   # 不留裸奔窗口：清桩即重装闸
_stub_restore quota_identity_read quota_monitor_new_launch_id quota_log

echo "── monitor 操作互斥：poll 与人工 restart/ensure 不得同时驱动同一 pane ──"
MONITOR_LOCK_PROBE="$TMP/monitor-lock-probe"
rm -f "$MONITOR_LOCK_PROBE" "$QUOTA_MONITOR_OP_LOCK"
monitor_lock_probe() { printf 'ran\n' >> "$MONITOR_LOCK_PROBE"; }
exec {MONITOR_HELD_FD}> "$QUOTA_MONITOR_OP_LOCK"
flock "$MONITOR_HELD_FD"
if quota_monitor_op_run try monitor_lock_probe >/dev/null 2>&1 \
   && [[ ! -e "$MONITOR_LOCK_PROBE" ]]; then
  pass "人工操作持锁时 poll tick 直接跳过，不交错发送 tmux 按键"
else
  fail "monitor-op 锁未挡住并发 poll"
fi
flock -u "$MONITOR_HELD_FD"; exec {MONITOR_HELD_FD}>&-
if quota_monitor_op_run wait monitor_lock_probe >/dev/null 2>&1 \
   && [[ "$(cat "$MONITOR_LOCK_PROBE" 2>/dev/null)" == 'ran' ]]; then
  pass "锁释放后人工/单轮入口只执行一次完整 monitor 操作"
else
  fail "monitor-op 锁释放后没有正常执行入口"
fi
unset -f monitor_lock_probe

echo "── 陈旧帧自愈：稳定 stale 只允许受控重启一次，冷却期内不循环 ──"
STALE_RECOVERY_TRACE="$TMP/stale-recovery-trace"
: > "$STALE_RECOVERY_TRACE"
QUOTA_STATE="$TMP/stale-recovery-state.json"; QUOTA_CACHE_MTIME=""; echo '{}' > "$QUOTA_STATE"
_stub_save quota_monitor_restart quota_monitor_refresh quota_log
quota_monitor_restart() { printf 'restart:%s:%s\n' "$1" "$2" >> "$STALE_RECOVERY_TRACE"; return 0; }
quota_monitor_refresh() { printf 'refresh:%s\n' "$1" >> "$STALE_RECOVERY_TRACE"; return 0; }
quota_log() { :; }
date() { [[ "$*" == '+%s' ]] && printf '10000\n' || command date "$@"; }
SAVED_STALE_COOLDOWN=${QUOTA_MONITOR_STALE_RESTART_COOLDOWN:-}
QUOTA_MONITOR_STALE_RESTART_COOLDOWN=1800
if declare -F quota_monitor_recover_stale_frame >/dev/null 2>&1 \
   && quota_monitor_recover_stale_frame scheduled 'target@x' 'uuid-target' 6 1 20000 30000 \
   && [[ "$(tr '\n' ' ' < "$STALE_RECOVERY_TRACE")" == \
         'restart:target@x:uuid-target refresh:stale_recovery ' ]] \
   && [[ "$(quota_state_get '.monitor_recovery.last_restart_ts' 0)" == '10000' ]]; then
  pass "稳定 stale 帧先持久化冷却，再原 pane 重启并只追加一次 fresh /usage"
else
  fail "stale 帧没有进入受控单次自愈：$(tr '\n' ' ' < "$STALE_RECOVERY_TRACE")"
fi
: > "$STALE_RECOVERY_TRACE"
if declare -F quota_monitor_recover_stale_frame >/dev/null 2>&1 \
   && ! quota_monitor_recover_stale_frame scheduled 'target@x' 'uuid-target' 6 1 20000 30000 \
   && [[ ! -s "$STALE_RECOVERY_TRACE" ]] \
   && ! quota_monitor_recover_stale_frame stale_recovery 'target@x' 'uuid-target' 6 1 20000 30000; then
  pass "30 分钟冷却与 stale_recovery 模式共同阻断递归重启"
else
  fail "stale 自愈能在同一事故里循环重启：$(tr '\n' ' ' < "$STALE_RECOVERY_TRACE")"
fi
[[ -n "$SAVED_STALE_COOLDOWN" ]] && QUOTA_MONITOR_STALE_RESTART_COOLDOWN=$SAVED_STALE_COOLDOWN || unset QUOTA_MONITOR_STALE_RESTART_COOLDOWN
unset -f date
_stub_restore quota_monitor_restart quota_monitor_refresh quota_log

}

# ── thresholds, cadence, panel sampling / 阈值、节奏、面板采样 ──
run_cadence_tests() {
# ⚠️ Upstream this variable was set by a neighbouring case and simply inherited here.
#    That kind of implicit coupling between cases survives only as long as every
#    neighbour is migrated, and it fails as a **fatal** `unbound variable` under
#    `set -u` — which is loud, but only at the case that inherits, not at the one that
#    was dropped. Set it locally instead.
# ⚠️ 上游这个变量由相邻用例设好、这里直接继承。这种用例之间的隐式耦合，只在「每个邻居
#    都被迁移」时成立；一旦某个邻居没搬，它在 set -u 下是**致命**的未绑定变量——响是响，
#    但响在继承方，不响在被丢掉的那一方。改成本地取值。
SCHED_NOW=$(date +%s)
echo "── 两个窗口各自的阈值（五小时 90 / 周 99）──"
# The two lines move in OPPOSITE directions, and that is deliberate. The five-hour and the
# weekly window differ by an order of magnitude in burn rate (five-hour measured peak
# ~1.3%/min, weekly ~0.2%/min) AND by an order of magnitude in unit value: at the measured
# conversion constant of 0.120, **one weekly point is worth about 8.3 five-hour points**.
# So leave MORE headroom on the five-hour line (4 points is what a comfortable switch
# needs) and as LITTLE as possible on the weekly one (every point left early throws away
# 8.3 five-hour points of capacity).
# 五小时线与周线方向相反，是有意的。两者不只烧速差一个数量级（五小时实测峰值
# 1.3%/分钟，周 ~0.2%/分钟），单位价值也差一个数量级——按实测换算常数 0.120，
# **1 个周额度点 ≈ 8.3 个五小时点**。所以五小时要多留（留 4 点才够从容切号），
# 周额度要尽量少留（每早 1 点就扔掉 8.3 个五小时点的产能）。
# ⚠️ Upstream pinned a THIRD number here: an "accept line" strictly BELOW the switch line
#    (five 89 / week 99). Its reason for existing is anti-flapping -- accept a candidate
#    that sits exactly on the line and the next round switches away from it again.
#    🔴 This repo does not have that line: the switching half was rewritten, and
#    quota_switch_pick uses the same QUOTA_SWITCH_PCT_* as both the leave line and the
#    accept line. ⇒ The anti-flap margin goes from "at least 2 points" to "exactly 1":
#    a candidate at five=89 is accepted, and it is 1 point away from 90.
#    This was not lost in migration -- it is a pre-existing difference of the rewritten
#    switching half. It is **measured and written down here** rather than being allowed to
#    disappear as "upstream had an assertion and this repo does not".
# ⚠️ 上游这里还钉住第三个数：一条**严格低于**切换线的「接受线」（five 89 / week 99），
#    存在的理由是防来回切——接纳一个恰好在线上的候选，下一轮又把它切走。
#    🔴 本仓没有这条线：切号那一半是重写的，quota_switch_pick 用同一个
#    QUOTA_SWITCH_PCT_* 既当切走线又当接纳线。⇒ 防抖余量从「至少 2 点」变成
#    「恰好 1 点」：一个 five=89 的候选会被接纳，而它离 90 只差 1 点。
#    这不是迁移时丢的，是切号那一半重写时的既有差异；这里把它**测出来并写下来**，
#    而不是让它以「上游有一条断言、本仓没有」的形式消失。
if [[ "$QUOTA_SWITCH_PCT_FIVE" == "90" && "$QUOTA_SWITCH_PCT_WEEK" == "99" ]]; then
  pass "阈值配置：五小时切换线 90 / 周切换线 99"
else
  fail "阈值配置错误（five=$QUOTA_SWITCH_PCT_FIVE week=$QUOTA_SWITCH_PCT_WEEK）"
fi
# Pin the fact "accept line == switch line" as an assertion: a candidate exactly 1 point
# below is accepted, one exactly on the line is not.
# 把「接纳线 = 切换线」这个事实钉成断言：恰好差 1 点的候选会被接纳，等于线上的不会。
QUOTA_STATE="$TMP/accept-line-state.json"
cat > "$QUOTA_STATE" <<JSON
{"account":"cur@x","accounts":{
  "cur@x":{"five":95,"week":10},
  "edge@x":{"five":$(( QUOTA_SWITCH_PCT_FIVE - 1 )),"week":10},
  "over@x":{"five":$QUOTA_SWITCH_PCT_FIVE,"week":10}}}
JSON
picked=$(quota_switch_pick "cur@x" || echo "")
if [[ "$picked" == "edge@x" ]]; then
  pass "接纳线 = 切换线：five=$(( QUOTA_SWITCH_PCT_FIVE - 1 )) 被接纳，防抖余量只有 1 点（与上游的两点不同，已记）"
else
  fail "候选接纳边界不是「切换线减一」（picked=${picked:-none}）"
fi
cat > "$QUOTA_STATE" <<JSON
{"account":"cur@x","accounts":{
  "cur@x":{"five":95,"week":10},
  "over@x":{"five":$QUOTA_SWITCH_PCT_FIVE,"week":10}}}
JSON
if picked2=$(quota_switch_pick "cur@x"); then
  fail "正好在切换线上的候选被接纳了（picked=$picked2），那会当场再切走"
else
  pass "正控：候选恰好在切换线上时不被接纳，上一条不是恒真"
fi
# A weak-evidence banner has to be cross-checked against the percentages, which makes this
# the right place to verify that the two windows are compared independently of each other.
# 弱证据横幅要拿百分比交叉验证，正好用它验两个窗口是各比各的
mk_json() {  # $1=five $2=week
  export QUOTA_CLAUDE_JSON="$TMP/thr.json"
  cat > "$QUOTA_CLAUDE_JSON" <<JSON
{"oauthAccount":{"emailAddress":"t@x"},
 "cachedUsageUtilization":{"fetchedAtMs":$(( $(date +%s) * 1000 )),"accountUuid":"u",
  "utilization":{"five_hour":{"utilization":$1,"resets_at":null},
                 "seven_day":{"utilization":$2,"resets_at":null}}}}
JSON
}
mk_json 90 50
if quota_banner_confirmed "$(read_fx banner-weak.txt)" "$(date +%s)"; then
  pass "five=90% 触五小时阈值 90（周才 50% 也算数）"
else
  fail "five=90% 没触发五小时阈值 90"
fi
# ⚠️ When the five-hour line dropped to 90, the `five` value used here had to drop with
#    it: 90 used to mean "not at the line yet", and now 90 IS the line -- leave it and the
#    case silently tests the opposite of what it says.
# ⚠️ 五小时线降到 90 后，这里的 five 取值必须跟着降：原来用 90 表示「还没到线」，
#    现在 90 本身就是线上，这条会变成测反了。
mk_json 85 97
if quota_banner_confirmed "$(read_fx banner-weak.txt)" "$(date +%s)"; then
  fail "five=85%/week=97% 都不到各自阈值（90/99），不该触发"
else
  pass "five=85%/week=97% 两边都不到各自阈值 → 不触发"
fi
mk_json 85 98
if quota_banner_confirmed "$(read_fx banner-weak.txt)" "$(date +%s)"; then
  fail "week=98% 不该触发（周阈值已从 98 上调到 99）"
else
  pass "week=98% 不触发（边界：99 才触发，98 差一点）"
fi

echo "── /usage 网络频率：按更紧张窗口的剩余额度走 60/300/600 秒 ──"
if declare -F quota_usage_interval_for_values >/dev/null 2>&1 \
   && [[ "$(quota_usage_interval_for_values 10 20)" == "600" ]] \
   && [[ "$(quota_usage_interval_for_values 50 20)" == "300" ]] \
   && [[ "$(quota_usage_interval_for_values 79 20)" == "300" ]] \
   && [[ "$(quota_usage_interval_for_values 80 20)" == "60" ]] \
   && [[ "$(quota_usage_interval_for_values 20 94)" == "60" ]] \
   && [[ "$(quota_usage_interval_for_values nope 20)" == "60" ]]; then
  pass "剩余 >50%=600s、21–50%=300s、≤20%=60s；任一窗口紧张即收紧，未知 fail-safe 到 60s"
else
  fail "/usage 频率分档缺失或没有按两个窗口中更紧张的一维计算"
fi
if declare -F quota_usage_backoff_interval >/dev/null 2>&1 \
   && [[ "$(quota_usage_backoff_interval 60)" == "300" ]] \
   && [[ "$(quota_usage_backoff_interval 300)" == "600" ]] \
   && [[ "$(quota_usage_backoff_interval 600)" == "600" ]]; then
  pass "高频请求不可信/受限后按 60→300→600 退避，600s 封顶"
else
  fail "/usage 失败退避不是 60→300→600"
fi

echo "── /usage 面板可信度：刷新中、限流、last-known 与刷新失败整帧拒绝 ──"
PANEL_OK=$'Current session\n  12% used\n  Resets 5:00pm (Asia/Shanghai)\nCurrent week (all models)\n  34% used\n  Resets Aug 20, 5:00pm (Asia/Shanghai)'
PANEL_DETAIL=$'   Settings  Status   Config   Usage   Stats\n\n   What is contributing to your limits usage?\n   Last 24h · these are independent characteristics of your usage\n   88% of your usage was at >150k context'
if declare -F quota_panel_frame_status >/dev/null 2>&1 \
   && [[ "$(quota_panel_frame_status "$PANEL_OK")" == "clean" ]] \
   && [[ "$(quota_panel_frame_status "$PANEL_OK\nRefreshing…")" == "refreshing" ]] \
   && [[ "$(quota_panel_frame_status "$PANEL_OK\nUsage endpoint is rate limited. Press r to retry")" == "rate_limited" ]] \
   && [[ "$(quota_panel_frame_status "$PANEL_OK\nShowing last-known usage")" == "last_known" ]] \
   && [[ "$(quota_panel_frame_status "$PANEL_OK\nCould not refresh usage data")" == "refresh_failed" ]]; then
  pass "只有无污染的完整面板为 clean；带旧百分比的错误/刷新帧也不会进入决策"
else
  fail "/usage 面板缺少整帧可信度闸，可能把错误页上的旧百分比当实时值"
fi
if [[ "$(quota_panel_frame_status "$PANEL_DETAIL")" == "panel_detail" ]]; then
  pass "额度区块被归因分析滚出可见区时仍识别为 Usage 面板，不会提前触网重开"
else
  fail "常驻 Usage 页的归因详情被误判为面板关闭，会绕过 next_due 提前重发 /usage"
fi

echo "── 流速自适应：涨得快就多看几眼，但只收紧不放宽 ──"
# Hit live: the panel read 77%, and 5 minutes 13 seconds later it read 100%. At 77% the
# level-based tier is 300 seconds, while climbing from 77% to the then-94% switch line
# takes only 3.9 minutes -- **the polling interval was longer than the time-to-line, so
# missing it was certain, not unlucky**. The switch therefore happened at 100%, six
# sessions had already hit the wall before it, and preventive switching had degraded into
# after-the-fact recovery.
# Upstream stubbed a banner-pressure source here, because the rate tier and the
# "banner on screen" speed-up source shared one exit. This repo has no such source (it
# read the screen archives of every session in that environment, which was not extracted),
# so quota_usage_interval_adaptive has only the rate input left and no stub is needed --
# which also means **this group now covers ALL speed-up sources rather than a quarter of
# them**.
# 实撞：面板 77% → 5 分 13 秒后 100%。77% 按水位是 300 秒档，而从 77% 涨到当时的
# 切换线 94% 只要 3.9 分钟——**间隔比到线时间还长，漏过是必然不是运气**。结果切号发生在
# 100%，6 个会话在切号前就撞了墙，预防性切号退化成事后补救。
# 上游这里给横幅压力源打了桩，因为流速档与「屏上横幅」提速源共用一个出口。
# 本仓没有那个提速源（它读的是那套环境里全部会话的屏幕留档，未抽取），
# quota_usage_interval_adaptive 只剩流速这一条，所以不需要打桩——但也就意味着**这一组
# 现在覆盖的是全部提速源，而不是四分之一**。

RATE_FAIL=0
_rate() {  # _rate <期望> <说明> <five> <week> <prev_five> <prev_week> <prev_ts> <now> <prev_email> <cur_email>
  local want="$1" label="$2"; shift 2
  local got; got=$(quota_usage_interval_adaptive "$@")
  [[ "$got" == "$want" ]] && return 0
  printf '     %-34s 期望 %s 实际 %s\n' "$label" "$want" "$got"; RATE_FAIL=$((RATE_FAIL+1))
}
# Real numbers: previous five=0% (t=1000), this one five=77% (t=1620).
# ⚠️ After the switch line dropped from 94 to 90, the same scenario computes
#    (90-77)*620/77/2 ≈ 52s, which is under the floor, so the result is 60 -- the combined
#    effect of both changes: poll more often AND a lower line, margin from two directions.
#    (Under the old 94 line it was 68s; that number is kept here for comparison.)
# 真实数字：上次 five=0%（t=1000），这次 five=77%（t=1620）。
# ⚠️ 切换线从 94 降到 90 之后，同一场景算出来是 (90-77)*620/77/2≈52s，
#    低于地板价，所以结果是 60 —— 两项改动叠加的效果：查得更勤 + 线更低，双重余量。
#    （按旧的 94 线算是 68s，这个数留在注释里做对照。）
_rate 60  "实撞那次：300s → 60s（撞地板）" 77 47 0  39 1000 1620 a@x a@x
# One more that does not hit the floor, to exercise the rate formula on its own:
# +30 points in 600s -> 400s still to reach the 90 line -> take half.
# 再来一条不撞地板的，单独验流速算式本身：600s 内涨 30 点 → 到 90 线还需 400s，取一半
_rate 200 "中速上涨：300s → 200s（未撞地板）" 70 20 40 15 1000 1600 a@x a@x
# Tighten only, never loosen: the level tier is always the upper bound.
# 只收紧不放宽：水位档永远是上界
_rate 300 "慢涨不收紧（水位档 300 封顶）" 50 20 40 19 1000 1600 a@x a@x
# No rate across accounts: old account 100% -> new account 0% computes as negative.
# 跨账号不能算流速：旧账号 100% → 新账号 0%，算出来是负的
_rate 300 "跨账号（切号那轮）不算流速"   0  51 100 49 1000 1620 old@x new@x
# A percentage going down is a window reset, not a rate.
# 百分比掉下来是窗口重置，不是流速
_rate 600 "窗口重置导致下降，不当流速"   5  49 100 49 1000 1620 a@x a@x
# No previous reading.
# 没有上一次读数
_rate 300 "无 prev 时回落到水位档"       77 47 "" "" "" 1620 a@x a@x
# Floor: however fast it climbs, never below 60s.
# 地板价：再快也不低于 60s
_rate 60  "极快上涨仍不低于地板 60s"     93 10 0  5  1000 1010 a@x a@x
if (( RATE_FAIL == 0 )); then
  pass "流速自适应六种情形全部正确（含跨账号/窗口重置两种不该收紧的）"
else
  fail "$RATE_FAIL 种情形算错"
fi

# ⚠️ The switch has to actually switch it off: an env escape hatch means falling back to
#    the old behaviour when something goes wrong does not require a code change.
# ⚠️ 开关必须真能关掉：留一个 env 后门，出问题时不用改代码就能退回旧行为。
QUOTA_RATE_ADAPTIVE=0
RATE_OFF=$(quota_usage_interval_adaptive 77 47 0 39 1000 1620 a@x a@x)
QUOTA_RATE_ADAPTIVE=1
if [[ "$RATE_OFF" == "300" ]]; then
  pass "QUOTA_RATE_ADAPTIVE=0 时退回纯水位档（有可回退的后门）"
else
  fail "关掉开关后行为没退回旧逻辑（得到 $RATE_OFF）"
fi

echo "── 0% inactive：无 Resets 可写 null，连续 TAB 不得把周 reset 错位 ──"
PANEL_INACTIVE=$'Current session\n  0% used\n\nCurrent week (all models)\n  34% used\n  Resets Aug 20, 5:00pm (Asia/Shanghai)'
if inactive_row=$(quota_panel_parse "$PANEL_INACTIVE") \
   && [[ "$(quota_panel_field "$inactive_row" 1)" == "0" ]] \
   && [[ -z "$(quota_panel_field "$inactive_row" 3)" ]] \
   && [[ "$(quota_panel_field "$inactive_row" 4)" == *'Aug 20'* ]] \
   && [[ "$(quota_window_reset_for_write 0 '' "$SCHED_NOW" "$QUOTA_SESSION_WINDOW_HORIZON")" == "null" ]] \
   && ! quota_window_reset_for_write 1 '' "$SCHED_NOW" "$QUOTA_SESSION_WINDOW_HORIZON" >/dev/null 2>&1; then
  pass "0%/无 reset 明确记为 inactive(null)；非 0 缺 reset 仍拒绝，四字段不串列"
else
  fail "0% 无 reset 被误拒或 TAB 空列让周 reset 错归到五小时窗口"
fi

# ── 面板观测落盘：默认存 SHA + 结构化字段，整屏原文只在显式打开时才存 ──
# WHY / 为什么是这个默认
# --------------------------------------------------------------------------
# The sampler reads with `tmux capture-pane -p`, which returns the WHOLE visible pane.
# Storing that verbatim by default means whatever the monitored session happens to show
# lands on disk every 10 seconds and stays a week. Here that session only ever runs
# `/usage` — but that is how WE run it, and this file is the thing a stranger installs.
# ⇒ default: sha256 + parsed fields; raw text behind QUOTA_PANEL_TEXT_CAPTURE.
# 采样用 `tmux capture-pane -p`，返回的是**整个可见 pane**。默认原样落盘，意味着被监控
# 会话上碰巧显示的任何东西每 10 秒进一次磁盘、留一周。在这里那个会话只跑 `/usage`——
# 但那是**我们**的用法，而这份代码是陌生人装到自己机器上的东西。
#
# 🔴 两个方向都要，只做一个都不算数：
#    默认关 → 原文不许出现；开关打开 → 原文必须原样回来。只测前者，一个「永远不存」的
#    实现也全绿，而那不是这里要的东西——要的是「默认安全」，不是「功能被删掉」。
# 🔴 BOTH directions, either alone is worthless: default off -> the text must not appear;
#    switch on -> the text must come back verbatim. Testing only the first is also passed
#    by an implementation that can never store it, which is not what is wanted here:
#    the goal is a safe DEFAULT, not a removed feature.
if [[ -n "$QS_TEST_PANEL_CAPTURE_PRESET" ]]; then
  fail "环境里预置了 QUOTA_PANEL_TEXT_CAPTURE ⇒ 下面这组测的不是 lib/config.sh 里的默认值"
fi

# ⭐ A canary line that parses into NOTHING, so it cannot reach any structured field.
#    `has("panel_text")` answers "is that one key absent"; the canary answers the wider
#    question: "did any of this screen reach any file, or stdout/stderr, by any route
#    inside this sandbox".
# ⭐ 金丝雀行解析不出任何字段，所以它进不了任何结构化字段这条路。
#    `has("panel_text")` 答的是「那一个键在不在」；金丝雀答的是更宽的一问：
#    「这一屏有没有**在本沙箱内**，经**任何**路径进到**任何文件**或 stdout/stderr」。
#
# 🩸 2026-08-31 m5b review 实撞：这条断言的**第一版**只 grep `$QUOTA_PANEL_OBSERVATIONS`
#    **一个文件**，而注释写的是「任何口子」。reviewer 在副本里注入了一条真实的第二出口
#    （`printf '%s\n' "$frame" >> "$QUOTA_LOG"`）——**整屏原文每 10 秒进一次 `quota.log`，
#    而整套 `--fast` 仍然 PASS 106 / FAIL 0，这条断言仍然绿。**
#    ⭐ 教训不是「话说大了」，是**判据的射程与它的自我描述必须同时可核**；
#      两者一旦分叉，绿色读起来仍然像是那句大话被验过了。
#    ⇒ 现在把判据做到配得上那句话（AGENT 裁定选「扩断言」而非「缩声称」：
#      「任何口子都不漏」这句声称本身是有价值的那个，缩掉它等于把判据降级成
#      「某个文件里没有」）。消融 `frame-second-sink` 把那条反例固化成可复跑的一条。
#
# ⚠️ **搜的是 `$TMP`（整个测试沙箱），不是 `$QS_STATE_DIR`** —— 这不是随手放宽。
#    本套件把若干 `QUOTA_*` 路径**直接绑到 `$TMP` 下而不是 `$QS_STATE_DIR` 下**
#    （`QUOTA_LOG="$TMP/quota.log"` 就是其一）⇒ **只搜 `$QS_STATE_DIR` 恰好搜不到
#    reviewer 那条反例**，也就是搜不到这条判据为之而写的那个东西。
#    （生产环境里 `quota.log` 确实在 `$QS_STATE_DIR` 下；分叉只存在于测试夹具里，
#      而判据跑在夹具里。）
# ⚠️ Searched root is `$TMP` (the whole test sandbox), not `$QS_STATE_DIR`: this suite
#    rebinds several QUOTA_* paths directly under `$TMP` (`QUOTA_LOG="$TMP/quota.log"` is
#    one), so searching only `$QS_STATE_DIR` would have missed the very counterexample
#    this assertion was widened for.
#
# ⚠️ 扩完之后**仍然拦不住**的口子，逐条写在这里，别让声称又跑到射程前面：
#    ① **编码后落盘** —— `grep -F` 只认逐字原文，base64 / hex / 转义变形一律漏。
#    ② **落到 `$TMP` 之外** —— 判据只搜测试沙箱。⚠️ 这一条**很实**：`lib/reading.sh:871-872`
#       与 `account-probe:186,310` 真的会写 `${TMPDIR:-/tmp}`（那几处写的是 OAuth 响应，
#       不是帧；但「沙箱外无人看」这个结构性缺口是真的）。
#    ③ **上命令行** —— 由 `_frame_in_argv` 那条静态判据管，而它**按变量名**认，改个名就漏。
#    ④ **不发生在这一次调用里的泄漏** —— 只观察这一次调用之后的落点，
#       后台写入、延迟 flush、下一拍才写出去的东西，这里看不见。
# ⚠️ Still NOT covered after the widening, stated rather than implied: ① encoded copies
#    (`grep -F` is literal only); ② anything written outside `$TMP` — real, see
#    `lib/reading.sh:871-872` and `account-probe:186,310` writing `${TMPDIR:-/tmp}`;
#    ③ command lines, covered by `_frame_in_argv`, which recognises BY VARIABLE NAME;
#    ④ leaks that do not happen during this one call (background or deferred writes).
#
# ⚠️ 两个方向用**两个不同的金丝雀串**：默认方向要在**整个 `$TMP`** 里搜「一个都不许有」，
#    而 opt-in 方向**故意**把原文写进 `$TMP` 下另一个文件 ⇒ 共用一个串会让默认方向
#    在用例顺序改变时被自己的 opt-in 产物打红（一个纯粹由脚手架造出来的假红）。
# ⚠️ Two DIFFERENT canaries on purpose: the default direction searches all of `$TMP` for
#    zero occurrences, while the opt-in direction deliberately writes the text into
#    another file under `$TMP`. Sharing one string would let a re-ordering of the cases
#    turn the default assertion red for a purely scaffolding reason.
PANEL_CANARY='CANARY-default-whatever-else-was-on-this-screen-0d5f'
PANEL_CANARY_OPTIN='CANARY-optin-whatever-else-was-on-this-screen-7b3e'
PANEL_WITH_CANARY="$PANEL_OK"$'\n'"$PANEL_CANARY"
PANEL_WITH_CANARY_OPTIN="$PANEL_OK"$'\n'"$PANEL_CANARY_OPTIN"
rm -f "$QUOTA_PANEL_OBSERVATIONS"
# stdout/stderr 一并收走：写到文件是一种出口，打印出来是另一种，两种都要看。
# Capture stdout+stderr too: printing it out is a second kind of exit, not a lesser one.
_obs_io=$(quota_panel_log_observation "$SCHED_NOW" 'sched@x' 'uuid-s' local_sample clean "$PANEL_WITH_CANARY" 2>&1)
# 先落到变量再判，不写成 `… | grep -q`：本文件开着 pipefail，命中会被报成没命中。
# Assign first, never `… | grep -q`: pipefail would report a match as no match.
_obs_leaks=$(grep -rlF -- "$PANEL_CANARY" "$TMP" 2>/dev/null || true)
if jq -e '
     .source=="usage_panel_screen" and .mode=="local_sample" and .status=="clean"
     and .account.email=="sched@x" and .cadence.local_sample_seconds==10
     and .parsed.five_hour==12 and .parsed.seven_day==34
     and (.panel_sha256|length)==64
     and .panel_text_captured==false and (has("panel_text")|not)' \
     "$QUOTA_PANEL_OBSERVATIONS" >/dev/null 2>&1 \
   && [[ -z "$_obs_leaks" ]] \
   && [[ "$_obs_io" != *"$PANEL_CANARY"* ]]; then
  pass "默认落盘：结构化字段齐全，且整个沙箱里没有任何文件、stdout/stderr 也没有出现过屏幕原文"
else
  fail "默认就把可见屏原文送了出去（文件落点：${_obs_leaks:-无}；stdout/stderr 命中：$( [[ "$_obs_io" == *"$PANEL_CANARY"* ]] && echo 有 || echo 无 )）——装这套的人屏幕上有什么就被送到哪"
fi

if (
  QUOTA_PANEL_TEXT_CAPTURE=1
  QUOTA_PANEL_OBSERVATIONS="$TMP/quota-panel-observations.optin.jsonl"
  QUOTA_PANEL_PRUNE_STAMP="$TMP/quota-panel-observations.optin.prune-ts"
  rm -f "$QUOTA_PANEL_OBSERVATIONS"
  quota_panel_log_observation "$SCHED_NOW" 'sched@x' 'uuid-s' local_sample clean "$PANEL_WITH_CANARY_OPTIN"
  jq -e --arg raw "$PANEL_WITH_CANARY_OPTIN" '
     .panel_text==$raw and .panel_text_captured==true
     and (.panel_sha256|length)==64' "$QUOTA_PANEL_OBSERVATIONS" >/dev/null 2>&1
); then
  pass "QUOTA_PANEL_TEXT_CAPTURE=1 时原文原样回来（调试开关是真开关，不是摆设）"
else
  fail "打开 QUOTA_PANEL_TEXT_CAPTURE 之后拿不回可见屏原文：这个逃生口是坏的"
fi

echo "── 原始整屏日志：滚动保留七天，低频清理且不误删坏行 ──"
RETENTION_NOW=2000000
RETENTION_CUTOFF=$(( RETENTION_NOW - 604800 ))
cat > "$QUOTA_PANEL_OBSERVATIONS" <<JSON
{"schema":1,"source":"usage_panel_screen","observed_at":$(( RETENTION_CUTOFF - 1 )),"tag":"expired"}
{"schema":1,"source":"usage_panel_screen","observed_at":$RETENTION_CUTOFF,"tag":"boundary"}
{"schema":1,"source":"usage_panel_screen","observed_at":$(( RETENTION_NOW - 1 )),"tag":"recent"}
{"schema":2,"source":"usage_panel_screen","observed_at":$(( RETENTION_CUTOFF - 2 )),"tag":"unknown-schema"}
{"schema":1,"source":"usage_panel_screen","observed_at":"$(( RETENTION_CUTOFF - 3 ))","tag":"wrong-ts-type"}
not-json-preserve-me
JSON
rm -f "$QUOTA_PANEL_PRUNE_STAMP"
quota_panel_log_observation "$RETENTION_NOW" 'retention@x' 'uuid-r' local_sample clean "$PANEL_OK"
if [[ "${QUOTA_PANEL_RETENTION_SEC:-}" == "604800" \
      && "${QUOTA_PANEL_PRUNE_INTERVAL:-}" == "86400" ]] \
   && ! grep -q '"tag":"expired"' "$QUOTA_PANEL_OBSERVATIONS" \
   && grep -q '"tag":"boundary"' "$QUOTA_PANEL_OBSERVATIONS" \
   && grep -q '"tag":"recent"' "$QUOTA_PANEL_OBSERVATIONS" \
   && grep -q '"tag":"unknown-schema"' "$QUOTA_PANEL_OBSERVATIONS" \
   && grep -q '"tag":"wrong-ts-type"' "$QUOTA_PANEL_OBSERVATIONS" \
   && grep -q '^not-json-preserve-me$' "$QUOTA_PANEL_OBSERVATIONS" \
   && jq -Rse --argjson now "$RETENTION_NOW" '
        split("\n") | map(try fromjson catch null)
        | any(.observed_at==$now and .account.email=="retention@x")' \
        "$QUOTA_PANEL_OBSERVATIONS" >/dev/null 2>&1 \
   && [[ "$(stat -c %a "$QUOTA_PANEL_OBSERVATIONS")" == "600" ]] \
   && [[ "$(cat "$QUOTA_PANEL_PRUNE_STAMP" 2>/dev/null)" == "$RETENTION_NOW" ]]; then
  pass "首次到期清理只删除七天前的有效帧，边界/坏行/本轮新帧均保留"
else
  fail "整屏日志没有落实七天保留，或清理误删了边界/坏行/新帧"
fi

printf '{"schema":1,"source":"usage_panel_screen","observed_at":%s,"tag":"throttled-old"}\n' \
  "$(( RETENTION_CUTOFF - 2 ))" >> "$QUOTA_PANEL_OBSERVATIONS"
quota_panel_log_observation "$(( RETENTION_NOW + QUOTA_PANEL_PRUNE_INTERVAL - 1 ))" \
  'retention@x' 'uuid-r' local_sample clean "$PANEL_OK"
if grep -q '"tag":"throttled-old"' "$QUOTA_PANEL_OBSERVATIONS" \
   && [[ "$(cat "$QUOTA_PANEL_PRUNE_STAMP" 2>/dev/null)" == "$RETENTION_NOW" ]]; then
  pass "每日清理周期内只追加不重扫整份大日志"
else
  fail "整屏日志清理没有按每日周期节流"
fi
quota_panel_log_observation "$(( RETENTION_NOW + QUOTA_PANEL_PRUNE_INTERVAL ))" \
  'retention@x' 'uuid-r' local_sample clean "$PANEL_OK"
if ! grep -q '"tag":"throttled-old"' "$QUOTA_PANEL_OBSERVATIONS" \
   && [[ "$(cat "$QUOTA_PANEL_PRUNE_STAMP" 2>/dev/null)" == "$(( RETENTION_NOW + QUOTA_PANEL_PRUNE_INTERVAL ))" ]]; then
  pass "清理间隔到期后再次滚动删除过期帧"
else
  fail "整屏日志到期后没有再次执行滚动清理"
fi

if (
  QUOTA_PANEL_OBSERVATIONS="$TMP/quota-panel-observations.atomic.jsonl"
  QUOTA_PANEL_PRUNE_STAMP="$TMP/quota-panel-observations.atomic.prune-ts"
  printf '%s\n' \
    "{\"schema\":1,\"source\":\"usage_panel_screen\",\"observed_at\":$(( RETENTION_CUTOFF - 1 )),\"tag\":\"must-survive\"}" \
    "{\"schema\":1,\"source\":\"usage_panel_screen\",\"observed_at\":$RETENTION_NOW,\"tag\":\"recent\"}" \
    > "$QUOTA_PANEL_OBSERVATIONS"
  before=$(sha256sum "$QUOTA_PANEL_OBSERVATIONS" | awk '{print $1}')
  mv() {
    local dest="${@: -1}"
    [[ "$dest" == "$QUOTA_PANEL_OBSERVATIONS" ]] && return 1
    command mv "$@"
  }
  declare -F quota_panel_observations_prune_if_due >/dev/null \
    && ! quota_panel_observations_prune_if_due "$RETENTION_NOW" \
    && [[ "$(sha256sum "$QUOTA_PANEL_OBSERVATIONS" | awk '{print $1}')" == "$before" ]] \
    && ! compgen -G "${QUOTA_PANEL_OBSERVATIONS}.prune.*" >/dev/null
); then
  pass "整屏日志 atomic rename 失败时原文件不变且临时文件已清理"
else
  fail "整屏日志清理失败破坏原文件或遗留临时文件"
fi
mk_json 90 99
if quota_banner_confirmed "$(read_fx banner-weak.txt)" "$(date +%s)"; then
  pass "week=99% 触周阈值 99"
else
  fail "week=99% 没触发周阈值"
fi
unset QUOTA_CLAUDE_JSON; unset -f mk_json

echo "── 陈旧帧：窗口身份优先，不能只看单调性 ──"
# Both real sequences from this incident are **not** regressions -- they are the previous
# window's high value coming back:
# 事故的两条真实序列都**不是回退**，而是旧窗口的高值回来了：
#   accountA   19:49:53 five=97%(旧窗口) → 19:50:13 five=0%(真 reset) → 19:50:31 five=97%(旧窗口)
#   accountB 21:10:09 five=0%(真 reset) → 21:10:28 five=99%(旧窗口)
# 97 > 0 is an INCREASE, so a pure monotonicity test stops neither of them. Both caused a
# wrong switch; the second pushed the "wait until" time 24 hours into the future.
# ⭐ 每一步都合理，合起来错得离谱，且全程无报错。
# ⭐ Every step is reasonable, the combination is badly wrong, and nothing errors.
# 97>0 是上涨，纯单调性判据一条都拦不住；两次都因此错切账号，第二次把 waiting 推到 24h 后。
QUOTA_STATE="$TMP/frame-state.json"; QUOTA_CACHE_MTIME=""
NOW_T=$(date +%s)
SR_NEW=$(( NOW_T + 17000 ))    # 新窗口：reset 还在未来
SR_OLD=$(( NOW_T - 600 ))      # 旧窗口：reset 已过（视界钳制会解析成这种过去 epoch）
WR=$(( NOW_T + 100000 ))
mk_last() {  # $1=account $2=five $3=week $4=five_reset $5=week_reset
  cat > "$QUOTA_STATE" <<JSON
{"account":"$1","five_hour":$2,"seven_day":$3,"five_reset_ts":$4,"week_reset_ts":$5}
JSON
}

# ── Incident sequence 1 / 事故序列 1：accountA 97 → 0 → 97 ──
mk_last "accountA@x" 0 11 "$SR_NEW" "$WR"          # 已确认：真 reset 后的 0%
if quota_frame_stale "accountA@x" 97 10 "$SR_OLD" "$WR"; then
  pass "accountA 97%(已过期窗口) 在 0%(新窗口) 之后回来 → 判陈旧（事故序列 1）"
else
  fail "没拦住事故序列 1——这正是 19:50:31 那次错切的原因"
fi
# ── Incident sequence 2 / 事故序列 2：accountB 0 → 99 ──
mk_last "accountB@x" 0 88 "$SR_NEW" "$WR"
if quota_frame_stale "accountB@x" 99 87 "$SR_OLD" "$WR"; then
  pass "accountB 99%(已过期窗口) 在 0% 之后回来 → 判陈旧（事故序列 2）"
else
  fail "没拦住事故序列 2"
fi
# ⚠️ Isolate the "window already expired" rule. Both sequences above ALSO trigger "older
# than last confirmed", so deleting the expiry rule leaves them green (destructive check
# measured: 0 cases went red). The scenario only it can save is **the first read of a new
# account right after a switch** -- there is no comparable history, so if the panel serves
# a cached frame from the previous window, a reset lying in the past is the only tell.
# ⭐ 一条判据「有没有被别的判据顺带盖住」，只能靠单独隔离它才看得出来。
# ⭐ Whether a predicate is merely being shadowed by another one is only visible if you
#   isolate it.
# ⚠️ 隔离「窗口已过期」这条规则：上面两条序列同时命中「比上次更旧」，所以即使删掉
# 过期规则也照样红不了（破坏性验证实测红 0 条）。真正只有它能救的场景是**切号后第一次
# 读新账号**——没有可比的历史读数，此时若面板给的是上一个窗口的缓存帧，只能靠 reset
# 落在过去来识别。
mk_last "someone-else@x" 50 50 "$SR_NEW" "$WR"
if quota_frame_stale "brandnew@x" 97 10 "$SR_OLD" "$WR"; then
  pass "无同账号历史时，仅凭 reset 已过去即判陈旧（切号后第一读的唯一防线）"
else
  fail "切号后第一读会收下已过期窗口的缓存帧"
fi

# ⚠️ The BASELINE itself can be bad. Hit live: state held a five_reset_ts written by older
# buggy code that was 14.5 hours away -- impossible for a five-hour window -- so the
# panel's **true value** was judged "an older window", every frame the new poller produced
# was rejected, and no reading could get in at all.
# Validate the baseline against the same physical fact first: beyond the 5h horizon, or
# already in the past => treat it as no baseline.
# ⚠️ 基准本身可能是坏的。活体实撞：state 里存着旧 buggy 代码写下的 five_reset_ts，
# 距今 14.5h——五小时窗口不可能这么远——于是面板的**真值**被判成「更旧的窗口」，
# 新 poller 每一帧都被拒、读数彻底进不来。
# 基准要用同一条物理事实先校验：超出 5h 视界或已过去 → 当没有基准。
BAD_SR=$(( NOW_T + 52200 ))     # 14.5 小时后——不可能是五小时窗口
mk_last "accountA@x" 0 10 "$BAD_SR" "$WR"
if quota_frame_stale "accountA@x" 20 14 "$(( NOW_T + 1800 ))" "$WR"; then
  fail "坏基准（$(date -d @$BAD_SR '+%m-%d %H:%M')）把真值判成陈旧 → 读数会彻底进不来"
else
  pass "基准超出 5h 视界 → 当没有基准，真值照常采信"
fi
mk_last "accountA@x" 0 10 "$(( NOW_T - 3600 ))" "$WR"
if quota_frame_stale "accountA@x" 20 14 "$(( NOW_T + 1800 ))" "$WR"; then
  fail "已过去的基准仍被用来比较"
else
  pass "基准已过去（窗口早结束）→ 当没有基准"
fi

# ⚠️ When the baseline expires, its PERCENTAGE is void along with its reset. Hit live:
# after accountA reset, state still held the old window's five=100 (whose reset had
# passed), and the new window's true 20% was rejected as "100 -> 20 went backwards" --
# the readings starved. Voiding only the baseline's reset while keeping its percentage for
# a monotonicity comparison lets a DEAD window keep vetoing a LIVE one.
# The frame's week is 25 (no regression) so this case exercises only "a dead baseline on
# the five-hour axis". The real 20/14 frame that day had its week go backwards too, and
# rejecting THAT one was correct -- what actually starved the readings was the five-hour
# axis of later frames such as 19/25.
# ⚠️ 基准过期时，百分比要跟 reset 一起作废。实撞：accountA 重置后 state 里还留着旧窗口的
# five=100（reset 已过），新窗口真值 20% 被「100→20 回退」拒掉，读数饿死——只作废基准的
# reset、留着它的百分比做单调性比较，等于让死窗口继续否决活窗口。
# 帧的 week 给 25（不回退）：这条用例只考「五小时维度的死基准」。当天真实的 20/14 帧
# 其实 week 也回退了，它被拒是对的——真正饿死读数的是后来 19/25 那类帧的 five 维度。
mk_last "accountA@x" 100 23 "$(( NOW_T - 300 ))" "$WR"     # 基准：reset 五分钟前已过
if quota_frame_stale "accountA@x" 20 25 "$(( NOW_T + 17000 ))" "$WR"; then
  fail "死窗口的 100% 否决了新窗口的真值 20%（当天 12:19 读数饿死那一幕）"
else
  pass "基准 reset 已过 → 其百分比一并作废，新窗口 20% 正常采信"
fi

# The monotonicity path still has to hold (the accountB 94->0 and accountC 21->7 groups
# from that day).
# 单调性那一路仍要保住（当天 accountB 94→0、accountC 21→7 那两组）
mk_last "accountB@x" 94 88 "$SR_NEW" "$WR"
if quota_frame_stale "accountB@x" 0 88 "$SR_NEW" "$WR"; then
  pass "同窗口内 94%→0% 回退 → 判陈旧"
else
  fail "没识别同窗口回退"
fi
mk_last "accountC@x" 21 95 "$SR_NEW" "$WR"
if quota_frame_stale "accountC@x" 7 94 "$SR_NEW" "$WR"; then
  pass "同窗口内 21%→7% 回退 → 判陈旧（当天 accountC 那一组）"
else
  fail "没识别 accountC 那组回退"
fi
# A legitimate drop to zero after a real reset must be let through, or the true value
# after every reset is rejected forever.
# 真 reset 后合法归零必须放行，否则永远拒绝重置后的真值
mk_last "accountB@x" 98 88 "$(( NOW_T + 60 ))" "$WR"
if quota_frame_stale "accountB@x" 0 88 "$SR_NEW" "$WR"; then
  fail "真 reset 后的合法归零被误判 → 会永远拒绝新窗口读数"
else
  pass "真 reset（窗口 reset 时刻前移到新的未来值）后归零 → 采信"
fi
# Different accounts are not comparable.
# 账号不同不可比
mk_last "accountB@x" 98 88 "$SR_NEW" "$WR"
if quota_frame_stale "other@x" 0 5 "$SR_NEW" "$WR"; then
  fail "不同账号之间不该比较"
else
  pass "账号不同 → 不适用（切号后第一读本就是另一账号的独立读数）"
fi
# No reset available AND a regression -> fail closed.
# reset 拿不到 + 回退 → fail closed
mk_last "accountB@x" 94 88 "$SR_NEW" "$WR"
if quota_frame_stale "accountB@x" 0 88 "" ""; then
  pass "reset 时刻不可得 + 回退 → fail closed 当陈旧帧"
else
  fail "reset 未知时应保守判陈旧"
fi
# A normal increase must be let through.
# 正常上涨必须放行
mk_last "accountB@x" 90 88 "$SR_NEW" "$WR"
if quota_frame_stale "accountB@x" 91 88 "$SR_NEW" "$WR"; then
  fail "正常上涨被误判 → 会拒绝一切真值"
else
  pass "同窗口内上涨 → 正常采信"
fi

echo "── reset 分钟抖动：同一窗口允许相差 5 分钟，不能颠倒新旧帧 ──"
# Hit live: one refresh alternated between accountD 62/35 @ 4:00/14:00 (cached) and
# 77/37 @ 3:59/13:59 (fresh). The two sources round the SAME reset to the minute 60s
# apart, so comparing epochs exactly would reject the real frame for being a minute early
# AND let the cache pose as a "new window" for being a minute late.
# Same-window resets from the server and the UI can differ by several minutes, so the
# tolerance is 5 minutes. A genuine window change jumps by about 5h or 7d, far beyond
# that; within the tolerance percentage monotonicity still applies, so a low cached value
# cannot slip in under cover of it.
# 活体：同一次刷新交替显示 accountD 62/35 @ 4:00/14:00（缓存）与 77/37 @ 3:59/13:59
# （新鲜）。两个来源对同一 reset 的分钟取整相差 60s；若精确比较 epoch，真帧会因 reset
# 早一分钟被拒，缓存又会因 reset 晚一分钟冒充「新窗口」。
# 服务端/UI 的同窗 reset 还可能相差几分钟，容差因此扩为 5 分钟。真正换窗会跳约 5h/7d，
# 远大于 5 分钟；容差内仍必须服从百分比单调性，不能让低值缓存借机混入。
if declare -F quota_reset_same_window >/dev/null 2>&1 \
   && quota_reset_same_window "$SR_NEW" "$((SR_NEW-300))" \
   && quota_reset_same_window "$WR" "$((WR+300))" \
   && ! quota_reset_same_window "$SR_NEW" "$((SR_NEW-301))"; then
  pass "reset 相差不超过 5 分钟归为同窗，超过容差仍区分窗口"
else
  fail "reset 同窗容差不是 5 分钟"
fi
mk_last "accountD@x" 66 36 "$SR_NEW" "$WR"
if quota_frame_stale "accountD@x" 77 37 "$((SR_NEW-240))" "$((WR-240))"; then
  fail "新鲜 77/37 因 reset 早 4 分钟被错拒"
else
  pass "同窗 reset 早 4 分钟但用量上涨 → 采信新鲜帧"
fi
mk_last "accountD@x" 77 37 "$((SR_NEW-240))" "$((WR-240))"
if quota_frame_stale "accountD@x" 62 35 "$SR_NEW" "$WR"; then
  pass "同窗 reset 晚 4 分钟但用量回退 → 仍判缓存陈旧"
else
  fail "62/35 缓存借 reset 晚 4 分钟冒充新窗口"
fi
mk_last "accountD@x" 66 36 "$SR_NEW" "$WR"
if quota_frame_stale "accountD@x" 99 99 "$((SR_NEW-301))" "$((WR-301))"; then
  pass "超过 5 分钟的更旧 reset 即使百分比更高也仍判陈旧"
else
  fail "reset 容差放得过宽，吞掉了真正更旧的窗口"
fi
if declare -F quota_panel_sample_better >/dev/null 2>&1 \
   && quota_panel_sample_better "$((SR_NEW-240))" 77 37 "$SR_NEW" 66 36 \
   && ! quota_panel_sample_better "$SR_NEW" 66 36 "$((SR_NEW-240))" 77 37 \
   && quota_panel_sample_better "$((SR_NEW+301))" 0 37 "$SR_NEW" 99 37 \
   && ! quota_panel_sample_better "$((SR_NEW-301))" 99 99 "$SR_NEW" 66 36; then
  pass "单轮交错采样始终选同窗高值，只有明确新窗口才允许归零"
else
  fail "单轮 best-frame 仍会被几分钟 reset 抖动颠倒"
fi
if quota_panel_sample_better "" 0 37 "$((NOW_T-1))" 99 37 "$WR" "$WR" \
   && ! quota_panel_sample_better "" 0 37 "$SR_NEW" 99 37 "$WR" "$WR" \
   && quota_panel_sample_better "$SR_NEW" 2 0 "$SR_NEW" 2 99 "" "$((NOW_T-1))" \
   && quota_panel_sample_better "$SR_NEW" 2 37 "" 0 37 "$WR" "$WR" \
   && ! quota_panel_sample_better "$((NOW_T-1))" 99 37 "" 0 37 "$WR" "$WR"; then
  pass "单轮选帧分别识别五小时/周窗口的 0% inactive；只在旧 reset 到期后允许无 reset 归零"
else
  fail "0%/无 reset 与旧高值交错时仍会选错窗口"
fi

echo "── reset 解析：五小时窗口的跨日回卷必须被钳制 ──"
# 事故的根因之一：19:50:31 那帧写 `Resets 7:50pm`，而 19:50 刚过去，裸解析 +86400 变成
# **明天 19:50**，比真帧的今天 00:50 还晚 → 「按 reset 比新旧」完全失效。
# ⚠️ LC_ALL=C is mandatory: `date`'s %P/%b FOLLOW THE LOCALE. Under a Chinese locale `%P`
#    prints a localised string instead of "pm", and feeding that to the parser produces an
#    input that can never occur in reality -- the client's panel is always English.
#    Without the lock these cases test the machine's locale rather than the production
#    logic, and the failure message reads as though the PARSER is broken, which points
#    whoever is debugging in the wrong direction.
# ⚠️ 必须锁 LC_ALL=C：date 的 %P/%b 是**跟随 locale** 的，本机中文环境下 `%P` 输出
#    「下午」而不是「pm」，喂给解析器就是一个现实中根本不会出现的字符串——
#    客户端面板永远是英文。不锁的话这几条用例测的不是生产逻辑，而是本机 locale，
#    且失败文案会显示成解析器坏了，把人引向错误方向。
NOWHM=$(LC_ALL=C TZ=CST-8 date '+%-I:%M%P')          # 取「刚刚过去」的那个时刻文案
PAST_LINE="Resets $(LC_ALL=C TZ=CST-8 date -d '-2 minutes' '+%-I:%M%P') (Asia/Shanghai)"
naive=$(quota_panel_reset_epoch "$PAST_LINE" || echo "")
clamped=$(quota_panel_reset_epoch "$PAST_LINE" "$QUOTA_SESSION_WINDOW_HORIZON" || echo "")
if [[ "$naive" =~ ^[0-9]+$ ]] && (( naive > NOW_T + 80000 )); then
  pass "不加视界时确实回卷到约 24h 后（复现原缺陷，got $(date -d "@$naive" '+%m-%d %H:%M')）"
else
  fail "没复现回卷（naive=$naive）"
fi
if [[ "$clamped" =~ ^[0-9]+$ ]] && (( clamped < NOW_T )); then
  pass "加 5h 视界后还原成已过去的时刻 → 调用方能看出窗口已过期"
else
  fail "视界钳制没生效（clamped=$clamped）"
fi
: "${NOWHM:-}"
unset -f mk_last

}

# ── the reading round and its write gates / 读数主轮与写入闸 ──
# ⚠️ Upstream this function was `quota_read_once`; here the reading half is
#    `quota_read_once` and the switching half hangs off the seam at its end. Every
#    call below is renamed accordingly. Stubs for functions that no longer exist
#    (`quota_reap_dead_sessions`, `quota_after_recovery` — session reaping and the
#    resume-delivery chain, neither extracted) are harmless no-ops and are kept so the
#    diff against the upstream case stays readable.
# ⚠️ 上游这个函数叫 quota_read_once；本仓读数那一半叫 quota_read_once，切号那一半挂在它
#    末尾的接缝上。下面的调用一律照此改名。对本仓已不存在的函数打的桩
#    （quota_reap_dead_sessions / quota_after_recovery——会话回收与复工投递链，两者都
#    未抽取）是无害空转，保留它们是为了与上游用例的 diff 仍然读得出来。
run_reading_round_tests() {
export QUOTA_CLAUDE_JSON="$TMP/poll-round.json"
QUOTA_STATE="$TMP/poll-round-state.json"; QUOTA_CACHE_MTIME=""
echo "── 主轮询：发现账号漂移后不得重启监控并把旧账号读数收编进 state ──"
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON
cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"old@x","accountUuid":"uuid-old"},
 "cachedUsageUtilization":{"accountUuid":"uuid-old"}}
JSON
POLL_MONITOR_MARK="$TMP/account-drift-monitor-called"
rm -f "$POLL_MONITOR_MARK"
if (
  quota_reap_dead_sessions() { :; }
  quota_monitor_refresh() { : > "$POLL_MONITOR_MARK"; return 1; }
  quota_read_once >/dev/null 2>&1
); then
  drift_poll_rc=0
else
  drift_poll_rc=$?
fi
if (( drift_poll_rc != 0 )) && [[ ! -e "$POLL_MONITOR_MARK" ]] \
   && [[ "$(quota_state_get '.account' '')" == "target@x" ]]; then
  pass "主轮询在账号漂移处止步，没有静默跟随旧账号"
else
  fail "主轮询未在账号漂移处止步（rc=$drift_poll_rc monitor_called=$([[ -e "$POLL_MONITOR_MARK" ]] && echo yes || echo no)）"
fi

echo "── 主轮询归属：必须消费 guard 同一快照，不能通过后再读一次身份 ──"
QUOTA_STATE="$TMP/poll-same-snapshot.json"; QUOTA_CACHE_MTIME=""
echo '{}' > "$QUOTA_STATE"
if (
  quota_account_guard() {
    QUOTA_GUARD_EMAIL='target@x'
    QUOTA_GUARD_UUID='uuid-target'
    return 0
  }
  quota_reap_dead_sessions() { return 0; }
  quota_monitor_refresh() { QUOTA_PANEL_LAST=$'20\t30\tfive-good\tweek-good'; return 0; }
  quota_panel_reset_epoch() {
    [[ -n "${2:-}" ]] && echo $(( $(date +%s) + 1800 )) || echo $(( $(date +%s) + 604800 ))
  }
  # Simulate the case where an older writer overwrites the whole file with a DIFFERENT but
  # internally consistent account, only after the guard has already passed.
  # 模拟 guard 通过后旧 writer 才把文件完整盖成另一个内部自洽的账号。
  quota_identity_read() { printf 'old@x\037uuid-old\037uuid-old\n'; }
  quota_ratio_update() { :; }
  quota_capacity_update() { :; }
  quota_after_recovery() { :; }
  quota_read_once >/dev/null 2>&1
); then
  poll_snapshot_rc=0
else
  poll_snapshot_rc=$?
fi
if (( poll_snapshot_rc == 0 )) \
   && [[ "$(quota_state_get '.account' '')" == "target@x" ]] \
   && [[ "$(quota_state_get '.uuid' '')" == "uuid-target" ]]; then
  pass "面板值归给 guard 已确认的同一快照，未被第二次读取改写归属"
else
  fail "guard 后另读身份重新打开 TOCTOU（rc=$poll_snapshot_rc account=$(quota_state_get '.account' '')）"
fi
unset QUOTA_CLAUDE_JSON

echo "── 双时钟：未到网络 due 只做 10s 本地处理，不重复进入决策 ──"
SCHED_NOW=$(date +%s)
QUOTA_STATE="$TMP/usage-schedule.json"; QUOTA_CACHE_MTIME=""
cat > "$QUOTA_STATE" <<JSON
{"account":"sched@x","uuid":"uuid-s","five_hour":80,"seven_day":10,
 "monitor_session_created":111,"monitor_launch_id":"launch-111",
 "usage_refresh":{"account":"sched@x","uuid":"uuid-s","monitor_generation":111,
                  "monitor_launch_id":"launch-111",
                  "refresh_seq":7,"decided_seq":7,"interval_seconds":60,
                  "next_due_ts":$((SCHED_NOW+60))}}
JSON
if ! quota_usage_refresh_due "$SCHED_NOW" 'sched@x' 'uuid-s' 111 'launch-111' \
   && quota_usage_refresh_due "$((SCHED_NOW+60))" 'sched@x' 'uuid-s' 111 'launch-111' \
   && quota_usage_refresh_due "$SCHED_NOW" 'sched@x' 'uuid-s' 111 'launch-new' \
   && quota_usage_refresh_due "$SCHED_NOW" 'other@x' 'uuid-o' 222 'launch-222'; then
  pass "同账号/同 客户端 代际在 next_due 前不触网；到点或账号/tmux/cc 代际变化立即刷新"
else
  fail "网络 due 没有按持久账号、tmux+客户端 代际与 next_due 隔离"
fi
LOCAL_MARK="$TMP/local-observe"; NETWORK_MARK="$TMP/network-refresh"
rm -f "$LOCAL_MARK" "$NETWORK_MARK"
_stub_save quota_account_guard quota_reap_dead_sessions quota_monitor_observe quota_monitor_refresh
quota_account_guard() { QUOTA_GUARD_EMAIL='sched@x'; QUOTA_GUARD_UUID='uuid-s'; return 0; }
quota_reap_dead_sessions() { return 0; }
quota_monitor_observe() { : > "$LOCAL_MARK"; return 0; }
quota_monitor_refresh() { : > "$NETWORK_MARK"; return 1; }
if quota_read_once >/dev/null 2>&1 && [[ -e "$LOCAL_MARK" && ! -e "$NETWORK_MARK" ]]; then
  pass "未到 due 的 poll tick 只处理本地面板，不调用 /usage，也不复用旧帧做决策"
else
  fail "10s 本地 tick 仍触发了网络 /usage 或没有处理面板"
fi
_stub_restore quota_account_guard quota_reap_dead_sessions quota_monitor_observe quota_monitor_refresh

echo "── 双时钟：成功后的下一 due 必须从采样完成时刻计算 ──"
COMPLETE_MARK="$TMP/usage-refresh-completed"
rm -f "$COMPLETE_MARK"
if (
  QUOTA_STATE="$TMP/usage-completion-clock.json"; QUOTA_CACHE_MTIME=""
  cat > "$QUOTA_STATE" <<'JSON'
{"account":"clock@x","uuid":"uuid-c","monitor_session_created":111,
 "monitor_launch_id":"launch-111",
 "usage_refresh":{"account":"clock@x","uuid":"uuid-c","monitor_generation":111,
                  "monitor_launch_id":"launch-111",
                  "refresh_seq":8,"decided_seq":8}}
JSON
  date() {
    if [[ "$*" == "+%s" ]]; then
      [[ -e "$COMPLETE_MARK" ]] && printf '1020\n' || printf '1000\n'
    else
      command date "$@"
    fi
  }
  quota_account_guard() { QUOTA_GUARD_EMAIL='clock@x'; QUOTA_GUARD_UUID='uuid-c'; return 0; }
  quota_reap_dead_sessions() { return 0; }
  quota_usage_refresh_due() { return 0; }
  quota_monitor_refresh() {
    QUOTA_PANEL_LAST=$'75\t8\tfive-reset\tweek-reset'; QUOTA_REFRESH_SEQ=9
    : > "$COMPLETE_MARK"
    return 0
  }
  quota_window_reset_for_write() {
    [[ "$4" == "$QUOTA_SESSION_WINDOW_HORIZON" ]] && printf '1500\n' || printf '6000\n'
  }
  quota_source_log_usage() { return 0; }
  quota_source_log_usage_failure() { return 0; }
  quota_ratio_update() { :; }
  quota_capacity_update() { :; }
  quota_after_recovery() { return 0; }
  quota_log() { :; }
  quota_read_once >/dev/null 2>&1
  # ⚠️ This case tests the **clock origin**, not the tier value: next_due must equal
  #    completion time + the tier actually used this round.
  #    It used to hard-code 1320 (=1020+300). Once rate adaptation was added the tier could
  #    legitimately tighten, and this went red immediately -- but what was broken was not
  #    the semantics under test, it was the assertion treating a VARIABLE tier as a
  #    constant.
  #    ⭐ 断言把一个会合法变化的量写成常量，红的时候看起来像被测物坏了。
  #    ⭐ An assertion that hard-codes a legitimately-varying quantity looks, when it goes
  #      red, exactly like the code under test being broken.
  #    Rewritten as an invariant: if the three values relate to each other correctly, they
  #    came from the same completion clock.
  # ⚠️ 本条测的是**时钟起点**，不是档位数值：next_due 必须 = 完成时刻 + 本轮实际档位。
  #    原来写死成 1320（=1020+300）——加了流速自适应后档位会被合法地收紧，
  #    这条立刻转红，但坏的不是被测语义，是断言把可变的档位当成了常量。
  #    改成断言不变式：三个值互相之间的关系对，就说明用的是同一个完成时钟。
  _clk_fetched=$(quota_state_get '.fetched_ts' 0)
  _clk_success=$(quota_state_get '.usage_refresh.last_success_ts' 0)
  _clk_due=$(quota_state_get '.usage_refresh.next_due_ts' 0)
  _clk_int=$(quota_state_get '.usage_refresh.interval_seconds' 0)
  [[ "$_clk_fetched" == "1020" && "$_clk_success" == "1020" ]] \
     && [[ "$_clk_int" =~ ^[0-9]+$ ]] && (( _clk_int > 0 )) \
     && [[ "$_clk_due" == "$(( 1020 + _clk_int ))" ]]
); then
  pass "300s 档从网络采样完成时刻起算，fetched/success/next_due 使用同一完成时钟"
else
  fail "网络耗时被从档位中扣掉：下一 due 仍从 poll tick 开始时刻计算"
fi

echo "── P2-C：reset 在写入 state 前统一按窗口视界校验 ──"
P2C_NOW=$(date +%s)
P2C_FIVE_BAD=$(( P2C_NOW + QUOTA_SESSION_WINDOW_HORIZON + 3600 ))
P2C_WEEK_BAD=$(( P2C_NOW - 60 ))
P2C_WEEK_TOO_FAR=$(( P2C_NOW + ${QUOTA_WEEK_WINDOW_HORIZON:-700000} + 3600 ))
P2C_FIVE_GOOD=$(( P2C_NOW + 1800 ))
P2C_WEEK_GOOD=$(( P2C_NOW + 604800 ))
if declare -F quota_reset_validate_for_write >/dev/null 2>&1 \
   && [[ "$(quota_reset_validate_for_write "$P2C_FIVE_GOOD" "$P2C_NOW" "$QUOTA_SESSION_WINDOW_HORIZON")" == "$P2C_FIVE_GOOD" ]] \
   && [[ "$(quota_reset_validate_for_write "$P2C_WEEK_GOOD" "$P2C_NOW" "${QUOTA_WEEK_WINDOW_HORIZON:-700000}")" == "$P2C_WEEK_GOOD" ]] \
   && ! quota_reset_validate_for_write "$P2C_FIVE_BAD" "$P2C_NOW" "$QUOTA_SESSION_WINDOW_HORIZON" >/dev/null 2>&1 \
   && ! quota_reset_validate_for_write "$P2C_WEEK_BAD" "$P2C_NOW" "${QUOTA_WEEK_WINDOW_HORIZON:-700000}" >/dev/null 2>&1 \
   && ! quota_reset_validate_for_write nope "$P2C_NOW" "$QUOTA_SESSION_WINDOW_HORIZON" >/dev/null 2>&1 \
   && ! quota_reset_validate_for_write "$P2C_NOW" "$P2C_NOW" "$QUOTA_SESSION_WINDOW_HORIZON" >/dev/null 2>&1 \
   && [[ "$(quota_reset_validate_for_write "$((P2C_NOW+QUOTA_SESSION_WINDOW_HORIZON))" "$P2C_NOW" "$QUOTA_SESSION_WINDOW_HORIZON")" == "$((P2C_NOW+QUOTA_SESSION_WINDOW_HORIZON))" ]]; then
  pass "reset 写入校验：合法未来边界保留，过期/超视界/非数字拒绝"
else
  fail "缺少统一 reset 写入校验，或 epoch 边界语义错误"
fi

# The main round writes two places: the top-level current value and accounts[current].
# If either reset is illegal the WHOLE frame must be rejected atomically -- do not pair a
# new percentage with an old reset, and do not write null and thereby manufacture the very
# incomplete ledger this guards against.
# 主轮写两份：顶层当前值 + accounts[current]。任一 reset 非法时，整帧必须原子拒绝，
# 不能把新百分比配旧 reset，也不能写 null 主动制造残缺台账。
QUOTA_STATE="$TMP/reset-write-current.json"; QUOTA_CACHE_MTIME=""
cat > "$QUOTA_STATE" <<JSON
{"phase":"normal","account":"prior@x","five_hour":7,"seven_day":8,
 "five_reset_ts":$P2C_FIVE_GOOD,"week_reset_ts":$P2C_WEEK_GOOD,
 "accounts":{"current@x":{"five":7,"week":8,"five_reset":$P2C_FIVE_GOOD,"week_reset":$P2C_WEEK_GOOD}}}
JSON
P2C_CURRENT_BEFORE=$(quota_state_read | jq -c '{account,five_hour,seven_day,five_reset_ts,week_reset_ts,accounts}')
P2C_DECISION_MARK="$TMP/p2c-current-decision"
rm -f "$P2C_DECISION_MARK"
_stub_save quota_account_guard quota_reap_dead_sessions quota_monitor_refresh quota_panel_reset_epoch \
           quota_ratio_update quota_capacity_update quota_after_recovery quota_source_log_usage quota_source_log_usage_failure
quota_account_guard() { QUOTA_GUARD_EMAIL='current@x'; QUOTA_GUARD_UUID='uuid-current'; return 0; }
quota_reap_dead_sessions() { return 0; }
quota_monitor_refresh() { QUOTA_PANEL_LAST=$'20\t30\tfive-bad\tweek-bad'; return 0; }
quota_panel_reset_epoch() {
  [[ "$1" == "five-bad" ]] && printf '%s\n' "$P2C_FIVE_BAD" || printf '%s\n' "$P2C_WEEK_GOOD"
}
quota_ratio_update() { : > "$P2C_DECISION_MARK"; }
quota_capacity_update() { : > "$P2C_DECISION_MARK"; }
quota_after_recovery() { : > "$P2C_DECISION_MARK"; }
quota_source_log_usage() { : > "$P2C_DECISION_MARK"; }
quota_source_log_usage_failure() { :; }
if quota_read_once >/dev/null 2>&1; then p2c_current_rc=0; else p2c_current_rc=$?; fi
P2C_CURRENT_AFTER=$(quota_state_read | jq -c '{account,five_hour,seven_day,five_reset_ts,week_reset_ts,accounts}')
if (( p2c_current_rc != 0 )) \
   && [[ "$P2C_CURRENT_AFTER" == "$P2C_CURRENT_BEFORE" ]] \
   && [[ ! -e "$P2C_DECISION_MARK" ]]; then
  pass "主轮当前账号：一维 reset 非法则整帧不写、不进入 ratio/capacity/恢复决策"
else
  fail "主轮未原子拒绝非法 reset（rc=$p2c_current_rc changed=$([[ "$P2C_CURRENT_AFTER" != "$P2C_CURRENT_BEFORE" ]] && echo yes || echo no) decision=$([[ -e "$P2C_DECISION_MARK" ]] && echo yes || echo no)）"
fi
_stub_restore quota_account_guard quota_reap_dead_sessions quota_monitor_refresh quota_panel_reset_epoch \
              quota_ratio_update quota_capacity_update quota_after_recovery quota_source_log_usage quota_source_log_usage_failure
# 🔴 Upstream had a third part to this group: **another write entry point**, reached after
#    switching to a candidate and measuring it once, which likewise must not bypass reset
#    normalisation.
#    This repo **has no such path**: the switching half was rewritten, and
#    quota_switch_perform ends once it has handed the credential move to account-switch --
#    it does not measure the candidate and does not write a candidate ledger entry
#    (candidate numbers come separately from account-probe's snapshot).
#    ⇒ That assertion has no subject here, so the whole part is NOT migrated -- rather than
#    reshaped into something that happens to pass. ⭐ 一条没有对象的断言改到能通过，
#    就成了一条恒真断言。If candidate measurement is ever added, this comes back with it.
# 🔴 上游这一组还有第三段：候选账号切过去量一次之后的**另一处写入口**，同样不许绕过
#    reset 规范化。本仓**没有那条路径**：切号那一半是重写的，quota_switch_perform
#    把凭据交给 account-switch 之后就结束，不去测量候选账号、也不写候选台账
#    （候选数值只由 account-probe 的快照另行提供）。⇒ 那段断言在本仓没有对象，整段不搬，
#    **而不是**改成一条碰巧能通过的形式。若以后补上候选测量，这段要一起补回来。
}

# ── shadow sampling / 影子采样 ──

run_shadow_tests() {
  echo "── 影子采样：两条新来源只记账，不参与额度决策 ──"
  _stub_save quota_log
  quota_log() { printf '[test] %s\n' "$1" >> "$QUOTA_LOG"; }
  rm -f "$QUOTA_SHADOW_OAUTH_STATE" "$QUOTA_SHADOW_OAUTH_EVENTS" "$QUOTA_SHADOW_OAUTH_LOCK" \
        "$QUOTA_SHADOW_STATUSLINE_STATE" "$QUOTA_SHADOW_STATUSLINE_EVENTS" "$QUOTA_SHADOW_STATUSLINE_LOCK" \
        "$QUOTA_SHADOW_SCHEDULE_STATE" "$QUOTA_SHADOW_SCHEDULE_LOCK" \
        "$QUOTA_SOURCE_EVENTS" "$QUOTA_SOURCE_EVENTS_LOCK"

  # ⚠️ Reversed: this case used to assert that the OAuth shadow poller **must be disabled
  #    by default**. That came from a measurement where 25 of 28 queries were rate-limited
  #    (7% success), so the whole line was switched off. It was re-verified later: the real
  #    cause of the limiting was **querying too often**, and at intervals of >=180s a normal
  #    token succeeded 7 times out of 7. The line was turned back on.
  #    So what is guarded is no longer "it must be off" but "even when on it must not burn
  #    request budget" -- the throttle interval may not go below the floor.
  #    ⭐ 断言要跟着决定走；一条依据已被推翻的断言会一直红着挡路，而它红得毫无信息。
  #    ⭐ Assertions have to follow the decision. One whose premise has been overturned just
  #      sits there red and blocking, and its redness carries no information.
  # ⚠️ 改判：本用例原先断言 OAuth shadow poller **必须默认停用**。那来自一次实测——
  #    28 次查询里 25 次被限流（成功率 7%），于是整条路关掉。后来重新验证过：限流的真正
  #    原因是**查询间隔太密**，正常 token 在 ≥180s 间隔下 7/7 全部成功，据此重新打开。
  #    所以现在要守的不再是「必须关」，而是「开了也不能烧接口次数」——
  #    即节流间隔不得低于地板价。
  if [[ "$QUOTA_SHADOW_OAUTH_ENABLED" == "1" ]] \
     && [[ "$QUOTA_SHADOW_OAUTH_INTERVAL" =~ ^[0-9]+$ ]] \
     && (( QUOTA_SHADOW_OAUTH_INTERVAL >= 180 )); then
    pass "OAuth shadow poller 已启用，且采样间隔不低于 180s 地板价（${QUOTA_SHADOW_OAUTH_INTERVAL}s）"
  else
    fail "OAuth 采样配置越界（enabled=$QUOTA_SHADOW_OAUTH_ENABLED interval=$QUOTA_SHADOW_OAUTH_INTERVAL）—— 间隔低于 180s 会重演 08-13 的 25/28 限流"
  fi

  local schedule
  schedule=$(quota_shadow_schedule 100000 2>/dev/null || true)
  if [[ -n "$schedule" ]] \
     && [[ "$(printf '%s' "$schedule" | jq -r '.stage,.interval_seconds' | paste -sd/ -)" == "1/20" ]] \
     && [[ "$(quota_shadow_schedule 100600 2>/dev/null | jq -r '.stage,.interval_seconds' | paste -sd/ -)" == "2/40" ]] \
     && [[ "$(quota_shadow_schedule 101200 2>/dev/null | jq -r '.stage,.interval_seconds' | paste -sd/ -)" == "3/60" ]] \
     && [[ "$(quota_shadow_schedule 101800 2>/dev/null | jq -r '.stage,.interval_seconds' | paste -sd/ -)" == "4/120" ]] \
     && [[ "$(quota_shadow_schedule 102400 2>/dev/null | jq -r '.stage,.interval_seconds' | paste -sd/ -)" == "4/120" ]]; then
    pass "四个 10 分钟阶段依次为 20s/40s/60s/120s，结束后保持 120s"
  else
    fail "四阶段采样节奏不符合 20s/40s/60s/120s"
  fi
  rm -f "$QUOTA_SHADOW_SCHEDULE_STATE" "$QUOTA_SHADOW_SCHEDULE_LOCK"

  QUOTA_STATE="$TMP/shadow-main-state.json"; QUOTA_CACHE_MTIME=""
  cat > "$QUOTA_STATE" <<'JSON'
{"phase":"near","account":"shadow@x","five_hour":91,"seven_day":88,
 "monitor_account":"shadow@x","monitor_uuid":"uuid-shadow","monitor_session_created":"4242",
 "monitor_launch_id":"launch-shadow",
 "accounts":{"shadow@x":{"five":91,"week":88}}}
JSON
  local main_before payload event count launch
  main_before=$(sha256sum "$QUOTA_STATE" | awk '{print $1}')
  payload='{"session_id":"claude-session-1","version":"2.1.226","rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":1893474000},"seven_day":{"used_percentage":34,"resets_at":1893888000}}}'

  _stub_save quota_identity_read quota_session_created quota_monitor_live_launch_id
  quota_identity_read() { printf 'shadow@x\037uuid-shadow\037uuid-shadow\n'; }
  quota_session_created() { printf '4242\n'; }
  quota_monitor_live_launch_id() { printf 'launch-shadow\n'; }

  # 归属四值走文件，不走命令行（见 lib/reading.sh 里 quota_monitor_launch_command 的注释）。
  # Ownership travels in a file, not on the command line.
  _owner_file() {
    local f="$TMP/owner-$4.json"
    jq -cn --arg a "$1" --arg u "$2" --arg g "$3" --arg l "$4" \
      '{account:$a, uuid:$u, generation:$g, launch_id:$l}' > "$f"
    printf '%s' "$f"
  }

  if printf '%s' "$payload" | quota_shadow_statusline_ingest \
       --owner-file "$(_owner_file shadow@x uuid-shadow 4242 launch-shadow)" >/dev/null 2>&1 \
     && [[ -s "$QUOTA_SHADOW_STATUSLINE_EVENTS" ]]; then
    pass "statusLine 有效帧写入独立 JSONL"
  else
    fail "statusLine 有效帧未写入独立 JSONL"
  fi
  event=$(tail -n 1 "$QUOTA_SHADOW_STATUSLINE_EVENTS" 2>/dev/null || true)
  if [[ -n "$event" ]] && printf '%s' "$event" | jq -e '
      .source == "statusline"
      and .decision_eligible == false
      and .account.email == "shadow@x"
      and .account.uuid == "uuid-shadow"
      and .monitor.generation == "4242"
      and .monitor.launch_id == "launch-shadow"
      and .observed_at > 0
      and .cadence.stage == 1
      and .cadence.interval_seconds == 20
      and .windows.five_hour.period_seconds == 18000
      and .windows.five_hour.used_percentage == 12.5
      and .windows.five_hour.resets_at == 1893474000
      and .windows.seven_day.period_seconds == 604800
      and .windows.seven_day.used_percentage == 34
      and .windows.seven_day.resets_at == 1893888000' >/dev/null 2>&1; then
    pass "statusLine 记录含来源、账号、采样时刻、两个额度窗口且明确不可决策"
  else
    fail "statusLine 影子记录字段不完整：${event:-empty}"
  fi

  printf '%s' "$payload" | quota_shadow_statusline_ingest \
    --owner-file "$(_owner_file shadow@x uuid-shadow 4242 launch-shadow)" >/dev/null 2>&1 || true
  if [[ -f "$QUOTA_SHADOW_STATUSLINE_EVENTS" ]]; then count=$(wc -l < "$QUOTA_SHADOW_STATUSLINE_EVENTS"); else count=0; fi
  if (( count == 1 )); then
    pass "statusLine 回调在当前实验频率窗口内节流"
  else
    fail "statusLine 相同帧重复落盘（lines=$count）"
  fi

  printf '%s' "${payload/claude-session-1/claude-session-2}" | quota_shadow_statusline_ingest \
    --owner-file "$(_owner_file shadow@x uuid-shadow old-generation launch-shadow)" >/dev/null 2>&1 || true
  if [[ -f "$QUOTA_SHADOW_STATUSLINE_EVENTS" ]]; then count=$(wc -l < "$QUOTA_SHADOW_STATUSLINE_EVENTS"); else count=0; fi
  if (( count == 1 )); then
    pass "statusLine 旧 monitor 代际帧被丢弃，不会串账号"
  else
    fail "statusLine 接收了旧 monitor 代际帧"
  fi

  QUOTA_SHADOW_STATUSLINE_OWNER_DIR="$TMP/owner-dir"
  if launch=$(quota_monitor_launch_command "shadow@x" "uuid-shadow" "4242" "launch-shadow" 2>/dev/null) \
     && [[ "$launch" == *"--settings"* && "$launch" == *"shadow-statusline-ingest"* \
           && "$launch" == *"refreshInterval"* ]]; then
    pass "专用 monitor 启动命令注入低频 statusLine 采样器"
  else
    fail "专用 monitor 启动命令没有注入 statusLine 采样器"
  fi

  # 🔴 这条命令是要被 send-keys 进 pane 去启动 CLI 的 ⇒ 它出现在那个**长命进程**的 argv 里。
  #    这里守的不是「短命 jq 调用」，是整个会话期间都躺在 /proc/<pid>/cmdline 里的那份。
  # 🔴 This command is sent into a pane to launch the CLI, so it becomes the argv of a
  #    LONG-LIVED process. What is guarded here is not a microsecond-long jq call but a
  #    string that sits in /proc/<pid>/cmdline for the entire session.
  if [[ "$launch" != *"shadow@x"* && "$launch" != *"uuid-shadow"* ]]; then
    pass "启动命令里没有账号地址与 UUID（归属四值走 0600 文件）"
  else
    fail "启动命令仍带账号身份，会长期留在 monitor 进程的 argv 里"
  fi
  if [[ -s "$QUOTA_SHADOW_STATUSLINE_OWNER_DIR/launch-shadow.json" ]] \
     && [[ "$(stat -c '%a' "$QUOTA_SHADOW_STATUSLINE_OWNER_DIR/launch-shadow.json")" == 600 ]] \
     && [[ "$(jq -r '.account' "$QUOTA_SHADOW_STATUSLINE_OWNER_DIR/launch-shadow.json")" == "shadow@x" ]]; then
    pass "归属文件按 0600 写下且内容正确（上一条不是因为四个值根本没被传出去）"
  else
    fail "归属文件缺失、权限不对或内容不对 —— 上一条的绿说明不了任何事"
  fi
  # ⚠️ 这条判据的正控**不在这里**，在 posctrl 的 `statusline-addr-in-argv`：那条把
  #    构造命令的写法改回「四个位置参数」再看这条断言红不红。写在这里的任何「正控」
  #    都只会是在测 bash 的 `==` 通配符匹配，而不是在测这条判据有没有分辨力
  #    —— 判据锚在谈论它的文字上，就近乎恒真。
  # ⚠️ The control for this assertion lives in posctrl (`statusline-addr-in-argv`), which
  #    reverts the command construction to the four-positional form and requires THIS
  #    assertion to go red. Anything written inline here would only exercise bash pattern
  #    matching, not this judgement -- a control anchored on prose about a check is very
  #    nearly always true.
  # 上一代 owner 文件必须被清掉 —— 既不留只增不减的凭据相关文件，也顺带把旧代际挡在门外。
  : > "$QUOTA_SHADOW_STATUSLINE_OWNER_DIR/launch-stale.json"
  quota_monitor_launch_command "shadow@x" "uuid-shadow" "4242" "launch-shadow" >/dev/null 2>&1
  if [[ ! -e "$QUOTA_SHADOW_STATUSLINE_OWNER_DIR/launch-stale.json" \
        && -s "$QUOTA_SHADOW_STATUSLINE_OWNER_DIR/launch-shadow.json" ]]; then
    pass "上一代归属文件被清掉，当代的还在（不是只增不减）"
  else
    fail "归属文件目录只增不减，或把当代的一起删了"
  fi

  if [[ "$(sha256sum "$QUOTA_STATE" | awk '{print $1}')" == "$main_before" ]]; then
    pass "statusLine 采样未改主 quota-state（不进入切号/等待/恢复）"
  else
    fail "statusLine 采样污染了主 quota-state"
  fi

  # When the tmux session is unchanged and only the client is replaced inside the same
  # pane, an old callback still carries the same session_created -- a separate launch id is
  # what keeps the previous generation's callbacks out.
  # tmux session 不变、只在原 pane 内换客户端时，旧 callback 的 session_created 仍相同；
  # 必须靠独立 launch id 把上一代回调挡住。
  quota_state_merge '.monitor_launch_id = "launch-new"' >/dev/null 2>&1
  quota_monitor_live_launch_id() { printf 'launch-new\n'; }
  if [[ -f "$QUOTA_SHADOW_STATUSLINE_EVENTS" ]]; then count=$(wc -l < "$QUOTA_SHADOW_STATUSLINE_EVENTS"); else count=0; fi
  before_launch_count=$count
  printf '%s' "${payload/claude-session-1/claude-session-old}" | quota_shadow_statusline_ingest \
    --owner-file "$(_owner_file shadow@x uuid-shadow 4242 launch-shadow)" >/dev/null 2>&1 || true
  if [[ -f "$QUOTA_SHADOW_STATUSLINE_EVENTS" ]]; then count=$(wc -l < "$QUOTA_SHADOW_STATUSLINE_EVENTS"); else count=0; fi
  if (( count == before_launch_count )); then
    pass "同 tmux 代际内上一代 客户端 的 statusLine callback 被 launch id 丢弃"
  else
    fail "旧 客户端 callback 冒用了未变化的 session_created"
  fi
  _stub_restore quota_identity_read quota_session_created quota_monitor_live_launch_id
  main_before=$(sha256sum "$QUOTA_STATE" | awk '{print $1}')
  # Decision-state snapshot: OAuth may write readings, but must not touch these fields.
  # 决策状态快照：OAuth 写读数可以，动这几格不行
  QUOTA_CACHE_MTIME=""
  decision_phase_before=$(quota_state_get '.phase' 'null')
  decision_wait_before=$(quota_state_get '.waiting_until' 'null')
  decision_episode_before=$(quota_state_get '.episode' 'null')
  decision_switch_before=$(quota_state_get '.last_switch_ts' 'null')
  decision_sessions_before=$(quota_state_read | jq -c '.sessions // {}')

  echo "── 影子采样：OAuth JSON 的成功、节流、漂移与退避 ──"
  rm -f "$QUOTA_SHADOW_OAUTH_STATE" "$QUOTA_SHADOW_OAUTH_EVENTS" "$QUOTA_SHADOW_OAUTH_LOCK"
  _stub_save quota_identity_read quota_shadow_oauth_http_fetch
  quota_identity_read() { printf 'shadow@x\037uuid-shadow\037uuid-shadow\n'; }
  quota_shadow_oauth_http_fetch() {
    local body_file="$1" header_file="$2"
    printf '%s' '{"five_hour":{"utilization":13,"resets_at":"2030-01-01T05:00:00+00:00"},"seven_day":{"utilization":47,"resets_at":"2030-01-07T00:00:00+00:00"}}' > "$body_file"
    : > "$header_file"
    printf '200'
  }
  if quota_shadow_oauth_sample >/dev/null 2>&1 \
     && event=$(tail -n 1 "$QUOTA_SHADOW_OAUTH_EVENTS" 2>/dev/null) \
     && printf '%s' "$event" | jq -e '
          .source == "oauth_api"
          and .decision_eligible == false
          and .outcome == "ok"
          and .account.email == "shadow@x"
          and .account.uuid == "uuid-shadow"
          and .observed_at > 0
          and .cadence.stage == 1
          and .cadence.interval_seconds == 20
          and .windows.five_hour.period_seconds == 18000
          and .windows.five_hour.used_percentage == 13
          and .windows.five_hour.resets_at > 0
          and .windows.seven_day.period_seconds == 604800
          and .windows.seven_day.used_percentage == 47
          and .windows.seven_day.resets_at > 0' >/dev/null 2>&1; then
    pass "OAuth JSON 成功帧按账号与窗口写入独立 JSONL"
  else
    fail "OAuth JSON 成功帧没有正确落盘：${event:-empty}"
  fi

  quota_shadow_oauth_sample >/dev/null 2>&1 || true
  if [[ -f "$QUOTA_SHADOW_OAUTH_EVENTS" ]]; then count=$(wc -l < "$QUOTA_SHADOW_OAUTH_EVENTS"); else count=0; fi
  if (( count == 1 )); then
    pass "OAuth JSON 成功采样后按低频间隔节流"
  else
    fail "OAuth JSON 未节流（lines=$count）"
  fi

  rm -f "$QUOTA_SHADOW_OAUTH_STATE" "$QUOTA_SHADOW_OAUTH_EVENTS" "$TMP/shadow-identity-changed"
  quota_identity_read() {
    if [[ -e "$TMP/shadow-identity-changed" ]]; then
      printf 'other@x\037uuid-other\037uuid-other\n'
    else
      printf 'shadow@x\037uuid-shadow\037uuid-shadow\n'
    fi
  }
  quota_shadow_oauth_http_fetch() {
    local body_file="$1" header_file="$2"
    printf '%s' '{"five_hour":{"utilization":14,"resets_at":"2030-01-01T05:00:00+00:00"},"seven_day":{"utilization":48,"resets_at":"2030-01-07T00:00:00+00:00"}}' > "$body_file"
    : > "$header_file"
    : > "$TMP/shadow-identity-changed"
    printf '200'
  }
  quota_shadow_oauth_sample >/dev/null 2>&1 || true
  event=$(tail -n 1 "$QUOTA_SHADOW_OAUTH_EVENTS" 2>/dev/null || true)
  if [[ -n "$event" ]] && printf '%s' "$event" | jq -e '.outcome == "identity_changed" and .windows == null' >/dev/null 2>&1; then
    pass "OAuth 请求途中账号变化时丢弃额度，不把值记到错误账号"
  else
    fail "OAuth 请求途中账号变化仍采信了额度：${event:-empty}"
  fi

  rm -f "$QUOTA_SHADOW_OAUTH_STATE" "$QUOTA_SHADOW_OAUTH_EVENTS" "$TMP/shadow-identity-changed"
  quota_identity_read() { printf 'shadow@x\037uuid-shadow\037uuid-shadow\n'; }
  quota_shadow_oauth_http_fetch() {
    local body_file="$1" header_file="$2"
    printf '%s' '{"error":{"type":"rate_limit_error"}}' > "$body_file"
    printf 'Retry-After: 900\r\n' > "$header_file"
    printf '429'
  }
  quota_shadow_oauth_sample >/dev/null 2>&1 || true
  event=$(tail -n 1 "$QUOTA_SHADOW_OAUTH_EVENTS" 2>/dev/null || true)
  if [[ -n "$event" ]] && printf '%s' "$event" | jq -e '
      .outcome == "rate_limited"
      and .windows == null
      and (.next_due - .attempted_at) >= 900
      and .cadence.interval_seconds >= 20' >/dev/null 2>&1 \
     && [[ "$(jq -r '.penalty_interval // 0' "$QUOTA_SHADOW_SCHEDULE_STATE" 2>/dev/null)" -ge 40 ]]; then
    pass "OAuth 429 尊重 Retry-After、自动降频且错误正文不进日志"
  else
    fail "OAuth 429 没有正确退避：${event:-empty}"
  fi
  schedule=$(quota_shadow_schedule "$(date +%s)" 2>/dev/null || echo '{}')
  if [[ "$(quota_shadow_source_interval statusline "$schedule")" == "20" \
        && "$(quota_shadow_source_interval oauth_api "$schedule")" -ge 40 ]]; then
    pass "OAuth 拒绝只降低网络直查频率，statusLine 仍按原四阶段计划"
  else
    fail "OAuth penalty 错误拖慢了本地 statusLine 采样"
  fi

  quota_source_log_usage "$(date +%s)" "shadow@x" "uuid-shadow" 15 1893474000 49 1893888000
  quota_source_log_usage_failure "$(date +%s)" "shadow@x" "uuid-shadow" "panel_stale_frame"
  if jq -s -e '
      any(.[]; .source == "statusline")
      and any(.[]; .source == "oauth_api")
      and any(.[]; .source == "usage_panel" and .decision_eligible == true)
      and any(.[]; .source == "usage_panel" and .decision_eligible == false
                   and .outcome == "panel_stale_frame" and .windows == null)
      and all(.[]; has("observed_at") and has("account") and has("windows") and has("cadence"))' \
      "$QUOTA_SOURCE_EVENTS" >/dev/null 2>&1; then
    pass "统一逐次日志同时含 /usage、OAuth、statusLine，均带账号/时刻/窗口/频率"
  else
    fail "统一逐次日志缺少三方样本或比较字段"
  fi

  # ⚠️ Upstream asserted this by grepping a single file for a call to the poller-ensure
  #    function. This repo is split across files, and the supervising daemon that called it
  #    **was not extracted** => copying that grep would only prove "this name appears in
  #    the file", which it also does at its own definition.
  #    ⭐ A grep that can only ever match the definition itself is green with no
  #      discriminating power whatsoever.
  #    Rewritten to test the thing it actually guards: **the main reading round must not
  #    drive OAuth sampling**.
  # ⚠️ 上游这条断言是「grep 单文件里有没有那个保活函数的调用」。本仓被拆成多文件，
  #    而且调用它的那个监督 daemon **未抽取** ⇒ 照搬那句 grep 只会证明「这个名字在文件里
  #    出现过」，而它在定义处也出现。⭐ 一条只会命中定义本身的 grep，绿得毫无分辨力。
  #    改成直接测它要守的那件事：**读数主轮不得驱动 OAuth 采样**。
  _stub_save quota_shadow_oauth_sample quota_account_guard quota_monitor_observe quota_usage_refresh_due
  OAUTH_DRIVEN_MARK="$TMP/oauth-driven-by-read-round"
  rm -f "$OAUTH_DRIVEN_MARK"
  quota_shadow_oauth_sample() { : > "$OAUTH_DRIVEN_MARK"; return 0; }
  quota_account_guard() { QUOTA_GUARD_EMAIL='sh@x'; QUOTA_GUARD_UUID='uuid-sh'; return 0; }
  quota_usage_refresh_due() { return 1; }
  quota_monitor_observe() { return 0; }
  quota_read_once >/dev/null 2>&1
  if declare -F quota_shadow_poller_loop >/dev/null 2>&1 \
     && declare -F quota_shadow_poller_ensure >/dev/null 2>&1 \
     && [[ ! -e "$OAUTH_DRIVEN_MARK" ]]; then
    pass "OAuth 走独立影子时钟：读数主轮跑完一整轮也没有触发过一次 OAuth 采样"
  else
    fail "OAuth 仍由 /usage 主轮驱动，20s 档会被单轮耗时拉成约 36s"
  fi
  # Positive control: the same marker file must appear when OAuth sampling really is
  # called -- otherwise the "it did not appear" above is indistinguishable from not testing.
  # 正控：同一个标记文件在 OAuth 采样真被调用时必须出现，否则上面那条「没出现」等于没测。
  quota_shadow_oauth_sample >/dev/null 2>&1
  if [[ -e "$OAUTH_DRIVEN_MARK" ]]; then
    pass "正控：标记文件在采样真被调用时确实出现（上面那条不是恒真）"
  else
    fail "正控没红：标记文件根本不会出现，上面那条断言不测任何东西"
  fi
  _stub_restore quota_shadow_oauth_sample quota_account_guard quota_monitor_observe quota_usage_refresh_due

  # 🔴 Reported, not fixed: quota_shadow_poller_ensure has **no caller at all** in this
  #    repo -- upstream, the supervising daemon that was not extracted called it every beat
  #    to keep the poller alive. The only entry point here is the CLI's shadow-poller
  #    subcommand, which a person has to start. ⇒ Shadow sampling **does not start itself**
  #    in this repo by default. This pins the fact; it deliberately does not decide on the
  #    reader's behalf who ought to call it.
  # 🔴 一处只报不修的观察：quota_shadow_poller_ensure 在本仓**没有任何调用方**——上游是
  #    那个未抽取的监督 daemon 每拍调它保活。本仓唯一的启动口是 CLI 的 shadow-poller
  #    子命令，要人自己起。⇒ 影子采样在本仓默认**不会自己跑起来**。这里只把事实钉住，
  #    不替它决定该由谁调。
  if grep -q 'shadow-poller' "$QS_SOURCE/quota-sentinel"; then
    pass "影子采样至少有一个可达入口（CLI shadow-poller）；ensure 保活无调用方，已记录"
  else
    fail "影子采样在本仓无任何可达入口：定义在那里，谁都起不动它"
  fi

  # ⚠️ Reversed: this used to assert "OAuth may not change one byte" via a sha256 of the
  #    whole state file. That was the contract while OAuth was a pure shadow. Once it became
  #    a real upstream, **writing readings is its job** and the whole-file hash necessarily
  #    changes. What it was really protecting did not change at all, and deserves to be
  #    guarded more precisely: **OAuth may update readings, but must never itself drive the
  #    switch / wait / recovery state transitions.**
  #    So it is now guarded field by field -- which is STRONGER than a whole-file hash: the
  #    hash only tells you "something changed", not whether it was a reading or the phase,
  #    and those two have completely different consequences.
  #    ⭐ 一个更粗的判据不等于一个更严的判据。
  #    ⭐ A coarser check is not the same thing as a stricter one.
  # ⚠️ 改判：原先用整个状态文件的 sha256 断言「OAuth 一个字节都不许动」。那是 OAuth
  #    还是纯影子时的契约。它转为正式上游后，**写读数是它的本职**，整文件哈希必然变化。
  #    但它背后要防的事一点没变、而且更该精确地守住：
  #    **OAuth 可以更新读数，但绝不能自己驱动切号/等待/恢复的状态跃迁。**
  #    所以改成按字段守 —— 这比整文件哈希更强：哈希只会告诉你「有东西变了」，
  #    不会告诉你变的是读数还是 phase，而这两者的后果天差地别。
  if [[ "$(quota_state_get '.phase' 'null')" == "$decision_phase_before" ]] \
     && [[ "$(quota_state_get '.waiting_until' 'null')" == "$decision_wait_before" ]] \
     && [[ "$(quota_state_get '.episode' 'null')" == "$decision_episode_before" ]] \
     && [[ "$(quota_state_get '.last_switch_ts' 'null')" == "$decision_switch_before" ]] \
     && [[ "$(quota_state_read | jq -c '.sessions // {}')" == "$decision_sessions_before" ]]; then
    pass "OAuth 采样只更新读数，不碰 phase/waiting/episode/last_switch/sessions（不驱动决策跃迁）"
  else
    fail "OAuth 采样动了决策状态：phase=$(quota_state_get '.phase' 'null')（原 $decision_phase_before）waiting=$(quota_state_get '.waiting_until' 'null')（原 $decision_wait_before）"
  fi
  _stub_restore quota_identity_read quota_shadow_oauth_http_fetch
  _stub_restore quota_log
}


# ── the decision layer / 决策层 ──
run_decision_tests() {

echo "── 切号被挡下时不得每拍重试 ──"
# ⚠️ Once decisions moved to every 10s, "threshold reached -> nowhere to switch" went from
#    once a minute to once every 10 seconds, and hit live as several hundred log lines.
#    With only one in-service account left, **reaching the threshold necessarily means
#    nowhere to switch**, so that state appears daily and lasts for hours -- the noise
#    buries the real signal.
# 🔴 The shape here is slightly worse: besides logging, the nowhere-to-switch branch also
#    **appends a `blocked` line to the ledger on every beat** -- and the ledger is the only
#    thing that can afterwards reconstruct why this machine is on this account.
#    Upstream hung this throttle on its safety gate (not extracted); here it hangs on the
#    quota_switch_pick failure branch. Same thing guarded, different place.
# ⚠️ 决策拆成每 10s 一拍之后，「触阈值 → 无处可切」从每 60s 一次变成每 10s 一次，
#    实撞刷了几百行。而在役只剩一个账号时，**到阈值必然无处可切**，这个状态天天出现
#    并持续数小时——噪音会埋掉真信号。
# 🔴 本仓的形态更糟一点：无处可切那一支除了打日志，还会**每拍往流水账追加一条 blocked**，
#    而流水账正是事后唯一能复原「这台机器为什么在这个账号上」的东西。
#    上游这道闸挂在它的安全闸（未抽取）上；本仓挂在 quota_switch_pick 失败这一支上。
#    守的是同一件事，位置不同。
TH="$TMP/throttle"; mkdir -p "$TH"
QUOTA_STATE="$TH/state.json"; QUOTA_LOG="$TH/quota.log"; QUOTA_SWITCH_LEDGER="$TH/switches.jsonl"
_TH_NOW=1787320000
_th_state() {   # 只有一个在役账号且已过线 ⇒ quota_switch_pick 必然找不到候选
  printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":95,"week":10}}}' \
    "$(( _TH_NOW - 30 ))" > "$QUOTA_STATE"
}
_th_state; : > "$QUOTA_LOG"; : > "$QUOTA_SWITCH_LEDGER"
for _i in $(seq 0 29); do quota_decide_once "$(( _TH_NOW + _i * 10 ))" >/dev/null 2>&1; done
_th_log=$(grep -c '🛑' "$QUOTA_LOG"); _th_led=$(grep -c '"blocked"' "$QUOTA_SWITCH_LEDGER")
if [[ "$_th_log" == "1" && "$_th_led" == "1" ]]; then
  pass "被挡下后 5 分钟（30 拍）日志 1 条、流水账 1 条，不刷屏也不刷账"
else
  fail "5 分钟内日志 $_th_log 条、流水账 $_th_led 条——每拍重试会把两者都刷满"
fi
# ⚠️ Control 1: silence must not become permanent muteness. After the debounce window it
#    has to speak again -- otherwise one "nowhere to switch" silences it forever, which is
#    far worse than flooding.
# ⚠️ 正控之一：静默不能变成永久闭嘴。防抖窗口过后必须能重新出声，
#    否则一次「无处可切」之后就再也不报告了——那比刷屏严重得多。
quota_decide_once "$(( _TH_NOW + QUOTA_SWITCH_MIN_INTERVAL + 5 ))" >/dev/null 2>&1
if [[ "$(grep -c '🛑' "$QUOTA_LOG")" == "2" ]]; then
  pass "正控：防抖窗口过后恢复报告（静默没变成永久闭嘴）"
else
  fail "窗口过后仍不出声——一次被挡就再也不报告了"
fi
# ⚠️ Control 2: the first attempt must not be delayed. The throttle only applies AFTER
#    something has already been blocked once.
# ⚠️ 正控之二：首次尝试不得被延迟。闸只在「已经被挡过」之后生效。
_th_state; : > "$QUOTA_LOG"; : > "$QUOTA_SWITCH_LEDGER"
quota_decide_once "$_TH_NOW" >/dev/null 2>&1
if [[ "$(grep -c '🛑' "$QUOTA_LOG")" == "1" ]]; then
  pass "正控：首次尝试立即执行，不被防抖闸延迟"
else
  fail "首次尝试就被压住——真该报告时会晚 ${QUOTA_SWITCH_MIN_INTERVAL}s"
fi
# ⚠️ Control 3: the throttle must not suppress a switch that CAN happen. Inside the same
#    debounce window, an available candidate must still be switched to.
#    ⭐ Without this one, an "always refuse" implementation passes the three above.
# ⚠️ 正控之三：闸不能把**能切**的那次也压住。同样在防抖窗口内，只要出现可用候选就必须切。
#    没有这一条，上面三条用「恒拒」实现也全绿。
printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":95,"week":10},"free@x":{"five":5,"week":5}}}' \
  "$(( _TH_NOW - 30 ))" > "$QUOTA_STATE"
: > "$QUOTA_LOG"
quota_decide_once "$(( _TH_NOW + 10 ))" >/dev/null 2>&1
if grep -q 'would switch' "$QUOTA_LOG"; then
  pass "正控：防抖窗口内出现可用候选时照常切号（闸压的是重复报告，不是切号）"
else
  fail "防抖闸把真正该切的那次也压住了：$(tail -1 "$QUOTA_LOG")"
fi

echo "── 决策只读台账，且对陈旧读数 fail closed ──"
# ⚠️ Deciding was split out of collecting, so every poll beat now judges against the
#    ledger. Before the split, a decision happened only on the beat where the panel
#    refreshed successfully -- which meant a new reading written by OAuth was not seen
#    until the panel next succeeded, and the panel goes blind under rate limiting exactly
#    when the threshold is near (measured 27 times, median 6.4 minutes).
# ⚠️ Splitting it REQUIRES a freshness gate, or it is worse than before: repeatedly
#    deciding against a FROZEN ledger means confidently judging on a stale level every
#    single beat, whereas the old shape at least did not judge without a refresh.
# ⚠️ 判断从采集里拆出来，轮询每一拍都对着台账判一次。拆之前决策只在**面板刷新成功那一拍**
#    发生，于是 OAuth 写进台账的新读数要等面板下次成功才被看见——而面板恰恰在逼近阈值时
#    被限流失明（实测 27 次、中位 6.4 分钟）。
# ⚠️ 拆开就必须配新鲜度闸，否则更糟：对着**僵住的**台账反复决策，等于每一拍都自信地
#    按陈旧水位判一次；原来至少「没刷新就不判」。
DC="$TMP/decide"; mkdir -p "$DC"
QUOTA_STATE="$DC/state.json"; QUOTA_LOG="$DC/quota.log"; QUOTA_SWITCH_LEDGER="$DC/switches.jsonl"
_DC_NOW=1787320000
_dc_run() {  # $1=five $2=读数年龄(s)
  printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":%s,"week":10},"free@x":{"five":5,"week":5}}}' \
    "$(( _DC_NOW - $2 ))" "$1" > "$QUOTA_STATE"
  : > "$QUOTA_LOG"; : > "$QUOTA_SWITCH_LEDGER"
  quota_decide_once "$_DC_NOW" >/dev/null 2>&1
  grep -c 'would switch' "$QUOTA_LOG"
}
if [[ "$(_dc_run 95 30)" == "1" ]]; then
  pass "读数新鲜且超阈值 → 只凭台账就能判定切号（不必等面板那一拍）"
else
  fail "台账里已有超阈值的新读数却没判 —— 决策没接上台账"
fi
if [[ "$(_dc_run 40 30)" == "0" ]]; then
  pass "读数新鲜但未到阈值 → 不切"
else
  fail "未到阈值也切了"
fi
# ⚠️ This risk is CREATED BY the split, so it has to be guarded hard.
# ⚠️ 这条是拆分带来的**新**风险，必须守死。
if [[ "$(_dc_run 95 $(( QUOTA_FETCH_MAX_AGE + 60 )))" == "0" ]]; then
  pass "读数超期 → 不做决策（fail closed，不按陈旧水位切号）"
else
  fail "拿超期读数切号 —— 每拍都会把这个错误重复一次"
fi
_dc_run 95 "$(( QUOTA_FETCH_MAX_AGE + 60 ))" >/dev/null
if grep -q 'no decision this round' "$QUOTA_LOG"; then
  pass "超期时说明了原因（上一条不是因为函数压根没跑到）"
else
  fail "超期时静默返回 —— 分不清『判过了没超阈值』和『压根没判』"
fi
# ⚠️ Positive control: the same stale reading is reported once, but a DIFFERENT stale
#    reading has to be reported again.
#    ⭐ "Once per reading" and "once ever" look identical within a single run.
# ⚠️ 正控：同一份超期读数只说一次，但换一份新的超期读数必须重新说。
#    「每份说一次」与「说过一次就再也不说」在单次运行里长得一模一样。
: > "$QUOTA_LOG"
printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":95,"week":10},"free@x":{"five":5,"week":5}}}' \
  "$(( _DC_NOW - QUOTA_FETCH_MAX_AGE - 60 ))" > "$QUOTA_STATE"
quota_decide_once "$_DC_NOW" >/dev/null 2>&1
quota_decide_once "$_DC_NOW" >/dev/null 2>&1
_dc_first=$(grep -c 'no decision this round' "$QUOTA_LOG")
printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":95,"week":10},"free@x":{"five":5,"week":5}},"decide_stale_logged":%s}' \
  "$(( _DC_NOW - QUOTA_FETCH_MAX_AGE - 61 ))" "$(( _DC_NOW - QUOTA_FETCH_MAX_AGE - 60 ))" > "$QUOTA_STATE"
quota_decide_once "$_DC_NOW" >/dev/null 2>&1
_dc_second=$(grep -c 'no decision this round' "$QUOTA_LOG")
if [[ "$_dc_first" == "1" && "$_dc_second" == "2" ]]; then
  pass "正控：同一份陈旧读数只说一次，换一份仍会说（不是说过就永久闭嘴）"
else
  fail "陈旧提示的去重口径错了（同一份说了 $_dc_first 次，换一份后累计 $_dc_second 次）"
fi

echo "── 两条线同时越过时，流水账必须两条都写 ──"
# Upstream assigned these two directly, so the weekly one silently overwrote the five-hour
# one: a double exhaustion left only ONE reason in the ledger, and a reader would conclude
# the five-hour window was fine. Extraction changed it to accumulate; this pins that.
# 上游那两句原本是直接赋值，周额度那句会把五小时那句悄悄盖掉；双重耗尽在账本里只剩一个
# 原因，读的人会据此以为五小时没事。抽取时已改成累加，这里把它钉住。
QUOTA_STATE="$DC/both.json"; QUOTA_LOG="$DC/both.log"; QUOTA_SWITCH_LEDGER="$DC/both.jsonl"
printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":99,"week":100},"free@x":{"five":5,"week":5}}}' \
  "$(( _DC_NOW - 30 ))" > "$QUOTA_STATE"
: > "$QUOTA_LOG"; : > "$QUOTA_SWITCH_LEDGER"
quota_decide_once "$_DC_NOW" >/dev/null 2>&1
_both=$(jq -r '.note' "$QUOTA_SWITCH_LEDGER" 2>/dev/null | tail -1)
if [[ "$_both" == *"five_hour"* && "$_both" == *"weekly"* ]]; then
  pass "两条线都越过时账本两条原因都在（不是后一条盖掉前一条）"
else
  fail "双重耗尽在账本里只留下一个原因：[$_both]"
fi
# Positive control: crossing only one line must leave only that one in the ledger --
# otherwise an "always write both" implementation passes the case above too.
# 正控：只越过一条线时，账本里必须只有那一条，否则上面那条用「永远两条都写」也能过。
printf '{"account":"cur@x","fetched_ts":%s,"accounts":{"cur@x":{"five":99,"week":10},"free@x":{"five":5,"week":5}}}' \
  "$(( _DC_NOW - 30 ))" > "$QUOTA_STATE"
: > "$QUOTA_SWITCH_LEDGER"
quota_decide_once "$_DC_NOW" >/dev/null 2>&1
_one=$(jq -r '.note' "$QUOTA_SWITCH_LEDGER" 2>/dev/null | tail -1)
if [[ "$_one" == *"five_hour"* && "$_one" != *"weekly"* ]]; then
  pass "正控：只越过五小时线时账本只写这一条（上面那条不是恒真）"
else
  fail "只越过一条线却写了两条原因：[$_one]"
fi
}

# ── slow layer / 慢层 ──
run_slow_tests() {
echo "── /usage 主动刷新：clean 重开、错误页才按 r，结束后面板常驻 ──"
# Claude Code 2.1.226 的 clean 面板没有 r action；正常到期必须 Esc→重开 /usage。
# rate-limit/last-known/error 面板才注册 r to retry。两条路径都不能在读完后再次 dismiss。
REFRESH_TRACE="$TMP/usage-refresh-trace"
: > "$REFRESH_TRACE"
_stub_save quota_monitor_prepare_owner quota_monitor_dismiss quota_monitor_panel_open \
           quota_monitor_owner_guard quota_monitor_open_usage quota_usage_refresh_begin \
           quota_usage_refresh_failure quota_panel_reset_epoch quota_frame_stale quota_panel_log_observation
_stub_save quota_monitor_recover_stale_frame
PANEL_OK=$'Current session\n  20% used\n  Resets 5:00pm (Asia/Shanghai)\nCurrent week (all models)\n  30% used\n  Resets Aug 20, 5:00pm (Asia/Shanghai)'
REFRESH_FRAME="$PANEL_OK"
tmux() {
  if [[ "${1:-}" == "send-keys" ]]; then
    printf 'send:%s\n' "${!#}" >> "$REFRESH_TRACE"
    [[ "${!#}" == "r" ]] && REFRESH_FRAME="$PANEL_OK"
    return 0
  fi
  if [[ "${1:-}" == "capture-pane" ]]; then
    printf '%s\n' "$REFRESH_FRAME"
    return 0
  fi
  return 0
}
sleep() { :; }
quota_monitor_prepare_owner() {
  QUOTA_MONITOR_CURRENT_ACCOUNT='s@x'; QUOTA_MONITOR_CURRENT_UUID='u'
  QUOTA_MONITOR_CURRENT_GENERATION=111; QUOTA_MONITOR_CURRENT_LAUNCH_ID='launch-111'; return 0
}
quota_monitor_dismiss() { printf 'dismiss\n' >> "$REFRESH_TRACE"; return 0; }
quota_monitor_panel_open() { return 0; }
quota_monitor_owner_guard() { return 0; }
quota_monitor_open_usage() { printf 'open\n' >> "$REFRESH_TRACE"; QUOTA_REFRESH_SEQ=1; return 0; }
quota_usage_refresh_begin() { printf 'begin\n' >> "$REFRESH_TRACE"; QUOTA_REFRESH_SEQ=1; return 0; }
quota_usage_refresh_failure() { return 0; }
quota_panel_reset_epoch() { echo $(( $(date +%s) + 3600 )); }
quota_frame_stale() { return 1; }
quota_panel_log_observation() { :; }
QUOTA_PANEL_LAST=""
if quota_monitor_refresh >/dev/null 2>&1; then
  if [[ "$(grep -c '^dismiss$' "$REFRESH_TRACE")" == "1" ]] \
     && [[ "$(grep -c '^open$' "$REFRESH_TRACE")" == "1" ]] \
     && ! grep -q '^send:r$' "$REFRESH_TRACE"; then
    pass "clean 面板只在网络到期时收起并重开一次；读完不再关闭，也不发送无效 r"
  else
    fail "clean 面板生命周期错误：$(tr '\n' ' ' < "$REFRESH_TRACE")"
  fi
else
  fail "clean 面板重开用例未完成"
fi

: > "$REFRESH_TRACE"
REFRESH_FRAME="$PANEL_OK"$'\nUsage endpoint is rate limited. Press r to retry'
QUOTA_PANEL_LAST=""
if quota_monitor_refresh >/dev/null 2>&1 \
   && grep -q '^begin$' "$REFRESH_TRACE" \
   && grep -q '^send:r$' "$REFRESH_TRACE" \
   && ! grep -qE '^(dismiss|open)$' "$REFRESH_TRACE"; then
  pass "错误页到期时只按一次 r retry，不重开第二个请求；成功后仍保留面板"
else
  fail "错误页没有走单次 r retry：$(tr '\n' ' ' < "$REFRESH_TRACE")"
fi

: > "$REFRESH_TRACE"
REFRESH_FRAME="$PANEL_OK"
quota_monitor_owner_guard() { printf 'owner-guard\n' >> "$REFRESH_TRACE"; return 1; }
quota_frame_stale() { printf 'stale-check\n' >> "$REFRESH_TRACE"; return 0; }
quota_monitor_recover_stale_frame() { printf 'stale-restart\n' >> "$REFRESH_TRACE"; return 0; }
if ! quota_monitor_refresh >/dev/null 2>&1 \
   && grep -q '^owner-guard$' "$REFRESH_TRACE" \
   && ! grep -qE '^(stale-check|stale-restart)$' "$REFRESH_TRACE"; then
  pass "采样期账号漂移先被 owner guard 拦下，不进入 stale 判断或重启 UI"
else
  fail "stale 自愈抢在 panel-after 身份 bracket 前运行：$(tr '\n' ' ' < "$REFRESH_TRACE")"
fi
unset -f sleep; _tmux_guard_install   # 不留裸奔窗口：清桩即重装闸
_stub_restore quota_monitor_prepare_owner quota_monitor_dismiss quota_monitor_panel_open \
              quota_monitor_owner_guard quota_monitor_open_usage quota_usage_refresh_begin \
              quota_usage_refresh_failure quota_panel_reset_epoch quota_frame_stale quota_panel_log_observation
_stub_restore quota_monitor_recover_stale_frame

echo "── 采样：窗口内要取最大帧，不能取「第一个稳定的」──"
# This is the other half of the fix. The old rule ("accept once N consecutive readings
# agree") accepts the CACHED frame whenever the sequence is "cache appears first and
# repeats, truth arrives later" -- and that is exactly the measured shape (the panel serves
# a cache at +1s and only refreshes at +2s, and fetching is throttled).
# 这是修复的另一半。旧规则「连续 N 次一致就收下」在「缓存帧先出现且重复多次、真值后到」
# 的序列上会收下缓存帧——而这正是实测的形态（面板 +1s 给缓存、+2s 才刷新，且拉取有节流）。
# ⚠️ 面板时刻必须动态生成为未来：写死 "Resets 3:29pm" 的话，现实时间一过 15:29，
# 这一帧就真的属于过期窗口，被 stale 规则**正确地**拒掉——测试会在下午定时变红。
# ⚠️ LC_ALL=C is mandatory: `date`'s %P/%b FOLLOW THE LOCALE. Under a Chinese locale `%P`
#    prints a localised string instead of "pm", and feeding that to the parser produces an
#    input that can never occur in reality -- the client's panel is always English.
#    Without the lock these cases test the machine's locale rather than the production
#    logic, and the failure message reads as though the PARSER is broken, which points
#    whoever is debugging in the wrong direction.
# ⚠️ 必须锁 LC_ALL=C：date 的 %P/%b 是**跟随 locale** 的，本机中文环境下 `%P` 输出
#    「下午」而不是「pm」，喂给解析器就是一个现实中根本不会出现的字符串——
#    客户端面板永远是英文。不锁的话这几条用例测的不是生产逻辑，而是本机 locale，
#    且失败文案会显示成解析器坏了，把人引向错误方向。
PANEL_SESS_RESET=$(LC_ALL=C TZ=CST-8 date -d '+2 hours' '+%-I:%M%P')
PANEL_WEEK_RESET=$(LC_ALL=C TZ=CST-8 date -d '+3 days' '+%b %-d, %-I:%M%P')
mk_panel() {  # $1=session% $2=week%
  # 末尾那行 composer 是必需的：refresh 会先确认 /usage 真落进 composer 才回车
  printf '   Current session\n   ███   %s%% used\n   Resets %s (Asia/Shanghai)\n\n   Current week (all models)\n   ███   %s%% used\n   Resets %s (Asia/Shanghai)\n❯ /usage\n' "$1" "$PANEL_SESS_RESET" "$2" "$PANEL_WEEK_RESET"
}
# Sequence: a cached 0% frame four times in a row (enough to fool stable-2), with the true
# 95% arriving afterwards.
# 序列：缓存帧 0% 连出 4 次（足够骗过 stable-2），真值 95% 后到
FRAMES=(0 0 0 0 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95 95)
FRAME_COUNTER="$TMP/frame-i"; echo 0 > "$FRAME_COUNTER"
tmux() {   # 只桩 capture-pane，其余调用一律成功
  if [[ "${1:-}" == "capture-pane" ]]; then
    # ⚠️ The counter must live in a FILE: the caller is a $(tmux ...) command substitution
    # running in a subshell, so a variable the stub changes never reaches the parent shell.
    # (The same trap was hit earlier on a different stub.)
    # ⚠️ 计数必须落文件：调用方是 $(tmux ...) 命令替换，跑在子 shell 里，
    # 桩函数改的变量传不回父 shell（早先在另一个桩上踩过同一个坑）。
    local i; i=$(cat "$FRAME_COUNTER" 2>/dev/null || echo 0)
    echo $(( i + 1 )) > "$FRAME_COUNTER"
    mk_panel "${FRAMES[$i]:-95}" 50; return 0
  fi
  return 0
}
_stub_save quota_monitor_alive quota_monitor_dismiss quota_monitor_panel_open \
           quota_monitor_owner_guard quota_account_guard quota_session_created \
           quota_monitor_live_launch_id quota_monitor_single_pane_id quota_snapshot
sleep() { :; }                                  # 采样循环里的 sleep 直接跳过
quota_monitor_alive() { return 0; }
quota_monitor_dismiss() { return 0; }
quota_monitor_panel_open() { return 0; }
quota_monitor_owner_guard() { return 0; }
quota_account_guard() { QUOTA_GUARD_EMAIL="s@x"; QUOTA_GUARD_UUID="u"; return 0; }
quota_session_created() { echo 111; }
quota_monitor_live_launch_id() { echo launch-111; }
quota_monitor_single_pane_id() { echo %1; }
quota_snapshot() { printf '0\tu\ts@x\t0\t\t0\t\n'; }
QUOTA_STATE="$TMP/sample-state.json"
# monitor owner/代际预置成一致，避免走进重启分支（那条路要真等 40s 就绪）
echo '{"monitor_account":"s@x","monitor_uuid":"u","monitor_session_created":111,"monitor_launch_id":"launch-111"}' > "$QUOTA_STATE"
QUOTA_CACHE_MTIME=""
QUOTA_PANEL_LAST=""
if quota_monitor_refresh >/dev/null 2>&1; then
  IFS=$'\t' read -r sm_five sm_week _ _ <<< "$QUOTA_PANEL_LAST"
  if [[ "$sm_five" == "95" ]]; then
    pass "缓存帧 0% 连出 4 次仍取到真值 95%（窗口内取最大，不取第一个稳定的）"
  else
    fail "采样取到 ${sm_five}%，应为 95%——「第一个稳定帧」正是旧规则会收下缓存帧的原因"
  fi
else
  fail "采样整体失败"
fi
# ── Case B: five flat, week advancing / 场景 B：five 持平但 week 前进 ──
# Taking the maximum on `five` alone discards such a frame as "no progress". The weekly
# window is coarser and climbs more slowly, so it is often the one that moves first while
# `five` has not yet ticked over; dropping it delays the weekly observation by a whole
# round.
# 只按 five 取最大会把这种帧当成「没进步」丢掉。周额度粒度更粗、爬得更慢，
# 常常是它先动而 five 还没跳格；漏掉它会让周额度的观测慢一整轮。
FRAMES_W=(10 10 10 10 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13 13)
echo 0 > "$FRAME_COUNTER"
tmux() {
  if [[ "${1:-}" == "capture-pane" ]]; then
    local i; i=$(cat "$FRAME_COUNTER" 2>/dev/null || echo 0)
    echo $(( i + 1 )) > "$FRAME_COUNTER"
    mk_panel 50 "${FRAMES_W[$i]:-13}"; return 0
  fi
  return 0
}
echo '{"monitor_account":"s@x","monitor_uuid":"u","monitor_session_created":111,"monitor_launch_id":"launch-111"}' > "$QUOTA_STATE"
QUOTA_CACHE_MTIME=""; QUOTA_PANEL_LAST=""
if quota_monitor_refresh >/dev/null 2>&1; then
  IFS=$'\t' read -r sw_five sw_week _ _ <<< "$QUOTA_PANEL_LAST"
  if [[ "$sw_week" == "13" ]]; then
    pass "five 持平(50%)但 week 由 10→13 时取到 13（不只按 five 取最大）"
  else
    fail "取到 week=${sw_week}%，应为 13——只按 five 比较会漏掉这类新帧"
  fi
else
  fail "场景 B 采样失败"
fi

unset -f sleep mk_panel; _tmux_guard_install   # 不留裸奔窗口：清桩即重装闸
_stub_restore quota_monitor_alive quota_monitor_dismiss quota_monitor_panel_open \
              quota_monitor_owner_guard quota_account_guard quota_session_created \
              quota_monitor_live_launch_id quota_monitor_single_pane_id quota_snapshot

echo "── 面板解析：必须跳过 Current week (Fable) 那段 ──"
# The fixture is real panel output captured from a live monitor session.
# The first parser took "the first % used after Current week", which picked up the 2% from
# the per-model section and read a weekly 87% as 2% -- that makes "the weekly window is
# nearly full" completely invisible.
# fixture 是从活体监控会话抓的真实面板原文。
# 第一版解析取「Current week 之后第一个 % used」，会抓到按模型分档那段的 2%，
# 把周额度 87% 读成 2% —— 那会让「周额度快满」完全看不见。
if pr=$(quota_panel_parse "$(read_fx usage-panel.txt)"); then
  IFS=$'\t' read -r p_s p_w p_sr p_wr <<< "$pr"
  if [[ "$p_s" == "38" && "$p_w" == "87" ]]; then
    pass "session=38% week=87%（没把 Fable 的 2% 当成周额度）"
  else
    fail "面板数值解析错误（session=$p_s week=$p_w，期望 38/87）"
  fi
  se=$(quota_panel_reset_epoch "$p_sr" || echo "")
  we=$(quota_panel_reset_epoch "$p_wr" || echo "")
  if [[ "$(date -d "@${se:-0}" '+%H:%M')" == "15:29" ]]; then
    pass "session Resets 3:29pm → 本地 15:29"
  else
    fail "session reset 解析错误（got=$(date -d "@${se:-0}" '+%m-%d %H:%M')）"
  fi
  if [[ "$(date -d "@${we:-0}" '+%m-%d %H:%M')" == "08-13 14:59" ]]; then
    pass "week Resets Aug 13, 2:59pm → 08-13 14:59（带日期的形态也认）"
  else
    fail "week reset 解析错误（got=$(date -d "@${we:-0}" '+%m-%d %H:%M')）"
  fi
else
  fail "面板解析整体失败"
fi

echo "── 接受线：周额度只剩一点也要用，不能干等 ──"
# A spent weekly window takes days to come back and waiting buys nothing => the weekly
# accept line must **equal** the switch line, squeezing it to the last point. The moment
# the accept line drops below the switch line you get "there is quota left, yet it decides
# there is nowhere to switch and the whole machine sits waiting".
# The five-hour window is the opposite: it refills in hours, so waiting genuinely pays and
# leaving margin on that side is right.
# 🔴 Upstream wrote this as a comparison of two constants. This repo has no separate accept
#    line constant (see the threshold group), so copying that would read a variable that
#    does not exist. ⇒ Rewritten to test the load-bearing expression directly: a candidate
#    exactly 1 point below on `week` must be accepted.
#    ⭐ That is also slightly stronger than the original -- two constants being equal does
#      not mean the decision actually used either of them.
# 周额度花完要等好几天，干等换不来任何东西 ⇒ 周的接纳线必须**等于**切换线，把它榨到最后
# 一点。接纳线一旦低于切换线，就会出现「手里还有额度却判定无处可切、整台机器停下来等」。
# 五小时相反：几小时自己回血，等待真有收益，所以那一侧留余量是对的。
# 🔴 上游把这条写成两个常量的比较。本仓没有独立的接纳线常量（见「两个窗口各自的阈值」
#    那组的记录），照搬会读到一个不存在的变量。⇒ 改成直接测承重的那个表达式：
#    一个 week 恰好差 1 点的候选必须被接纳。
#    ⭐ 这也比原来那条强一点——常量相等不等于决策真的用了它。
QUOTA_STATE="$TMP/accept-week.json"
printf '{"account":"cur@x","accounts":{"cur@x":{"five":95,"week":10},"lastdrop@x":{"five":10,"week":%s}}}' \
  "$(( QUOTA_SWITCH_PCT_WEEK - 1 ))" > "$QUOTA_STATE"
if [[ "$(quota_switch_pick 'cur@x' || echo none)" == "lastdrop@x" ]]; then
  pass "周额度只剩 1 点的候选仍被接纳（不会出现「还有额度却干等」）"
else
  fail "周额度还剩 1 点的候选被挡在外面，那段额度会被白白等掉"
fi

echo "── capacity 展示层必须容忍 null 字段 ──"
# Hit live: after the ratio accumulator was manually cleared, `cycles` was still present
# while `ratio` had become null, and `null * 100` made the whole capacity command exit with
# an error. That command exists for a person to inspect state, and
# **an abnormal state is exactly when it is most needed** -- letting one null switch off
# the diagnostic tool is the worst possible timing.
# 实撞：手工清零比值累加器后 cycles 还在而 ratio 已 null，
# `null * 100` 让整条 capacity 命令报错退出。它是给人看状态的命令，
# **状态异常时恰恰最需要它还能跑**——一个 null 就把诊断工具关掉是最坏的时机。
QUOTA_STATE="$TMP/nullcap.json"; QUOTA_CACHE_MTIME=""
cat > "$QUOTA_STATE" <<'JSON'
{"account":"n@x","accounts":{"n@x":{"five":10,"week":20}},
 "capacity":{"updated":1786000000,"accounts_known":1,"week_used_total":20,
             "week_remaining_total":80,"five_remaining_total":90,
             "week_remaining_cycles":6.7,"week_five_ratio":null,
             "week_five_ratio_measured":null}}
JSON
# ⚠️ here-string. This one fails in the **false-green** direction: `!` turns a pipeline's
#    141 into true, so when the output really DOES contain an error this still prints PASS.
# ⚠️ here-string。这一条的失效方向是**假绿**：`!` 会把管道的 141 变成真，
#    于是输出里**确实有** error 时这条仍然打 PASS。
if out=$(quota_cmd_capacity 2>&1) && ! grep -qi 'error' <<<"$out"; then
  pass "ratio=null 时 capacity 仍正常输出（不再 null*100 崩掉）"
else
  fail "capacity 在 null 字段上报错：$(printf '%s' "$out" | grep -i error | head -1)"
fi
# ⚠️ Runtime output was translated to English during extraction. The assertion follows the
#    new wording but **guards the same thing**: on degradation it must SAY "unavailable"
#    rather than print a null and leave the reader guessing.
# ⚠️ 运行时输出在抽取时英文化过。断言跟着改文案，但**守的是同一件事**：
#    降级时必须说出「不可用」，而不是打印一个 null 让读的人自己猜。
if grep -q 'ratio unavailable' <<<"$out"; then
  pass "如实说明比值不可用，而不是打印一个 null"
else
  fail "缺少可读的降级说明：$(printf '%s' "$out" | tail -3)"
fi

echo "── 预估额度：外推与它的四道闸 ──"
ES="$TMP/estimate"; mkdir -p "$ES"
QUOTA_STATE="$ES/state.json"; QUOTA_CACHE_MTIME=""; QUOTA_LOG="$ES/quota.log"
_es_state() {  # $1=five $2=fetched_ts $3=burn_five $4=last_switch_ts
  printf '{"five_hour":%s,"seven_day":5,"fetched_ts":%s,"burn_rate_five":%s,"burn_rate_week":0,"last_switch_ts":%s}\n' \
    "$1" "$2" "$3" "$4" > "$QUOTA_STATE"; QUOTA_CACHE_MTIME=""
}
_es_state 50 1000 0.01 0            # 50% + 0.01%/s
V=$(quota_estimate_values 1100)     # 外推 100s → 51
[[ "$V" == "51 5" ]] && pass "按流速外推（50% + 0.01/s × 100s = 51%）" || fail "外推算错，得到 '$V'"
# ⚠️ `lead` must stay within QUOTA_ESTIMATE_MAX_LEAD (=180s), or the "too old to
#    extrapolate" gate catches it first and this case quietly tests something else.
# ⚠️ lead 必须留在 QUOTA_ESTIMATE_MAX_LEAD(=180s) 以内，否则会先被「读数太旧就不外推」
#    那道闸挡掉，这条用例就变成在测另一件事了。
_es_state 85 1000 0.05 0
if quota_estimate_exceeds 1100; then pass "外推越过 90 线时报越线（85 + 0.05/s × 100s = 90）"; else fail "外推已达 90% 却没报越线"; fi
_es_state 85 1000 0.01 0
if quota_estimate_exceeds 1100; then fail "外推才 86% 就报越线"; else pass "外推未到线时不报越线"; fi
# ⚠️ No extrapolation between a switch and the first real reading: the rate at that moment
#    belongs to the **previous account**, and projecting the old account's burn onto the new
#    one demands another switch immediately after the first.
# ⚠️ This started out with lead=600 and passed **for the wrong reason**: 600 hits the "too
#    old to extrapolate" gate first, so it passed whether or not the post-switch gate was
#    even present. Mutation testing exposed it on the spot.
#    ⭐ 一条因为**别的**闸而绿的用例，与一条真正测到东西的用例，输出完全一样。
#    ⭐ A case that goes green because of a DIFFERENT gate is indistinguishable, in its
#      output, from one that actually tested anything.
#    So `lead` stays under 180, leaving the gate under test as the only thing that can make
#    this pass.
# ⚠️ 切号之后、真实读数之前不外推：那一刻的速度属于**上一个账号**，
#    拿旧账号烧得多快去推新账号，会在刚切完就立刻要求再切一次。
# ⚠️ 这条一开始写成 lead=600，结果**因为另一个原因**而绿：600 先撞上「读数超过 180s
#    就不外推」那道闸，于是「切号后不外推」拆没拆都一样通过。变异测试当场戳穿了它。
#    所以 lead 必须留在 180 以内，让这条用例只可能因为要测的那道闸而通过。
_es_state 85 1000 0.05 1050
if quota_estimate_exceeds 1100; then fail "切号后仍用旧账号流速外推 —— 会刚切完就再切"; else pass "切号后到首次真实读数之前不外推"; fi
# ⚠️ Stop extrapolating past the cap: that far out means the query itself is broken, which
#    is a different problem and not one extrapolation should paper over.
# ⚠️ 外推超过上限就停：那说明查询本身坏了，是另一个问题，不该靠外推硬撑。
_es_state 85 1000 0.01 0
if quota_estimate_exceeds $(( 1000 + QUOTA_ESTIMATE_MAX_LEAD + 1 )); then
  fail "读数已过期超过 ${QUOTA_ESTIMATE_MAX_LEAD}s 仍在外推"
else
  pass "读数过期超过上限就停止外推（不拿陈旧基准硬撑）"
fi

echo "── 提前查一次 /usage：触发条件与防抖 ──"
# 🔴 Upstream had three trigger sources: a banner self-report on screen, a concurrency
#    jump, and the estimate crossing the line. The first two read session information from
#    that environment and **were not extracted**, so only the third remains here. Upstream's
#    two assertions about them have **no subject** in this repo and are not migrated -- and
#    deliberately not reshaped into something that happens to pass.
#    ⇒ State the cost plainly: an early query here can only be woken by the extrapolated
#    estimate crossing the line, and the extrapolation itself depends on existing readings.
#    The inflection point where a batch of sessions all start at once -- percentages have
#    not moved yet but are about to spike -- **is invisible to this repo**.
# 🔴 上游有三个触发源：屏上横幅自报、并发骤增、预估已越线。前两个读的是那套环境的会话
#    信息，**未抽取** ⇒ 本仓只剩「预估已越线」这一个。上游那两条断言在本仓**没有对象**，
#    不搬；不改成碰巧能过的形式。
#    ⇒ 代价要说清楚：本仓的提前查询只会被「预估外推越线」叫醒，而外推本身依赖已有读数；
#    「一批会话刚同时开工、百分比还没动但马上要飙」那个拐点，本仓看不见。
FR="$TMP/force-refresh"; mkdir -p "$FR"
QUOTA_STATE="$FR/state.json"; QUOTA_LOG="$FR/quota.log"
_stub_save quota_estimate_exceeds
_fr_state() {  # $1=last_force_ts
  printf '{"force_refresh_last_ts":%s}\n' "$1" > "$QUOTA_STATE"
  : > "$QUOTA_LOG"
}
quota_estimate_exceeds() { return 0; }
_fr_state 0
if quota_refresh_force_due 10000; then
  pass "预估已越线时触发一次提前查询"
else
  fail "预估越线也没触发提前查询"
fi
_fr_state $(( 10000 - QUOTA_FORCE_REFRESH_COOLDOWN + 5 ))
if quota_refresh_force_due 10000; then
  fail "防抖期内仍触发提前查询"
else
  pass "防抖期内不重复提前查询"
fi
# Positive control: with no trigger satisfied it must not fire -- otherwise an "always
# true" implementation passes the first case above too.
# 正控：没有任何触发源成立时必须不触发，否则上面第一条用「恒真」实现也全绿。
_stub_save quota_estimate_exceeds
quota_estimate_exceeds() { return 1; }
_fr_state 0
if quota_refresh_force_due 10000; then
  fail "没有任何触发源成立却仍然提前查询 —— 上面那条是恒真"
else
  pass "正控：没有触发源时不查（上面那条不是恒真）"
fi
_stub_restore quota_estimate_exceeds
# ⚠️ The switch has to actually switch it off.
# ⚠️ 开关必须真能关掉。
_stub_save quota_estimate_exceeds
quota_estimate_exceeds() { return 0; }
_fr_state 0
QUOTA_FORCE_REFRESH=0
if quota_refresh_force_due 10000; then
  fail "QUOTA_FORCE_REFRESH=0 时仍提前查询（没有可回退的后门）"
else
  pass "QUOTA_FORCE_REFRESH=0 时完全关闭提前查询"
fi
QUOTA_FORCE_REFRESH=1
_stub_restore quota_estimate_exceeds
_stub_restore quota_estimate_exceeds

echo "── OAuth 响应解析：空字段不得让后面全部错位 ──"
# ⚠️ 25 samples (about 5%) were lost over three days, all during low-usage periods of the
#    current account.
#    The root cause was NOT an over-strict test, it was **field shift on parse**: a tab is
#    an IFS whitespace character, so `read` collapses consecutive tabs into one separator
#    and one empty field in the middle makes everything after it slide:
#        server sends  0 <empty> 31 <ISO>   is read as  five=0 five_iso=31
#                                                       week=<ISO> week_iso=empty
#    and resets_at is exactly what is empty while a window sits idle (the server does not
#    return a reset time for a window that was never started).
#    The old "all four fields must be numeric" test had been **masking** that shift: it
#    kept the shifted result out, so it never showed up as a wrong NUMBER, only as
#    schema_error.
#    ⭐ 一条过严的判据把「我们解析错了」伪装成了「服务端给的数据不合规」。
#    ⭐ An over-strict test disguised "we parsed it wrong" as "the server sent malformed
#      data" -- and the outcome field said so.
#    ⇒ Fix the parsing (null becomes a "-" placeholder), not the test.
# ⚠️ 三天丢了 25 条样本（约 5%），全在当前账号低用量时段。
#    根因不是判据太严，是**解析错位**：tab 属于 IFS 空白字符，read 会把连续制表符
#    当成一个分隔符，中间字段一空后面全塌：
#        服务端 0 <空> 31 <ISO>  被读成  five=0 five_iso=31 week=<ISO> week_iso=空
#    而 resets_at 恰恰在窗口闲置时就是空的（服务端不返回没启用窗口的重置时刻）。
#    原来那条「四个字段都必须是数字」的判据一直在**掩盖**这个错位 —— 它把错位结果
#    挡在门外，于是从没表现成错误数值，只表现为 schema_error。
#    ⇒ 修解析（null 换 "-" 占位），不是放松判据。
SP="$TMP/schema-parse"; mkdir -p "$SP"
QUOTA_STATE="$SP/state.json"; QUOTA_CACHE_MTIME=""; QUOTA_LOG="$SP/quota.log"
QUOTA_SHADOW_OAUTH_STATE="$SP/sh.json"; QUOTA_SHADOW_OAUTH_EVENTS="$SP/ev.jsonl"
QUOTA_SHADOW_OAUTH_LOCK="$SP/sh.lock"
QUOTA_SHADOW_SCHEDULE_STATE="$SP/sc.json"; QUOTA_SHADOW_SCHEDULE_LOCK="$SP/sc.lock"
_stub_save quota_identity_read quota_shadow_oauth_http_fetch
quota_identity_read() { printf 'a@x\037u1\037u1\n'; }
_sp_try() {  # $1=响应 JSON → 打印 outcome
  printf '%s\n' '{"account":"a@x"}' > "$QUOTA_STATE"; QUOTA_CACHE_MTIME=""
  rm -f "$QUOTA_SHADOW_OAUTH_STATE" "$QUOTA_SHADOW_OAUTH_EVENTS"
  eval "quota_shadow_oauth_http_fetch() { printf '%s' \"\$SP_BODY\" > \"\$1\"; : > \"\$2\"; printf '200'; }"
  SP_BODY="$1" quota_shadow_oauth_sample >/dev/null 2>&1
  [[ -s "$QUOTA_SHADOW_OAUTH_EVENTS" ]] && tail -1 "$QUOTA_SHADOW_OAUTH_EVENTS" | jq -r '.outcome' || echo 无事件
}
if [[ "$(_sp_try '{"five_hour":{"utilization":40,"resets_at":"2030-01-01T05:00:00+00:00"},"seven_day":{"utilization":50,"resets_at":"2030-01-07T00:00:00+00:00"}}')" == "ok" ]]; then
  pass "两窗口齐全 → ok（基准，这条不过后面没意义）"
else
  fail "正常响应都解析不了"
fi
# ⚠️ This IS the bug that was fixed: an idle window has no resets_at and must still be
#    accepted.
# ⚠️ 这条是修的那个 bug 本身：闲置窗口没有 resets_at，必须照常采信。
if [[ "$(_sp_try '{"five_hour":{"utilization":0},"seven_day":{"utilization":31,"resets_at":"2030-01-07T00:00:00+00:00"}}')" == "ok" ]] \
   && [[ "$(quota_state_get '.seven_day' '')" == "31" ]]; then
  pass "五小时窗口闲置(0%)、无 resets_at → 照常采信，周额度没被连坐丢掉"
else
  fail "闲置窗口仍被判成格式错误（三天丢 25 条的原因）"
fi
# ⚠️ Positive control: relaxing must not become accepting everything. Non-zero utilisation
#    with no resets_at is genuinely malformed -- the server ought to know when it resets --
#    and must still be rejected, or the gate has effectively been removed.
# ⚠️ 正控：放宽不能变成一律放行。使用率不为 0 却没有 resets_at，服务端本该知道
#    何时重置，那是真的畸形，必须仍然拒绝 —— 否则这条闸等于拆了。
if [[ "$(_sp_try '{"five_hour":{"utilization":40},"seven_day":{"utilization":50,"resets_at":"2030-01-07T00:00:00+00:00"}}')" == "schema_error" ]]; then
  pass "使用率不为 0 却缺 resets_at → 仍判畸形（放宽没变成一律放行）"
else
  fail "真畸形响应也被收下了 —— 判据被拆掉了"
fi
if [[ "$(_sp_try '{"five_hour":{"resets_at":"2030-01-01T05:00:00+00:00"},"seven_day":{"utilization":50,"resets_at":"2030-01-07T00:00:00+00:00"}}')" == "schema_error" ]]; then
  pass "缺 utilization → 判畸形（决策要用的就是它）"
else
  fail "缺使用率也被收下"
fi
_stub_restore quota_identity_read quota_shadow_oauth_http_fetch

echo "── 台账多上游共写：谁的观测新用谁的 ──"
# ⚠️ The ledger has two upstreams (the /usage panel and OAuth). "Which one is
#    authoritative" was dissolved by the architecture -- arbitration is by observation time
#    alone. That came from measurement: across ten days of logs the panel went blind under
#    rate limiting 27 times, 22 of them (81%) with five>=85%, median 6.4 minutes, the worst
#    running from 91% straight to 100%. Approaching the threshold the panel tightens to
#    60s, and **asking more often is what gets you limited** -- so its sampling density
#    collapses exactly when it is most needed. The OAuth line is fixed at 180s and does not
#    collapse. ⇒ The two do not fail at the same times; in parallel beats in series.
# ⚠️ 台账有两个上游（/usage 面板、OAuth）。「谁当主」这个问题被架构消掉了 ——
#    只按观测时刻定胜负。这样做有实测依据：翻 10 天日志，面板因限流失明 27 次，
#    其中 22 次（81%）发生在 five>=85% 的危险区，失明中位 6.4 分钟；最要命一次从 91%
#    一路瞎到 100%。面板逼近阈值时收紧到 60s，**问得越勤越容易被限流**，
#    密度恰好在最需要的时候塌掉。OAuth 固定 180s 不塌。
#    ⇒ 两个上游失败时机不重合，并联比串联强。
UP="$TMP/upstream"; mkdir -p "$UP"
QUOTA_STATE="$UP/state.json"; QUOTA_CACHE_MTIME=""; QUOTA_LOG="$UP/quota.log"
_up_reset() {
  printf '%s\n' '{"account":"cur@x","five_hour":50,"seven_day":20,"fetched_ts":1000,
   "accounts":{"cur@x":{"five":50,"week":20,"checked_ts":1000,"source":"usage_panel"}}}' > "$QUOTA_STATE"
  QUOTA_CACHE_MTIME=""
}
_up_reset
quota_reading_apply oauth_api 1200 cur@x 66 22; _rc=$?; QUOTA_CACHE_MTIME=""
if (( _rc == 0 )) && [[ "$(quota_state_get '.five_hour' '')" == "66" ]] \
   && [[ "$(quota_state_get '.reading_source' '')" == "oauth_api" ]]; then
  pass "更新的观测写入并改写顶层决策字段，来源标成 oauth_api"
else
  fail "新观测没写进去（rc=$_rc five=$(quota_state_get '.five_hour' '')）"
fi
# ⚠️ This is the crux: an older observation must **never** overwrite a newer one. The two
#    upstreams run on their own cadences, so late arrivals are certain; without this the
#    ledger oscillates between old and new values and the switch decision jitters with it.
# ⚠️ 这条是要害：旧观测**绝不能**覆盖新的。两个上游各按自己的节拍跑，迟到的包一定会
#    出现；不挡住的话台账会在新旧值之间来回跳，切号判据跟着抖。
quota_reading_apply oauth_api 900 cur@x 11 11; _rc=$?; QUOTA_CACHE_MTIME=""
if (( _rc == 2 )) && [[ "$(quota_state_get '.five_hour' '')" == "66" ]]; then
  pass "更旧的观测被拒（rc=2），台账不回退"
else
  fail "旧观测覆盖了新值 —— 台账会在新旧之间来回跳（rc=$_rc five=$(quota_state_get '.five_hour' '')）"
fi
# ⚠️ A non-current account updates only its own slot. Top-level .five_hour means "how much
#    the **current** account has left"; writing someone else's number there switches on the
#    wrong level, directly.
# ⚠️ 非当前账号只更新自己那格。顶层 .five_hour 的语义是「**当前**账号还剩多少」，
#    把别人的数写进去会直接按错误水位切号。
quota_reading_apply oauth_api 1300 other@x 3 4; _rc=$?; QUOTA_CACHE_MTIME=""
if (( _rc == 0 )) && [[ "$(quota_state_get '.five_hour' '')" == "66" ]] \
   && [[ "$(quota_state_get '.accounts["other@x"].five' '')" == "3" ]]; then
  pass "写非当前账号只落到它自己那格，顶层纹丝不动"
else
  fail "写别的账号污染了顶层决策字段（顶层 five=$(quota_state_get '.five_hour' '')）"
fi
# ⚠️ Positive control: all three cases above could "pass by accident" simply because the
#    function never took effect at all. This confirms the rejection really hangs on the
#    **observation time** and is not an unconditional refusal -- the same account with a
#    newer timestamp must be writable again.
# ⚠️ 正控：上面三条都可能因为函数压根没生效而「碰巧通过」。这里确认拒绝逻辑
#    真的挂在**观测时刻**上，而不是恒拒——同一账号、更新的时刻，必须能再写进去。
quota_reading_apply oauth_api 1400 cur@x 71 23; _rc=$?; QUOTA_CACHE_MTIME=""
if (( _rc == 0 )) && [[ "$(quota_state_get '.five_hour' '')" == "71" ]]; then
  pass "再来一个更新的观测仍能写入（拒绝逻辑没退化成恒拒）"
else
  fail "新观测也被拒了 —— 闸恒拒等于把这条上游整个关掉"
fi
_up_reset

echo "── 回血盯梢：过点才查，查到就停 ──"
# ⚠️ The test has to be **structural**: "snapshot taken < reset moment <= now" means what
#    we hold was taken before it reset.
#    Not "usage dropped below N" -- that needs a threshold, and an account can be used down
#    again right after resetting, so a threshold test reads that as "has not reset yet" and
#    keeps querying forever, never stopping.
# ⚠️ 判据必须是**结构性**的：「快照拍摄时刻 < 回血时刻 <= 现在」＝手上这份是回血前拍的。
#    不能用「额度掉到多少以下」——那要挑一个阈值，而账号回血后可能立刻被别人用掉一截，
#    阈值判据会判成「还没回血」然后一直查下去，停不了。
WT="$TMP/watch"; mkdir -p "$WT"
QUOTA_SNAPSHOT_FILE="$WT/snap.json"
_WT_NOW=1787320000; _WT_RESET=$(( _WT_NOW - 600 ))
_wt_snap() {  # $1=快照拍摄时刻 $2=other 的 five_reset
  cat > "$QUOTA_SNAPSHOT_FILE" <<JSON
{"generated_at":$1,"accounts":[
 {"email":"cur@x","status":"active","is_current":true,"five_reset":$_WT_RESET,"week_reset":null},
 {"email":"other@x","status":"active","is_current":false,"five_reset":$2,"week_reset":null}]}
JSON
}
_wt_snap $(( _WT_RESET - 300 )) "$_WT_RESET"
if quota_reset_watch_pending "$_WT_NOW"; then
  pass "快照拍于回血前、现已过点 → 进入盯梢"
else
  fail "该盯没盯（后面几条就没意义了）"
fi
_wt_snap $(( _WT_RESET + 60 )) "$_WT_RESET"
if quota_reset_watch_pending "$_WT_NOW"; then
  fail "已经查到回血后的读数却还在盯 —— 停不下来，会一直烧请求"
else
  pass "查到回血后的读数 → 盯梢自动停"
fi
_wt_snap $(( _WT_NOW - 100 )) $(( _WT_NOW + 3600 ))
if quota_reset_watch_pending "$_WT_NOW"; then
  fail "回血时刻还没到就在盯 —— 白烧请求"
else
  pass "没到回血时刻不盯"
fi
# ⚠️ The current account should not be watched: the /usage panel and the 180s shadow
#    sampler already cover it, so a third path is duplication.
# ⚠️ 当前账号不该开盯梢：它由 /usage 面板和 180s 影子采样各自覆盖，再开一路是重复。
_wt_snap $(( _WT_RESET - 300 )) null
if quota_reset_watch_pending "$_WT_NOW"; then
  fail "为当前账号也开了盯梢（重复覆盖，白烧请求）"
else
  pass "只盯非当前账号"
fi

echo "── 面板失灵时 OAuth 顶上：三道闸都得能拒 ──"
# ⚠️ As it stands, an unreadable panel returns 1 for the whole round and updates nothing.
#    Sustained failure leaves the script holding an ever-older number **without being able
#    to tell that it is blind**. The OAuth line samples the current account independently
#    every 180s and covers exactly that gap -- but it must pass three gates, none optional.
# ⚠️ 现状是面板读不到就整轮 return 1，一个数都不更新；持续失灵会让脚本拿着越来越旧的数，
#    而且**看不出自己在瞎**。OAuth 那条线每 180s 独立采当前账号，正好补这个缺口。
#    但它必须过三道闸，一道都不能省。
FB="$TMP/fallback"; mkdir -p "$FB"
QUOTA_SHADOW_OAUTH_STATE="$FB/shadow.json"
QUOTA_STATE="$FB/state.json"; QUOTA_CACHE_MTIME=""; QUOTA_LOG="$FB/quota.log"
_FB_NOW=1787320000
_fb_setup() {  # $1=采样账号 $2=观测时刻
  printf '%s\n' '{"account":"cur@x","five_hour":50,"seven_day":20,"accounts":{}}' > "$QUOTA_STATE"
  QUOTA_CACHE_MTIME=""; : > "$QUOTA_LOG"
  cat > "$QUOTA_SHADOW_OAUTH_STATE" <<JSON
{"last_attempt":{"outcome":"ok","observed_at":$2,
 "account":{"email":"$1"},
 "windows":{"five_hour":{"used_percentage":77},"seven_day":{"used_percentage":33}}}}
JSON
}
_fb_setup "cur@x" "$(( _FB_NOW - 60 ))"
if quota_oauth_fallback_apply "$_FB_NOW" "cur@x" \
   && [[ "$(quota_state_get '.five_hour' '')" == "77" ]] \
   && [[ "$(quota_state_get '.reading_source' '')" == "oauth_fallback" ]]; then
  pass "身份对、够新 → 顶上，并标明来源是 oauth_fallback"
else
  fail "该顶没顶上（five=$(quota_state_get '.five_hour' '') source=$(quota_state_get '.reading_source' '')）"
fi
# ⚠️ Gate 1: an identity mismatch is unusable. That is **somebody else's quota**; using it
#    as your own switches to the wrong account.
# ⚠️ 闸一：身份不符绝不能用。那是**别人的额度**，拿来当自己的会切错号。
_fb_setup "someone_else@x" "$(( _FB_NOW - 60 ))"
if quota_oauth_fallback_apply "$_FB_NOW" "cur@x"; then
  fail "拿了别的账号的额度顶替当前账号 —— 会据此切错号"
else
  pass "采样账号与当前不一致 → 拒绝顶替"
fi
# ⚠️ Gate 2: a stale reading is more dangerous than none -- it makes the script believe it
#    can see.
# ⚠️ 闸二：陈旧读数比没有更危险，会让脚本以为自己看得见。
_fb_setup "cur@x" "$(( _FB_NOW - QUOTA_OAUTH_FALLBACK_MAX_AGE - 1 ))"
if quota_oauth_fallback_apply "$_FB_NOW" "cur@x"; then
  fail "拿超期读数顶替 —— 脚本会以为自己看得见，其实在瞎"
else
  pass "采样超过 ${QUOTA_OAUTH_FALLBACK_MAX_AGE}s → 拒绝顶替"
fi
# ⚠️ Nor when the sample itself failed (outcome is not ok).
# ⚠️ 采样本身失败时也不能用（outcome 不是 ok）
_fb_setup "cur@x" "$(( _FB_NOW - 60 ))"
printf '%s\n' '{"last_attempt":{"outcome":"rate_limited","observed_at":'"$(( _FB_NOW - 60 ))"',"account":{"email":"cur@x"},"windows":{}}}' > "$QUOTA_SHADOW_OAUTH_STATE"
if quota_oauth_fallback_apply "$_FB_NOW" "cur@x"; then
  fail "拿一次失败的采样当读数用"
else
  pass "采样 outcome 不是 ok → 拒绝顶替"
fi

echo "── 账号额度快照：陈旧的必须当作没有 ──"
# ⚠️ The dangerous failure mode of this path is not "cannot read" but **reading an old one
#    and treating it as current**: ranking candidates on half-hour-old numbers switches to
#    an account that is in fact already full, walks straight into the wall, and burns a
#    switch allowance and a debounce window for nothing.
#    Better to report "no snapshot" than to hand out expired data.
# ⚠️ 这条路的危险失败模式不是「读不到」，而是**读到一份旧的却当成新的**：
#    拿半小时前的额度排候选，会切到一个其实早就满了的账号，切过去立刻撞墙，
#    还白白消耗一次切号配额和防抖窗口。宁可判定「没有快照」，也不交出过期数据。
SN="$TMP/snapshot"; mkdir -p "$SN"
QUOTA_SNAPSHOT_FILE="$SN/snap.json"
QUOTA_STATE="$SN/state.json"; QUOTA_CACHE_MTIME=""; QUOTA_LOG="$SN/quota.log"
printf '%s\n' '{"account":"live1@x","accounts":{"live1@x":{"five":50,"week":20}}}' > "$QUOTA_STATE"
_snap_write() {  # $1=generated_at
  cat > "$QUOTA_SNAPSHOT_FILE" <<JSON
{"schema":1,"generated_at":$1,"current_account":"live1@x","accounts":[
 {"email":"live1@x","status":"active","five_hour":50,"seven_day":20,"five_reset":null,"week_reset":null,"outcome":"ok"},
 {"email":"live2@x","status":"active","five_hour":3,"seven_day":8,"five_reset":null,"week_reset":null,"outcome":"ok"}]}
JSON
}
_SN_NOW=1787300000
_snap_write "$_SN_NOW"
if quota_snapshot_read "$_SN_NOW" >/dev/null; then
  pass "新鲜快照可读"
else
  fail "新鲜快照被误判为不可用（后面几条就没意义了）"
fi
_snap_write "$(( _SN_NOW - QUOTA_SNAPSHOT_MAX_AGE - 1 ))"
if quota_snapshot_read "$_SN_NOW" >/dev/null; then
  fail "超过 ${QUOTA_SNAPSHOT_MAX_AGE}s 的陈旧快照仍被交出去 —— 会拿旧额度排候选"
else
  pass "陈旧快照判定为不可用（不交出过期数据）"
fi
# ⚠️ A timestamp in the FUTURE must be rejected too. A clock jump, or somebody writing the
#    file badly, makes `age` come out negative -- and a check that only tests "too old"
#    waves that obviously broken data straight through.
# ⚠️ 未来时刻同样要拒。时钟跳变或别人写坏文件时，age 会算成负数；
#    只判「太旧」的写法会让这种明显异常的数据一路绿灯通过。
_snap_write "$(( _SN_NOW + 3600 ))"
if quota_snapshot_read "$_SN_NOW" >/dev/null; then
  fail "生成时刻在未来的快照被接受 —— 只判『太旧』漏掉了时钟异常这一半"
else
  pass "生成时刻在未来的快照也拒绝"
fi
: > "$QUOTA_SNAPSHOT_FILE"
if quota_snapshot_read "$_SN_NOW" >/dev/null; then fail "空快照被接受"; else pass "空快照判定为不可用"; fi


echo "── 对账日志只在内容变化时记，不逐行心跳 ──"
# ⚠️ Upstream had two halves here: a sweep-frequency gate (capturing every session's
#    screen, not extracted => that half has no subject) and reconciliation-log dedup. Only
#    the latter came across; it has nothing to do with that environment.
# ⚠️ When decisions moved to every 10s, the reconciliation log went from one line a minute
#    to one every 10s -- 2183 lines a day. A per-line heartbeat buries the actual changes,
#    and changes are the entire point of reconciling.
#    ⇒ The gate lives **inside the function**, not at the call site: then every future
#    caller is protected without having to remember.
# ⚠️ 上游这一组原本两半：巡扫频率闸（对全部会话逐个抓屏，未抽取 ⇒ 那半没有对象）
#    与对账日志去重。搬过来的是后一半，它与那套环境无关。
# ⚠️ 决策拆成每 10s 一拍时，对账日志从每分钟一条变成每 10s 一条，最多每天 2183 行。
#    一份逐行心跳会把真正的变化埋掉，而对账要看的恰恰是变化。
#    ⇒ 闸放在**函数内部**而不是调用点：以后谁调都受保护，不靠调用方记得。
NZ="$TMP/noise"; mkdir -p "$NZ"
QUOTA_STATE="$NZ/state.json"; QUOTA_LOG="$NZ/quota.log"
QUOTA_SNAPSHOT_FILE="$NZ/snap.json"
_NZ_NOW=1787320000
printf '%s\n' '{"account":"cur@x","accounts":{"o@x":{"five":9,"week":9}}}' > "$QUOTA_STATE"
_nz_snap() { printf '{"generated_at":%s,"accounts":[{"email":"o@x","status":"active","is_current":false,"five_hour":%s,"seven_day":9,"five_reset":null,"week_reset":null}]}' "$1" "$2" > "$QUOTA_SNAPSHOT_FILE"; }
: > "$QUOTA_LOG"
for _i in $(seq 0 11); do _nz_snap "$(( _NZ_NOW + _i * 10 ))" 20; quota_snapshot_shadow_compare "$(( _NZ_NOW + _i * 10 ))" >/dev/null 2>&1; done
if [[ "$(grep -c '🔎' "$QUOTA_LOG")" == "1" ]]; then
  pass "数值没变时 12 拍只记 1 条对账（不再逐行心跳）"
else
  fail "记了 $(grep -c '🔎' "$QUOTA_LOG") 条 —— 心跳会把真正的变化埋掉"
fi
# ⚠️ Positive control: saving log lines must not become missing changes. The moment a
#    value changes it has to be recorded -- changes are the whole point of reconciling.
# ⚠️ 正控：省日志不能变成漏掉变化。数值一变必须立刻记 —— 对账的全部意义就在变化上。
_nz_snap "$(( _NZ_NOW + 200 ))" 55
quota_snapshot_shadow_compare "$(( _NZ_NOW + 200 ))" >/dev/null 2>&1
if [[ "$(grep -c '🔎' "$QUOTA_LOG")" == "2" ]]; then
  pass "数值一变立刻记（去重没变成漏报）"
else
  fail "数值变了却没记 —— 去重把真信号也吃掉了"
fi

echo "── 快照现阶段只记账，不参与决策 ──"
# ⚠️ Gather evidence before promoting it. The existing consistency evidence (within ±60s
#    the values differ by <=2 points, 98% success) comes **entirely from shadow sampling of
#    the CURRENT account**; querying other accounts is a different code path (different
#    token, different credential file) and only a handful of manual probes back it.
#    ⭐ 证据的适用面不会随使用场景自动扩大。
#    ⭐ Evidence does not widen its scope just because you want to use it somewhere else.
#    So: run it in shadow, reconcile, and do not let it change behaviour yet.
# ⚠️ 放行前必须先攒证据。已有的一致性证据（±60s 内差 ≤2 点、98% 成功率）**全部来自
#    当前账号**的影子采样；查其他账号是另一条代码路径（不同 token、不同凭据文件），
#    目前只有几次手动 probe 的证据。所以先影子跑、对账，别急着让它改变行为。
_snap_write "$_SN_NOW"
_before=$(cat "$QUOTA_STATE")
: > "$QUOTA_LOG"
quota_snapshot_shadow_compare "$_SN_NOW" >/dev/null 2>&1
if [[ "$(cat "$QUOTA_STATE")" == "$_before" ]]; then
  pass "影子对账没有改动任何状态"
else
  fail "影子对账改了状态 —— 它现在只该记账"
fi
# ⚠️ Runtime output was translated during extraction; the assertion follows the new wording
#    and still guards the same thing -- reconciliation must **leave a side-by-side record**,
#    or the "state did not change" above could equally mean it never ran.
# ⚠️ 运行时输出在抽取时英文化过；断言跟着改文案，守的仍是同一件事——
#    对账必须**留下一条并排记录**，否则上面那条「状态没变」也可能只是因为它压根没跑。
if grep -q 'shadow: reconciliation only, never decides' "$QUOTA_LOG"; then
  pass "影子对账把快照与台账并排记了一笔（上一条不是因为它压根没跑）"
else
  fail "影子对账没产生记录：$(tail -1 "$QUOTA_LOG")"
fi
if [[ "$QUOTA_SNAPSHOT_DECIDE" == "0" ]]; then
  pass "放行开关默认关闭（QUOTA_SNAPSHOT_DECIDE=0）"
else
  fail "快照默认就参与决策了 —— 证据还不够，不该默认开"
fi

}

# ── the isolation gate, checked after every layer / 隔离闸，每一层跑完都查 ──
# ⚠️ Upstream this lived at the very end of the slow layer, so `--fast` alone never
#    checked it. The gate guards the 2026-08-19 incident (the regression reached into
#    production sessions), and "which layer did you run" is not a sensible input to
#    whether that check happens.
# ⚠️ 上游这一组在慢层末尾，于是单跑 --fast 从不检查它。这道闸守的是 2026-08-19
#    「回归伸手动了生产会话」，而「你跑的是哪一层」不该是「这个检查做不做」的输入。
run_isolation_check() {
echo "── 隔离闸：整轮回归不得触达真实 tmux ──"
# ⚠️ 守的是 2026-08-19 那次「测试动了生产会话」。统计的是**会改变状态**的调用
#    （send-keys / kill-session / new-session …）有没有漏到闸外。
if [[ ! -s "$TMUX_VIOLATIONS" ]]; then
  pass "全程没有未打桩的危险 tmux 调用（send-keys/kill/new-session 等）"
else
  fail "有 $(grep -c . "$TMUX_VIOLATIONS") 次危险调用漏到闸外：$(head -3 "$TMUX_VIOLATIONS" | tr '\n' ' ')"
fi
# ⚠️ Positive control: the gate has to be able to go red. Trip it deliberately once and
#    confirm it is recorded -- otherwise the assertion above is permanently green and
#    tests nothing.
# ⚠️ 正控：闸必须真的会红。故意触发一次，确认它记得下来——否则上面那条恒绿，等于没测。
_tmux_probe="$TMP/tmux-violations.snapshot"
cp "$TMUX_VIOLATIONS" "$_tmux_probe"
tmux send-keys -t __fake_probe_session__ Escape >/dev/null 2>&1 || true
if (( $(grep -c . "$TMUX_VIOLATIONS") > $(grep -c . "$_tmux_probe") )); then
  pass "闸在故意触发时确实记录了违规（上一条不是恒绿）"
else
  fail "闸抓不住 send-keys —— 上一条断言没有区分度"
fi
cp "$_tmux_probe" "$TMUX_VIOLATIONS"
}

# ── the switch itself: verify, then fence / 切号本身：先回读，再挪 fence ──
run_switch_tests() {

echo "── 切号成功判据：账号必须真的变了，且身份 fence 必须跟着挪 ──"
# ⚠️ Upstream tested the switch entry point: after switching, **read the identity back**,
#    fail if the email does not match or the UUID did not change, and once success is
#    confirmed move account_guard's expected identity to the new account.
#    That third item looks like bookkeeping and is in fact functional: the identity guard
#    treats `expected` as a persistent expectation and re-reads it at every decision
#    boundary. A successful switch with `expected` still pointing at the old account means
#    the very next beat sees actual != expected, judges account-drift, fails closed --
#    and **never recovers by itself**, because expected is never updated.
#    ⭐ That is exactly the shape of a three-hour outage: the switch itself SUCCEEDED; what
#    was stuck was every reading after it. The guard also writes an `external` line to the
#    ledger, recording what this machine did itself as something an outsider did.
# ⚠️ 上游这一组测的是切号入口：切完**回读一次身份**，邮箱不符或 UUID 没变一律判失败，
#    并且在确认成功之后把 account_guard 的 expected 身份挪到新账号。
#    第三件事看着像记账，其实是功能性的：身份守卫拿 expected 当持久期望值，每个决策边界
#    都重读。切号成功而 expected 还停在旧账号 ⇒ 下一拍守卫看到 actual≠expected，
#    判 account-drift、fail closed，而且**再也不会自己好**（expected 永远不更新）。
#    ⭐ 那正是一次停摆三小时的形状：切号本身成功了，卡死的是它之后的每一次读数。
#    而且守卫还会往流水账写一条 external，把这台机器自己干的事记成外人干的。
SW="$TMP/switch"; mkdir -p "$SW"
QUOTA_STATE="$SW/state.json"; QUOTA_LOG="$SW/quota.log"; QUOTA_SWITCH_LEDGER="$SW/switches.jsonl"
export QUOTA_CLAUDE_JSON="$SW/claude.json"
SW_TOOL="$SW/fake-account-switch"
_sw_setup() {   # $1=切号工具切完之后写进配置文件的邮箱 $2=uuid
  cat > "$SW_TOOL" <<TOOL
#!/bin/bash
# ⚠️ Drain stdin first, exactly like the real tool does with \`--use -\`.
#    A fake that exits without reading leaves the caller's \`printf\` writing into a
#    closed pipe: SIGPIPE, and under \`set -o pipefail\` the caller sees rc=141 instead
#    of 0 — so a switch that succeeded is reported as failed, intermittently, depending
#    on scheduling. That is the same SIGPIPE-under-pipefail shape this suite guards for
#    in the detectors; here it was the **test harness** producing it.
cat >/dev/null
cat > "$QUOTA_CLAUDE_JSON" <<JSON
{"oauthAccount":{"emailAddress":"$1","accountUuid":"$2"},
 "cachedUsageUtilization":{"accountUuid":"$2"}}
JSON
exit 0
TOOL
  chmod +x "$SW_TOOL"
  cat > "$QUOTA_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"cur@x","accountUuid":"uuid-cur"},
 "cachedUsageUtilization":{"accountUuid":"uuid-cur"}}
JSON
  cat > "$QUOTA_STATE" <<JSON
{"account":"cur@x","fetched_ts":$(date +%s),
 "account_guard":{"expected_email":"cur@x","expected_uuid":"uuid-cur"},
 "accounts":{"cur@x":{"five":95,"week":10},"free@x":{"five":5,"week":5}}}
JSON
  : > "$QUOTA_LOG"; : > "$QUOTA_SWITCH_LEDGER"
}
QUOTA_ACCOUNT_SWITCH_BIN="$SW_TOOL"
QUOTA_SWITCH_MODE=on

# ① Happy path: the switching tool really did change the account to free@x.
# ① 正常路径：切号工具真把账号换成了 free@x
_sw_setup 'free@x' 'uuid-free'
quota_decide_once "$(date +%s)" >/dev/null 2>&1
_sw_kind=$(jq -r '.kind' "$QUOTA_SWITCH_LEDGER" 2>/dev/null | tail -1)
_sw_exp=$(quota_state_get '.account_guard.expected_email' '')
if [[ "$_sw_kind" == "auto" ]]; then
  pass "切号成功记 auto 一条"
else
  fail "切号成功却没记 auto（kind=$_sw_kind）"
fi
if [[ "$_sw_exp" == "free@x" ]]; then
  pass "身份 fence 跟着挪到新账号（expected_email=free@x）"
else
  fail "fence 还停在 [$_sw_exp]——下一拍守卫会判 account-drift，而且再也不会自己好"
fi
# ⭐ Test the CONSEQUENCE, not just the field: after a switch the guard must still pass.
# ⭐ 直接把后果测出来，而不是只测那个字段：切完之后守卫必须照常放行。
if quota_account_guard "post-switch" >/dev/null 2>&1; then
  pass "切完之后守卫照常放行（切号没有把自己锁死）"
else
  fail "切号成功之后守卫立刻 fail closed：$(quota_state_get '.poll.last_error' '')"
fi
# ⭐ And it must not record what it did itself as something an outsider did.
# ⭐ 而且不该把自己干的事记成外人干的。
if ! grep -q '"external"' "$QUOTA_SWITCH_LEDGER"; then
  pass "流水账里没有把本次自动切号误记成 external"
else
  fail "本工具自己切的号被记成了 external —— 读账本的人会去查一个不存在的外部 writer"
fi

# ② The tool returns 0 but the account **did not change at all** (a backup restore, or a
#   concurrent write overwriting it, both look like this).
# ② 切号工具返回 0，但账号**根本没换**（备份恢复、写入被并发盖回都会这样）
_sw_setup 'cur@x' 'uuid-cur'
quota_decide_once "$(date +%s)" >/dev/null 2>&1
_sw_kind2=$(jq -r '.kind' "$QUOTA_SWITCH_LEDGER" 2>/dev/null | tail -1)
if [[ "$_sw_kind2" != "auto" ]]; then
  pass "正控：工具报成功但身份没变 → 不宣称切号成功（kind=$_sw_kind2）"
else
  fail "只看退出码就宣称切成了 —— 身份根本没变（这会让 fence 挪到一个假身份上）"
fi

# ③ The email claims to have changed while the UUID did not: the identity is not
#   trustworthy and this must fail closed.
# ③ 邮箱声称已换、UUID 却没变：身份不可信，必须 fail closed
_sw_setup 'free@x' 'uuid-cur'
quota_decide_once "$(date +%s)" >/dev/null 2>&1
_sw_kind3=$(jq -r '.kind' "$QUOTA_SWITCH_LEDGER" 2>/dev/null | tail -1)
if [[ "$_sw_kind3" != "auto" ]]; then
  pass "正控：邮箱变了但 UUID 没变 → 判身份不可信，不宣称成功（kind=$_sw_kind3）"
else
  fail "邮箱对了就放行 —— 双 UUID 裂开的假身份会被当成切号成功"
fi

QUOTA_SWITCH_MODE=dry-run
unset QUOTA_CLAUDE_JSON
}

# ── candidate ranking / 候选排序与筛选 ──
run_candidate_tests() {
CR_NOW=$(date +%s)
QUOTA_STATE="$TMP/candidates.json"

echo "── 候选排序：周额度剩得多的先用 ──"
# The strategy is "serial on the five-hour window, greedy on weekly quota when choosing an
# account". The five-hour window comes back on its own within hours; weekly quota waits for
# the weekly reset and is the scarce dimension. Ranking on it lets weekly usage even out
# passively, while being serial keeps several accounts from climbing to the ceiling
# together.
# ⚠️ Upstream tested the **attempt order** of a retry chain that tried candidates until one
#    succeeded. This repo has no such chain -- quota_switch_pick takes the first usable
#    candidate. ⇒ Rewritten to test the ranking function's output sequence directly, which
#    is what upstream's ordering assertion was really testing.
# 策略是「五小时窗口上串行、挑账号时贪心在周额度上」。五小时窗口几小时自己回来，周额度
# 要等周重置，是稀缺的那一维；按它排序能让周额度被动趋于均衡，同时串行本身保证几个账号
# 不会齐头并进同时撞顶。
# ⚠️ 上游测的是那条重试链的**尝试顺序**（逐个试到成功为止）。本仓没有那条重试链——
#    quota_switch_pick 只挑第一个可用的。⇒ 改成直接测排序函数的输出序列，
#    那正是上游那条顺序断言真正在测的东西。
cat > "$QUOTA_STATE" <<JSON
{"account":"cur@x","accounts":{
  "hi@x":{"five":10,"week":90},
  "lo@x":{"five":10,"week":30},
  "mid@x":{"five":10,"week":60},
  "nodata@x":{"five":null,"week":null}}}
JSON
_order=$(quota_switch_ranked_candidates | cut -f1 | tr '\n' ' ')
if [[ "$_order" == "lo@x mid@x hi@x " ]]; then
  pass "按周额度升序：lo(30%) → mid(60%) → hi(90%)"
else
  fail "候选顺序错误（实际：${_order:-无}）"
fi
if [[ "$_order" != *"nodata@x"* ]]; then
  pass "没有读数的账号不进候选（不是排最后，是压根不排——排它等于拿未知当 0%）"
else
  fail "把一个没有任何读数的账号排进了候选"
fi
# Positive control: with equal weekly quota the five-hour value is the secondary key --
# otherwise "sorted by week" could just be an order that happened to come out right.
# 正控：周额度相同时用五小时做次键，否则「按周排序」也可能只是碰巧顺序对。
cat > "$QUOTA_STATE" <<'JSON'
{"account":"cur@x","accounts":{
  "b@x":{"five":80,"week":50},
  "a@x":{"five":20,"week":50}}}
JSON
if [[ "$(quota_switch_ranked_candidates | cut -f1 | tr '\n' ' ')" == "a@x b@x " ]]; then
  pass "正控：周额度打平时按五小时做次键（排序真的两键都用了）"
else
  fail "周额度打平时次键没生效"
fi

echo "── 候选筛选：坏的 reset 存值不得把可用账号挡在候选外 ──"
# ⚠️ Hit live upstream: an account's five_reset had been written by older day-rollover code
#    as nine hours away (impossible for a five-hour window), so it was treated as "known
#    full and not yet reset" and skipped. The candidate set went empty, and three
#    consecutive triggers all concluded "every account is rate limited" -- while the
#    current account was already at 100%.
# 🔴 That defect is **structurally impossible** here: quota_switch_ranked_candidates looks
#    only at the two percentages and never reads a reset at all. This is pinned as an
#    ASSERTION rather than treated as "already fixed" -- the moment somebody adds a reset
#    test to candidate filtering, this goes red and puts the original incident's reasoning
#    in front of them.
# ⚠️ 上游实撞：某账号的 five_reset 是旧代码跨日回卷写下的 9 小时后（五小时窗口不可能），
#    于是被当成「已知满且尚未重置」跳过；候选为空 → 三次触发全部直接判「全账号撞限」，
#    而当前账号已经 100%。
# 🔴 本仓这条缺陷**结构上不可能**：quota_switch_ranked_candidates 只看 five/week 两个
#    百分比，根本不读 reset。这里把它钉成断言，而不是当成「已经修好了」——一旦以后有人
#    往候选筛选里加 reset 判断，这条会立刻红，并把当年那次事故的理由摆在他面前。
cat > "$QUOTA_STATE" <<JSON
{"account":"cur@x","accounts":{
  "badreset@x":{"five":10,"week":20,"five_reset":$(( CR_NOW + 32400 )),"week_reset":$(( CR_NOW + 200000 ))},
  "sane@x":{"five":10,"week":30,"five_reset":$(( CR_NOW + 1800 )),"week_reset":$(( CR_NOW + 200000 ))}}}
JSON
if [[ "$(quota_switch_pick 'cur@x')" == "badreset@x" ]]; then
  pass "reset 存值超出 5h 视界的账号仍进候选（候选筛选不消费 reset）"
else
  fail "坏 reset 把可用账号挡在候选外 —— 正是当年候选为空的原因"
fi

echo "── 退役账号必须彻底不占位置 ──"
# ⚠️ Direct cause of a 28-minute outage: there was only one pause list, and it took effect
#    **only where candidates were filtered**. Two dead accounts were correctly skipped as
#    candidates, yet still counted in the DENOMINATOR of "is everything full?" -- and that
#    logic required every account to have a usable reset time. Those two had not updated in
#    28 hours, so the set never completed, so it only ever logged "ledger incomplete, not
#    guessing a wait time" and sat there, until a human switched accounts by hand.
#    ⇒ ⭐ "Skip it" and "do not count it in the denominator" are two different things;
#    doing the first does not do the second.
# 🔴 This repo has no such denominator (the all-exhausted wait state machine was not
#    extracted), so only the first half is testable here. The second half stays in the
#    report rather than being pretended to be tested.
# ⚠️ 一次停摆 28 分钟的直接成因：当时只有一张暂停名单，而且**只在候选筛选处生效**；
#    两个已死账号被正确跳过了候选，却仍算在「是不是全都满了」的分母里，而那段逻辑要求
#    每个账号都有可用的重置时刻，这俩 28 小时没更新，于是永远凑不齐，于是只会打
#    「台账不完整 → 不猜等待时间」然后干等，最后靠人手动切号解开。
#    ⇒ 「跳过它」和「不把它算进分母」是两件事，做了前者不等于做了后者。
# 🔴 本仓没有那个分母（全撞限与等待状态机未抽取），所以只剩前半件事可测。后半件事
#    留在报告里，不在这里假装测过。
cat > "$QUOTA_STATE" <<'JSON'
{"account":"cur@x","accounts":{
  "dead1@x":{"five":5,"week":5},
  "dead2@x":{"five":6,"week":6},
  "live@x":{"five":10,"week":40}}}
JSON
QUOTA_RETIRED_ACCOUNTS="dead1@x"; QUOTA_DISABLED_ACCOUNTS="dead2@x"
_rt_order=$(quota_switch_ranked_candidates | cut -f1 | tr '\n' ' ')
if [[ "$_rt_order" == "live@x " ]]; then
  pass "退役与暂停的账号都不进候选，哪怕它们的数字最好看"
else
  fail "已退役/已暂停的账号仍在候选里：$_rt_order"
fi
# ⚠️ Positive control: take the two dead accounts off the list and they must **reappear**
#    as candidates -- otherwise the case above might have excluded them for some other
#    reason entirely, and the assertion has no discriminating power.
# ⚠️ 正控：把两个死账号从名单里拿掉，它们必须**重新**出现在候选里。
#    否则上面那条可能只是因为别的原因排除了它们，断言没有区分度。
QUOTA_RETIRED_ACCOUNTS=""; QUOTA_DISABLED_ACCOUNTS=""
_rt_order2=$(quota_switch_ranked_candidates | cut -f1 | tr '\n' ' ')
if [[ "$_rt_order2" == "dead1@x dead2@x live@x " ]]; then
  pass "正控：从名单里拿掉之后它们确实重新进候选（上一条不是恒真）"
else
  fail "拿掉名单后顺序仍不含它们：$_rt_order2 —— 上一条断言没有区分度"
fi
# ⚠️ The two lists must take effect independently: leave only one and the other's account
#    has to come back.
#    ⭐ Without this, "merge the two lists into one" passes everything.
# ⚠️ 两张名单必须各自独立生效：只留一张时另一张的账号必须回来。
#    没有这一条，「把两张名单拼成一张」这种改法会全绿通过。
QUOTA_RETIRED_ACCOUNTS="dead1@x"; QUOTA_DISABLED_ACCOUNTS=""
_rt_only_retired=$(quota_switch_ranked_candidates | cut -f1 | tr '\n' ' ')
QUOTA_RETIRED_ACCOUNTS=""; QUOTA_DISABLED_ACCOUNTS="dead2@x"
_rt_only_paused=$(quota_switch_ranked_candidates | cut -f1 | tr '\n' ' ')
if [[ "$_rt_only_retired" == "dead2@x live@x " && "$_rt_only_paused" == "dead1@x live@x " ]]; then
  pass "退役名单与暂停名单各自独立生效（不是被拼成同一张）"
else
  fail "两张名单没有各自生效（retired-only=$_rt_only_retired paused-only=$_rt_only_paused）"
fi
QUOTA_RETIRED_ACCOUNTS=""; QUOTA_DISABLED_ACCOUNTS=""
}

case "$TEST_LAYER" in
  shadow) run_shadow_tests ;;
  slow) run_decision_tests; run_switch_tests; run_candidate_tests; run_slow_tests ;;
  fast|all) run_extraction_tests; run_fast_tests; run_monitor_tests; run_cadence_tests; run_reading_round_tests
            [[ "$TEST_LAYER" == all ]] && { run_shadow_tests; run_decision_tests; run_switch_tests; run_candidate_tests; run_slow_tests; } ;;
  *) echo "layer $TEST_LAYER not populated yet" ;;
esac
run_isolation_check
echo
printf 'PASS %d   FAIL %d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
