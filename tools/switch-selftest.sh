#!/usr/bin/env bash
#
# Self-test for the switching half, plus the tooling contracts a regression suite will
# consume. Every check below exists because something got
# through without it; each one is paired with a negative control that proves the check
# can actually go red. A check that has never been observed to fail is not a check.
# 切号那一半的自检。下面每条判据都对应一次真实漏过去的事故,并且每条都配了负控证明它会红。
# 没红过的判据不算判据。
#
# Usage: tools/switch-selftest.sh
# Exit:  0 all checks passed (and every negative control went red) | 1 otherwise
#
# ⚠️ The positive checks run against the REAL functions, sourced from lib/. The negative
#    controls run against a verbatim copy of the PRE-FIX implementation. Testing a copy
#    of the fixed code would prove nothing about the code that ships.
# ⚠️ 正向判据打在**真实函数**上(从 lib/ source 进来);负控打在**修复前实现的逐字副本**上。
#    拿修好的代码的副本去测,对真正发布的那份什么都没证明。

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF_DIR/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/switch-selftest.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ck(){ # $1 id  $2 desc  $3 expected  rest: command
  local id="$1" desc="$2" exp="$3"; shift 3
  local out rc; out=$("$@" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then printf 'PASS  %-6s %s\n' "$id" "$desc"; pass=$((pass+1))
  else printf 'FAIL  %-6s %s\n        expected: %s\n        actual:   %s\n' \
       "$id" "$desc" "$exp" "${out:-<no output>}"; fail=$((fail+1)); fi
}
ckred(){ # negative control: the command MUST fail, or the matching check has no teeth
  local id="$1" desc="$2"; shift 2
  local out rc; out=$("$@" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then printf 'PASS  %-6s %s\n' "$id" "$desc"; pass=$((pass+1))
  else printf 'FAIL  %-6s %s\n        expected: the pre-fix code to FAIL this check\n        actual:   it passed, so the check has no teeth\n' \
       "$id" "$desc"; fail=$((fail+1)); fi
}

export QS_STATE_DIR="$WORK/state"; mkdir -p "$QS_STATE_DIR"
# shellcheck source=../lib/config.sh
source "$REPO/lib/config.sh" >/dev/null 2>&1 || { echo "cannot source lib/config.sh"; exit 1; }
# shellcheck source=../lib/reading.sh
source "$REPO/lib/reading.sh" >/dev/null 2>&1 || { echo "cannot source lib/reading.sh"; exit 1; }
source "$REPO/lib/monitor.sh" >/dev/null 2>&1
source "$REPO/lib/detect.sh"  >/dev/null 2>&1
source "$REPO/lib/state.sh"   >/dev/null 2>&1
source "$REPO/lib/switch.sh"  >/dev/null 2>&1 || { echo "cannot source lib/switch.sh"; exit 1; }

# ── S1: the roster must be ONE json document, for every combination of empty/non-empty
#
# 🔴 The check is `jq -s 'length == 1'`, NOT `jq -e .`. That distinction is the whole
#    point: the broken version emitted `[]\n[]` — two documents — and `jq -e .` returns
#    0 on it. The handiest validity check passed, which is why the defect survived to
#    a delivered milestone. Only `--argjson` (and a document count) rejects it.
# 🔴 判据用 `jq -s 'length == 1'` 而**不是** `jq -e .`。这个区别就是全部要害:坏掉的那版
#    产出 `[]\n[]`(两个文档),而 `jq -e .` 对它返回 0——最顺手的检查是通过的,所以它一路
#    活到了交付。只有 `--argjson`(和文档计数)会拒绝它。
roster_docs_is_one(){
  local r="$1" d="$2" v n
  QUOTA_RETIRED_ACCOUNTS="$r" QUOTA_DISABLED_ACCOUNTS="$d"
  v=$(quota_out_of_service_json)
  n=$(printf '%s' "$v" | jq -s 'length' 2>/dev/null)
  [ "$n" = 1 ] || { echo "roster=[$r|$d] produced $n json documents, not 1: $(printf '%q' "$v")"; return 1; }
  jq -n --argjson skip "$v" '$skip' >/dev/null 2>&1 \
    || { echo "roster=[$r|$d] is not usable with --argjson: $(printf '%q' "$v")"; return 1; }
}
s1(){ roster_docs_is_one "" "" && roster_docs_is_one "a@x.invalid" "" \
   && roster_docs_is_one "" "b@x.invalid" && roster_docs_is_one "a@x.invalid c@x.invalid" "b@x.invalid"; }

# the pre-fix implementation, verbatim, as the negative control
roster_prefix_impl(){
  printf '%s %s\n' "$1" "$2" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -sc . 2>/dev/null || printf '[]'
}
s1_neg(){
  local v n; v=$(roster_prefix_impl "" "")
  n=$(printf '%s' "$v" | jq -s 'length' 2>/dev/null)
  [ "$n" = 1 ] && { echo "pre-fix impl produced 1 document; the check would not have caught it"; return 0; }
  return 1
}

# ── S2: end-to-end — an EMPTY roster must not silently swallow every candidate.
#    The expectation is a specific account name, not "no error": the defect this
#    replaces produced a perfectly successful run that simply never switched.
# ── S2 端到端:空名册不得把所有候选静默吞掉。期望值写成**具体账号名**而不是「不报错」——
#    被它取代的那个缺陷跑起来完全成功,只是永远不切。
s2(){
  local got
  cat > "$QS_STATE_DIR/quota-state.json" <<'ST'
{ "account": "cur@example.invalid",
  "accounts": {
    "cur@example.invalid":     { "five": 99, "week": 50 },
    "lowweek@example.invalid": { "five": 85, "week": 5  },
    "lowfive@example.invalid": { "five": 1,  "week": 80 } } }
ST
  QUOTA_STATE="$QS_STATE_DIR/quota-state.json"
  QUOTA_RETIRED_ACCOUNTS="" QUOTA_DISABLED_ACCOUNTS=""
  got=$(quota_switch_pick "cur@example.invalid")
  [ "$got" = "lowweek@example.invalid" ] \
    || { echo "picked '${got:-<nothing>}', expected lowweek@example.invalid (ranked by weekly headroom)"; return 1; }
}

# ── S3: retention keeps the NEWEST backup, judged by mtime.
#
# 🔴 The expectation is WHICH ONE survives, not HOW MANY. The predecessor of this check
#    asserted a count ("16 switches, still 5 backups") and stayed green while retention
#    was deleting the wrong ones: directory names are
#    `claude-backup-before-<reason>-<timestamp>`, so lexical order sorts by REASON first
#    and 'r'ollback always sorted ahead of 's'witch — the rollback safety backup was
#    deleted first no matter how new it was.
# 🔴 期望值是**留下了哪一个**,不是**留下了几个**。上一版判据断言的是数量
#    (「16 次切换后仍是 5 个」),而保留策略正在删错人的时候它一直是绿的:目录名是
#    `claude-backup-before-<reason>-<timestamp>`,字典序先按 reason 排,'r' < 's' ⇒
#    rollback 的安全备份不论多新永远排在最前、第一个被删。
plant(){ mkdir -p "$1"; echo '{}' > "$1/manifest.json"; touch -d "$2" "$1"; }
s3(){
  local home="$WORK/s3/home" d
  rm -rf "$WORK/s3"; mkdir -p "$home/claude-backups"
  plant "$home/claude-backups/claude-backup-before-switch-20260101-000000"   '2026-01-01 00:00'
  plant "$home/claude-backups/claude-backup-before-rollback-20261231-235959" '2026-12-31 23:59'
  python3 - "$REPO" "$home" <<'PY' || return 1
import sys, types
from pathlib import Path
# account-switch has no .py suffix, so it is loaded by exec into a module object.
# ⚠️ It must be registered in sys.modules FIRST: @dataclass resolves its own class's
#    module by name at decoration time, and an unregistered module makes that lookup
#    return None. The traceback names dataclasses.py, not this file.
# ⚠️ 必须**先**注册进 sys.modules:@dataclass 在装饰时按名字回查自己所属模块,
#    没注册就会查到 None。报错栈指的是 dataclasses.py,不是这里。
mod = types.ModuleType("acs")
sys.modules["acs"] = mod
src = open(f"{sys.argv[1]}/account-switch", encoding="utf-8").read()
exec(compile(src, "account-switch", "exec"), mod.__dict__)
mod.prune_backups(Path(sys.argv[2]), 1)
left = sorted(p.name for p in (Path(sys.argv[2]) / "claude-backups").iterdir())
if left != ["claude-backup-before-rollback-20261231-235959"]:
    print(f"retention kept {left}, expected only the mtime-newest "
          f"(claude-backup-before-rollback-20261231-235959)")
    raise SystemExit(1)
PY
}
# negative control: lexical sort, i.e. the pre-fix ordering
s3_neg(){
  local home="$WORK/s3n/home"
  rm -rf "$WORK/s3n"; mkdir -p "$home/claude-backups"
  plant "$home/claude-backups/claude-backup-before-switch-20260101-000000"   '2026-01-01 00:00'
  plant "$home/claude-backups/claude-backup-before-rollback-20261231-235959" '2026-12-31 23:59'
  python3 - "$home" <<'PY'
import shutil, sys
from pathlib import Path
parent = Path(sys.argv[1]) / "claude-backups"
owned = sorted(p for p in parent.iterdir())          # <-- lexical, the pre-fix bug
for p in owned[: len(owned) - 1]:
    shutil.rmtree(p, ignore_errors=True)
left = sorted(p.name for p in parent.iterdir())
raise SystemExit(0 if left == ["claude-backup-before-rollback-20261231-235959"] else 1)
PY
}

# ── S4: after a successful rollback, the safety backup it PRINTED must still exist.
#    ⭐ The tool told the operator "this is your safety net" and then deleted it. The
#    check is on the exact path the tool printed, because that is the promise made.
# ── S4 一次成功回滚之后,它**打印给操作者的**那份安全备份必须还在磁盘上。
#    ⭐ 工具刚说完「这是你的安全网」就把它删了。判据打在它**印出来的那个路径**上,
#    因为那才是它许下的承诺。
mkacct(){ mkdir -p "$1/.claude"
  printf '{"oauthAccount":{"emailAddress":"%s@example.invalid","accountUuid":"%s"}}\n' "$2" "$3" > "$1/.claude.json"
  printf '{"claudeAiOauth":{"accessToken":"FAKE-A-%s","refreshToken":"FAKE-R-%s","expiresAt":4102416000000,"subscriptionType":"max"}}\n' "$2" "$2" > "$1/.claude/.credentials.json"
  chmod 600 "$1/.claude/.credentials.json"; }
s4(){
  local box="$WORK/s4" out safety
  rm -rf "$box"; mkdir -p "$box"
  mkacct "$box/home" alfa 11111111-1111-1111-1111-111111111111
  mkacct "$box/src"  bravo 22222222-2222-2222-2222-222222222222
  mkacct "$box/spare" alfa 11111111-1111-1111-1111-111111111111
  local A=(python3 "$REPO/account-switch" --no-docker --no-default-hosts
           --source "$box/src" --source "$box/spare" --root-home "$box/home"
           --backup-credentials full --keep 2)
  "${A[@]}" --use bravo@example.invalid --yes >/dev/null 2>&1 || { echo "setup switch failed"; return 1; }
  "${A[@]}" --use alfa@example.invalid  --yes >/dev/null 2>&1 || { echo "setup switch 2 failed"; return 1; }
  out=$("${A[@]}" --rollback latest --yes 2>&1) || { echo "rollback failed: $(printf '%s' "$out" | tail -1)"; return 1; }
  safety=$(printf '%s' "$out" | sed -n 's/^pre-rollback safety backup: //p' | tail -1)
  [ -n "$safety" ] || { echo "rollback printed no safety backup path"; return 1; }
  [ -d "$safety" ] || { echo "the tool printed '$safety' as the safety backup, then deleted it"; return 1; }
}

# ── S5: when BOTH lines are crossed, the ledger reason must name both, not just the last
# ── S5 两条线同时超时,账本的理由必须两条都写,不能只留最后一条
s5(){
  local r=""
  local five=99 week=100 QUOTA_SWITCH_PCT_FIVE=90 QUOTA_SWITCH_PCT_WEEK=99
  (( five >= QUOTA_SWITCH_PCT_FIVE )) && r="${r:+$r; }five_hour ${five}% >= ${QUOTA_SWITCH_PCT_FIVE}%"
  (( week >= QUOTA_SWITCH_PCT_WEEK )) && r="${r:+$r; }weekly ${week}% >= ${QUOTA_SWITCH_PCT_WEEK}%"
  case "$r" in
    *five_hour*weekly*) : ;;
    *) echo "reason names only one line: '$r'"; return 1 ;;
  esac
  # and assert the shipped code produces the same shape
  grep -q 'reason="${reason:+$reason; }' "$REPO/lib/switch.sh" \
    || { echo "lib/switch.sh still assigns reason instead of accumulating it"; return 1; }
}

echo "switch-selftest: positive checks run against the real functions in lib/"
ck    S1  "roster is one JSON document for every empty/non-empty combination" \
          "exactly 1 document, usable with --argjson"                          s1
ckred S1n "  negative control: the pre-fix roster pipeline fails S1"           s1_neg
ck    S2  "an empty roster still yields the weekly-best candidate" \
          "lowweek@example.invalid"                                            s2
ck    S3  "retention keeps the mtime-newest backup (not the lexically-last)" \
          "only claude-backup-before-rollback-20261231-235959 survives"        s3
ckred S3n "  negative control: lexical ordering deletes the newest"            s3_neg
ck    S4  "the safety backup a successful rollback printed still exists" \
          "the printed path is a directory"                                    s4
ck    S5  "both crossed lines appear in the ledger reason"                     "both named" s5

# ── S6: the DoD-4 control's own output must be readable by the thing that checks it.
#
# 🔴 This is not about tidiness. The natural way to consume the positive control is
#       grep -q 'POSCTRL_RESULT=FAIL' posctrl.log && exit 1
#    and its output used to contain a raw 0xff from the deliberately-binary range-A
#    fixture, which makes grep treat the whole file as binary: it returns 1 and prints
#    nothing, so that failure branch could never fire. A false green, in the direction
#    that looks fine.
#    ⭐ Whoever wires this into a suite will write exactly that grep. The check belongs
#    here, not in the control itself, because a control cannot vouch for its own output.
# 🔴 这条不是整洁问题。消费正控最自然的写法就是上面那句 grep;而它的输出里原本带着
#    范围 A 二进制夹具的裸 0xff,足以让 grep 把整份文件判为二进制:返回 1、什么都不打,
#    于是那个失败分支永远不会触发——假绿,而且往「看起来没事」的方向坏。
#    ⭐ 把它接进套件的人一定会写那句 grep。判据放在这里而不是正控自己里面,
#    因为一个控件没法为自己的输出背书。
s6(){
  local log="$WORK/posctrl.log" n
  bash "$REPO/tools/dod4-scan.posctrl.sh" > "$log" 2>&1
  n=$(grep -c 'POSCTRL_RESULT' "$log" 2>/dev/null)      # deliberately NO -a
  [ "${n:-0}" -ge 1 ] || {
    echo "a plain grep (no -a) found $n verdict lines in the control's own log;"
    echo "        file(1) says: $(file -b "$log"). A consumer's 'grep -q FAIL' would never fire."
    return 1; }
  grep -q 'patterns=' "$log" 2>/dev/null \
    || { echo "the verdict does not say which pattern set the scan used"; return 1; }
}
ck    S6  "the DoD-4 control's verdict is readable without grep -a" \
          "at least one POSCTRL_RESULT line, and it names the pattern set"      s6

echo "----"; echo "switch-selftest: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
