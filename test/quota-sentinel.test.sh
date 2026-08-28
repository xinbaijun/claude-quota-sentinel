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
TMP=$(mktemp -d "${TMPDIR:-/tmp}/quota-sentinel-test.XXXXXX")
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
_leaks=""
for _v in $(compgen -v | grep '^QUOTA_'); do
  _val="${!_v:-}"
  [[ "$_val" == "$QS_REAL_STATE_DIR"* ]] && _leaks="$_leaks $_v=$_val"
done
if [[ -n "$_leaks" ]]; then
  printf 'aborting: these paths point into the REAL state directory and running on would corrupt it:%s\n' "$_leaks" >&2
  printf '  fix: give it a value under $TMP, or make sure it derives from $QS_STATE_DIR (already redirected here)\n' >&2
  exit 3
fi
unset _leaks _v _val

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

echo "── 选单入口：cc 改了选项文案之后还认不认得出 ──"
# 实测背景：cc 在 2026-07-14 之后把选项 2 从 "Switch to usage credits" 改成
# "Upgrade your plan"，旧判据逐字锚这行 → 此后 28 天 menu-detected 恒为 0，
# 同期横幅分支跑了 165+ 次，撞限会话只能等人手动清框。
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
  pass "新判据不吃 scrollback 死选单（末 10 行有空 ❯ = cc 闲置）"
fi

echo "── 横幅入口：用户在对话里提到横幅文案（2026-08-11 活体自激）──"
# 当天实撞：用户在对话里引用了一句撞限横幅作说明，daemon 当场把本会话判成撞限，
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
  pass "新判据拒绝：横幅落在 ❯ 用户输入行上，不是 cc 渲染的横幅"
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
# 旧实现兜底用 tz=$(date +%Z)，本机返回裸 CST，glibc 把它当 UTC+0 → 整体偏 8 小时，
# 且不报错。实测活体撞出：同一句 "resets 3:10pm" 一次记成 15:10 一次记成 23:10。
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

echo "── reset 时间：带时区时新旧应一致（无回归）──"
o=$(legacy_call parse_usage_reset_epoch "$(read_fx reset-with-timezone.txt)" || echo "")
n=$(quota_parse_reset_epoch "$(read_fx reset-with-timezone.txt)" || echo "")
if [[ -n "$o" && "$o" == "$n" ]]; then
  pass "带 (Asia/Shanghai) 时新旧解析一致（$(date -d "@$n" '+%H:%M')）"
else
  fail "带时区时新旧解析不一致（old=$o new=$n）"
fi

echo "── ISO 解析：cc 写进 .claude.json 的形态 ──"
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

# 首次升级还没有 expected 字段时，也不能无条件采当前文件为基线：旧 state.account 是
# 最近一次面板归属。两者已不同时，正是“账号变了但没有对应切号成功事件”的签名。
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

# 恢复后续用例的持久 expected。
cat > "$QUOTA_STATE" <<'JSON'
{"phase":"normal","account":"target@x",
 "account_guard":{"expected_email":"target@x","expected_uuid":"uuid-target"}}
JSON

# 这是管家指出的一次性回读盲区：第一次检查已经通过，随后另一个 cc 进程才把整份
# .claude.json 用旧内存快照盖回。守卫必须拿持久 expected 身份对照，不能把新值当基线跟走。
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
    | grep -vxE 'HOME|PATH|TMPDIR|PWD|SHELL|TERM|LANG|LC_ALL|TZ|IFS|RANDOM|UID|EUID|HOSTNAME|SECONDS|LINENO|COLUMNS|LINES|OSTYPE|FUNCNAME|BASH_SOURCE|BASH_REMATCH|XDG_STATE_HOME|HTTPS_PROXY|HTTP_PROXY|NO_PROXY|ALL_PROXY|R|P' \
    || true
}
undef=$(_undefined_reads "$QS_SOURCE"/lib/*.sh "$QS_SOURCE/quota-sentinel")
if [[ -z "$undef" ]]; then
  pass "lib/*.sh 与 CLI 里没有「读了但谁都没定义」的配置变量"
else
  fail "这些名字被读到却没有任何定义，set -u 下会当场退出：$(printf '%s' "$undef" | tr '\n' ' ')"
fi

# 正控：把同一个检查指向一份**故意抠掉一行**的 config，必须变红。否则上面那条绿了也
# 不说明问题——它可能只是没看见任何东西。
mkdir -p "$TMP/posctrl-lib"
cp "$QS_SOURCE"/lib/*.sh "$TMP/posctrl-lib/"
grep -v '^QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL=' "$QS_SOURCE/lib/config.sh" > "$TMP/posctrl-lib/config.sh"
undef_pc=$(_undefined_reads "$TMP/posctrl-lib"/*.sh)
if printf '%s\n' "$undef_pc" | grep -qx 'QUOTA_ACCOUNT_DRIFT_LOG_INTERVAL'; then
  pass "正控：删掉那一行定义之后，同一个检查确实抓得到（判据会红）"
else
  fail "正控没红：这个检查抓不到「读了没定义」，上面那条绿是没有分辨力的绿"
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
}

# ── monitor lifecycle / monitor 生命周期 ──
run_monitor_tests() {
echo "── monitor 重启：保留 tmux/pane，只在原 shell 内替换 cc ──"
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
  pass "已有 monitor 在原 pane 内 /exit→新 cc→owner 绑定，不杀/重建 tmux"
else
  fail "monitor restart 仍破坏 tmux 或没有原子绑定：$(tr '\n' ' ' < "$MONITOR_RESTART_TRACE")"
fi

: > "$MONITOR_RESTART_TRACE"
quota_monitor_shell_ready() { return 0; }
if quota_monitor_restart 'target@x' 'uuid-target' >/dev/null 2>&1 \
   && [[ "$(tr '\n' ' ' < "$MONITOR_RESTART_TRACE")" == \
         "launch bind:target@x:uuid-target:launch-new " ]]; then
  pass "monitor 已退回 shell 时直接拉起新 cc，不会再向 shell 发送 /exit"
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

# tmux 不再重建后 session_created 不变，必须另有 cc launch id。否则同 pane 里的旧
# statusLine 回调/旧 cc 画面可以冒用新进程 owner 证明。
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
  pass "tmux 代际相同但 cc launch id 不同 → 旧进程 owner 证明失效"
else
  fail "只看 session_created，原 pane 内换 cc 后无法区分新旧进程"
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
  pass "owner/launch 虽匹配但 cc 已回 shell → prepare_owner 仍只恢复一次"
else
  fail "tmux 活着掩盖了已退出的 cc：$(tr '\n' ' ' < "$PREPARE_TRACE")"
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
  pass "原 pane 内先清 shell 残留，再完成 /exit→新 cc；tmux 容器身份保持"
else
  fail "原 pane 换代时序失败：$(tr '\n' ' ' < "$MONITOR_FAKE_TRACE")"
fi

printf 'old\n' > "$MONITOR_FAKE_PHASE"; : > "$MONITOR_FAKE_TRACE"
MONITOR_FAKE_EXIT_STUCK=1 QUOTA_MONITOR_EXIT_SEC=0
if quota_monitor_exit_to_shell >/dev/null 2>&1; then
  fail "/exit 未回 shell 仍继续换代"
elif ! grep -q 'literal:launch' "$MONITOR_FAKE_TRACE"; then
  pass "/exit 未回 shell → fail closed，不发送新 cc 启动命令"
else
  fail "/exit 失败后仍向旧 cc 塞了启动命令"
fi
unset MONITOR_FAKE_EXIT_STUCK

printf 'old\n' > "$MONITOR_FAKE_PHASE"; : > "$MONITOR_FAKE_TRACE"
MONITOR_FAKE_SWAP_PANE=1 QUOTA_MONITOR_EXIT_SEC=1
if quota_monitor_exit_to_shell >/dev/null 2>&1; then
  fail "/exit 前后 pane_id 变化仍被当成原 pane 成功"
else
  pass "pane_id/pane_pid/session 任一变化 → 拒绝在未知 pane 启动 cc"
fi
unset MONITOR_FAKE_SWAP_PANE

printf 'shell\n' > "$MONITOR_FAKE_PHASE"; : > "$MONITOR_FAKE_TRACE"
MONITOR_FAKE_LAUNCH_FAIL=1 QUOTA_MONITOR_READY_SEC=0
if quota_monitor_launch_in_pane >/dev/null 2>&1; then
  fail "启动命令立即失败回 shell仍被旧 composer 冒充 ready"
else
  pass "新 cc 未离开 shell → 即使屏上残留 composer 形文字也拒绝绑定"
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
  pass "凭据 A→B→A 时拒绝把 B 启动的 cc 绑定成 A（launch-time 身份闭环）"
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
# 用户 2026-08-13 拍板：五小时由 96 下调到 94、周仍为 99。两者不只烧速差一个数量级（五小时实测峰值
# 1.3%/分钟，周 ~0.2%/分钟），单位价值也差一个数量级——按实测换算常数 0.120，
# **1 个周额度点 ≈ 8.3 个五小时点**。所以五小时要多留（留 4 点才够从容切号），
# 周额度要尽量少留（每早 1 点就扔掉 8.3 个五小时点的产能）。
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
# ⚠️ 五小时线 2026-08-19 降到 90 后，这里的 five 取值必须跟着降：原来用 90 表示
#    "还没到线"，现在 90 本身就是线上，这条会变成测反了。
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
# 2026-08-19 11:40 实撞：11:35:39 面板 77% → 11:40:52 面板 100%。77% 按水位是 300 秒档，
# 而从 77% 涨到切换线 94% 只要 3.9 分钟——间隔比到线时间还长，必然漏过。结果切号发生在
# 100%，6 个会话在切号前就撞了墙，预防性切号退化成事后补救。
# 上游这里给 quota_banner_pressure 打了桩，因为流速档与「屏上横幅」提速源共用一个
# 出口。本仓没有那个提速源（它读的是那套环境里全部会话的屏幕留档，未抽取），
# quota_usage_interval_adaptive 只剩流速这一条，所以不需要打桩——但也就意味着**这一组
# 现在覆盖的是全部提速源，而不是四分之一**。

RATE_FAIL=0
_rate() {  # _rate <期望> <说明> <five> <week> <prev_five> <prev_week> <prev_ts> <now> <prev_email> <cur_email>
  local want="$1" label="$2"; shift 2
  local got; got=$(quota_usage_interval_adaptive "$@")
  [[ "$got" == "$want" ]] && return 0
  printf '     %-34s 期望 %s 实际 %s\n' "$label" "$want" "$got"; RATE_FAIL=$((RATE_FAIL+1))
}
# 真实数字：上次 five=0%（t=1000），这次 five=77%（t=1620）。
# ⚠️ 切换线 2026-08-19 从 94 降到 90 之后，同一场景算出来是 (90-77)*620/77/2≈52s，
#    低于地板价，所以结果是 60 —— 两项改动叠加的效果：查得更勤 + 线更低，双重余量。
#    （按旧的 94 线算是 68s，这个数留在注释里做对照。）
_rate 60  "实撞那次：300s → 60s（撞地板）" 77 47 0  39 1000 1620 a@x a@x
# 再来一条不撞地板的，单独验流速算式本身：600s 内涨 30 点 → 到 90 线还需 400s，取一半
_rate 200 "中速上涨：300s → 200s（未撞地板）" 70 20 40 15 1000 1600 a@x a@x
# 只收紧不放宽：水位档永远是上界
_rate 300 "慢涨不收紧（水位档 300 封顶）" 50 20 40 19 1000 1600 a@x a@x
# 跨账号不能算流速：旧账号 100% → 新账号 0%，算出来是负的
_rate 300 "跨账号（切号那轮）不算流速"   0  51 100 49 1000 1620 old@x new@x
# 百分比掉下来是窗口重置，不是流速
_rate 600 "窗口重置导致下降，不当流速"   5  49 100 49 1000 1620 a@x a@x
# 没有上一次读数
_rate 300 "无 prev 时回落到水位档"       77 47 "" "" "" 1620 a@x a@x
# 地板价：再快也不低于 60s
_rate 60  "极快上涨仍不低于地板 60s"     93 10 0  5  1000 1010 a@x a@x
if (( RATE_FAIL == 0 )); then
  pass "流速自适应六种情形全部正确（含跨账号/窗口重置两种不该收紧的）"
else
  fail "$RATE_FAIL 种情形算错"
fi

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

rm -f "$QUOTA_PANEL_OBSERVATIONS"
quota_panel_log_observation "$SCHED_NOW" 'sched@x' 'uuid-s' local_sample clean "$PANEL_OK"
if jq -e --arg raw "$PANEL_OK" '
     .source=="usage_panel_screen" and .mode=="local_sample" and .status=="clean"
     and .account.email=="sched@x" and .cadence.local_sample_seconds==10
     and .panel_text==$raw and (.panel_sha256|length)==64' \
     "$QUOTA_PANEL_OBSERVATIONS" >/dev/null 2>&1; then
  pass "每次本地采样保留账号、时刻、档位、解析值、SHA 与可见面板原文"
else
  fail "10s 面板观测日志缺原始画面或频率/账号字段"
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
# 2026-08-11 事故的两条真实序列都**不是回退**，而是旧窗口的高值回来了：
#   Faith   19:49:53 five=97%(旧窗口) → 19:50:13 five=0%(真 reset) → 19:50:31 five=97%(旧窗口)
#   Michael 21:10:09 five=0%(真 reset) → 21:10:28 five=99%(旧窗口)
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

# ── 事故序列 1：Faith 97 → 0 → 97 ──
mk_last "faith@x" 0 11 "$SR_NEW" "$WR"          # 已确认：真 reset 后的 0%
if quota_frame_stale "faith@x" 97 10 "$SR_OLD" "$WR"; then
  pass "Faith 97%(已过期窗口) 在 0%(新窗口) 之后回来 → 判陈旧（事故序列 1）"
else
  fail "没拦住事故序列 1——这正是 19:50:31 那次错切的原因"
fi
# ── 事故序列 2：Michael 0 → 99 ──
mk_last "m@x" 0 88 "$SR_NEW" "$WR"
if quota_frame_stale "m@x" 99 87 "$SR_OLD" "$WR"; then
  pass "Michael 99%(已过期窗口) 在 0% 之后回来 → 判陈旧（事故序列 2）"
else
  fail "没拦住事故序列 2"
fi
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

# ⚠️ 基准本身可能是坏的。2026-08-12 11:38 活体实撞：state 里存着旧 buggy 代码写下的
# five_reset_ts=08-13 02:10（距今 14.5h，五小时窗口不可能这么远），于是面板的**真值**
# 08-12 12:10 被判成"更旧的窗口"，新 poller 每一帧都被拒、读数彻底进不来。
# 基准要用同一条物理事实先校验：超出 5h 视界或已过去 → 当没有基准。
BAD_SR=$(( NOW_T + 52200 ))     # 14.5 小时后——不可能是五小时窗口
mk_last "f@x" 0 10 "$BAD_SR" "$WR"
if quota_frame_stale "f@x" 20 14 "$(( NOW_T + 1800 ))" "$WR"; then
  fail "坏基准（$(date -d @$BAD_SR '+%m-%d %H:%M')）把真值判成陈旧 → 读数会彻底进不来"
else
  pass "基准超出 5h 视界 → 当没有基准，真值照常采信"
fi
mk_last "f@x" 0 10 "$(( NOW_T - 3600 ))" "$WR"
if quota_frame_stale "f@x" 20 14 "$(( NOW_T + 1800 ))" "$WR"; then
  fail "已过去的基准仍被用来比较"
else
  pass "基准已过去（窗口早结束）→ 当没有基准"
fi

# ⚠️ 基准过期时，百分比要跟 reset 一起作废。2026-08-12 12:19 实撞：Faith 12:10 重置后
# state 里还留着旧窗口的 five=100（reset 已过），新窗口真值 20% 被「100→20 回退」拒掉，
# 读数饿死——只作废基准的 reset、留着它的百分比做单调性比较，等于让死窗口继续否决活窗口。
# 帧的 week 给 25（不回退）：这条用例只考「五小时维度的死基准」。当天真实的 20/14 帧
# 其实 week 也回退了，它被拒是对的——真正饿死读数的是后来 19/25 那类帧的 five 维度。
mk_last "f@x" 100 23 "$(( NOW_T - 300 ))" "$WR"     # 基准：reset 五分钟前已过
if quota_frame_stale "f@x" 20 25 "$(( NOW_T + 17000 ))" "$WR"; then
  fail "死窗口的 100% 否决了新窗口的真值 20%（当天 12:19 读数饿死那一幕）"
else
  pass "基准 reset 已过 → 其百分比一并作废，新窗口 20% 正常采信"
fi

# 单调性那一路仍要保住（当天 Michael 94→0、Paula 21→7 那两组）
mk_last "m@x" 94 88 "$SR_NEW" "$WR"
if quota_frame_stale "m@x" 0 88 "$SR_NEW" "$WR"; then
  pass "同窗口内 94%→0% 回退 → 判陈旧"
else
  fail "没识别同窗口回退"
fi
mk_last "p@x" 21 95 "$SR_NEW" "$WR"
if quota_frame_stale "p@x" 7 94 "$SR_NEW" "$WR"; then
  pass "同窗口内 21%→7% 回退 → 判陈旧（当天 Paula 那一组）"
else
  fail "没识别 Paula 那组回退"
fi
# 真 reset 后合法归零必须放行，否则永远拒绝重置后的真值
mk_last "m@x" 98 88 "$(( NOW_T + 60 ))" "$WR"
if quota_frame_stale "m@x" 0 88 "$SR_NEW" "$WR"; then
  fail "真 reset 后的合法归零被误判 → 会永远拒绝新窗口读数"
else
  pass "真 reset（窗口 reset 时刻前移到新的未来值）后归零 → 采信"
fi
# 账号不同不可比
mk_last "m@x" 98 88 "$SR_NEW" "$WR"
if quota_frame_stale "other@x" 0 5 "$SR_NEW" "$WR"; then
  fail "不同账号之间不该比较"
else
  pass "账号不同 → 不适用（切号后第一读本就是另一账号的独立读数）"
fi
# reset 拿不到 + 回退 → fail closed
mk_last "m@x" 94 88 "$SR_NEW" "$WR"
if quota_frame_stale "m@x" 0 88 "" ""; then
  pass "reset 时刻不可得 + 回退 → fail closed 当陈旧帧"
else
  fail "reset 未知时应保守判陈旧"
fi
# 正常上涨必须放行
mk_last "m@x" 90 88 "$SR_NEW" "$WR"
if quota_frame_stale "m@x" 91 88 "$SR_NEW" "$WR"; then
  fail "正常上涨被误判 → 会拒绝一切真值"
else
  pass "同窗口内上涨 → 正常采信"
fi

echo "── reset 分钟抖动：同一窗口允许相差 5 分钟，不能颠倒新旧帧 ──"
# 2026-08-13 活体：同一次 r 刷新交替显示 Boyce 62/35 @ 4:00/14:00（缓存）与
# 77/37 @ 3:59/13:59（新鲜）。两个来源对同一 reset 的分钟取整相差 60s；若精确比较
# epoch，真帧会因 reset 早一分钟被拒，缓存又会因 reset 晚一分钟冒充“新窗口”。
# 用户随后补充，服务端/UI 的同窗 reset 还可能相差几分钟；容差扩为 5 分钟。真正换窗会
# 跳约 5h/7d，远大于 5 分钟；容差内仍必须服从百分比单调性，不能让低值缓存借机混入。
if declare -F quota_reset_same_window >/dev/null 2>&1 \
   && quota_reset_same_window "$SR_NEW" "$((SR_NEW-300))" \
   && quota_reset_same_window "$WR" "$((WR+300))" \
   && ! quota_reset_same_window "$SR_NEW" "$((SR_NEW-301))"; then
  pass "reset 相差不超过 5 分钟归为同窗，超过容差仍区分窗口"
else
  fail "reset 同窗容差不是 5 分钟"
fi
mk_last "boyce@x" 66 36 "$SR_NEW" "$WR"
if quota_frame_stale "boyce@x" 77 37 "$((SR_NEW-240))" "$((WR-240))"; then
  fail "新鲜 77/37 因 reset 早 4 分钟被错拒"
else
  pass "同窗 reset 早 4 分钟但用量上涨 → 采信新鲜帧"
fi
mk_last "boyce@x" 77 37 "$((SR_NEW-240))" "$((WR-240))"
if quota_frame_stale "boyce@x" 62 35 "$SR_NEW" "$WR"; then
  pass "同窗 reset 晚 4 分钟但用量回退 → 仍判缓存陈旧"
else
  fail "62/35 缓存借 reset 晚 4 分钟冒充新窗口"
fi
mk_last "boyce@x" 66 36 "$SR_NEW" "$WR"
if quota_frame_stale "boyce@x" 99 99 "$((SR_NEW-301))" "$((WR-301))"; then
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
# ⚠️ 必须锁 LC_ALL=C：date 的 %P/%b 是**跟随 locale** 的，本机中文环境下 `%P` 输出
#    「下午」而不是「pm」，喂给解析器就是一个现实中根本不会出现的字符串——
#    cc 面板永远是英文。不锁的话这几条用例测的不是生产逻辑，而是本机 locale，
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
  pass "同账号/同 cc 代际在 next_due 前不触网；到点或账号/tmux/cc 代际变化立即刷新"
else
  fail "网络 due 没有按持久账号、tmux+cc 代际与 next_due 隔离"
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
  # ⚠️ 本条测的是**时钟起点**，不是档位数值：next_due 必须 = 完成时刻 + 本轮实际档位。
  #    原来写死成 1320（=1020+300）——2026-08-19 加了流速自适应后档位会被合法地收紧，
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

# 主轮写两份：顶层当前值 + accounts[current]。任一 reset 非法时，整帧必须原子拒绝，
# 不能把新百分比配旧 reset，也不能写 null 主动制造 P1-A 的残缺台账。
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
# 🔴 上游这一组还有第三段：候选账号切过去量一次之后的**另一处写入口**，同样不许绕过
#    reset 规范化（走 quota_try_switch → 候选面板读数 → 写 accounts[候选]）。
#    本仓**没有那条路径**：切号那一半是重写的，quota_switch_perform 把凭据交给
#    account-switch 之后就结束，不去测量候选账号、也不写候选台账（候选数值只由
#    account-probe 的快照另行提供）。⇒ 那段断言在本仓没有对象，整段不搬，
#    **而不是**改成一条碰巧能通过的形式。若以后补上候选测量，这段要一起补回来。
}

case "$TEST_LAYER" in
  fast|all) run_extraction_tests; run_fast_tests; run_monitor_tests; run_cadence_tests; run_reading_round_tests ;;
  *) echo "layer $TEST_LAYER not populated yet" ;;
esac
echo
printf 'PASS %d   FAIL %d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
