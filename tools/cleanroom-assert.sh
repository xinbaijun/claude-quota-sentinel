#!/usr/bin/env bash
# cleanroom-assert.sh — "is this machine clean?", one assertion at a time.
#                       「这台机器干净吗」逐条判据
#
# What this is for: proving that this repo runs **without the private in-house
# environment it was extracted from**. Run it inside a throwaway sandbox before you
# run the tool itself; if the environment is not actually clean, a later green result
# could have come from that environment rather than from this code.
# 它的用途：证明本仓**脱开它被抽取出来的那套内部环境**也能跑。在一次性沙箱里先跑它，
# 再跑被测物；环境不干净时，后面的绿有可能来自那套环境而不是来自这份代码。
#
# It generalises: point the six CLEANROOM_PRIVATE_* inputs at whatever environment
# you need to prove independence from — a corporate toolchain, a monorepo's helper
# shims, an internal PATH. Nothing about the private environment is baked in here.
# 它是通用的：把下面六个 CLEANROOM_PRIVATE_* 输入指向任何你需要证明「不依赖它」的环境
# 即可。本文件里不写死那套环境的任何东西。
#
# Design constraint 1: every assertion must go **red on the original host**. An
#   assertion that is always green has no discriminating power and is the same as not
#   having written it.
# Design constraint 2: **fail closed**. A missing precondition is red, with an
#   explanation — never a silent pass. An assertion that went green "because there was
#   nothing to check" and one that went green "because it checked and found nothing"
#   print identical output, and only one of them means anything.
# 设计约束一：每条判据都必须在**原宿主上跑会红**。恒绿的判据没有分辨力，等于没写。
# 设计约束二：**fail-closed**。缺前置条件一律判红并说明，绝不沉默通过——一条「因为没
#   东西可查所以绿了」的判据，和一条「查过了没问题」的判据，输出长得一模一样。
#
# Exit code: 0 = all green; 1 = something is red. / 退出码：0=全绿；1=有红。
#
# ── Inputs. All are empty by default and every one of them is site-specific. ──
# ⚠️ **They must stay empty in this repo.** Their values name internal paths, internal
#    command names and internal marker files — exactly the class of thing that must
#    not be published. Supply them from the environment on your verification machine.
# ⚠️ None of them has a non-empty default, and that is deliberate in a way worth
#    spelling out: a real default would publish an internal string, while an *empty*
#    default silently guts the check. An empty string makes `grep -qs ""` match
#    everything (C2 permanently red), degrades a `case` pattern to `/*` (C11
#    permanently red), and — worst — degrades `test -e "$ROOT/$MARKER"` into testing
#    `/` , which **passes forever while guarding nothing at all**. So each assertion
#    checks its own inputs first and goes red when they are missing.
# ── 输入。全部默认留空，且每一个都是站点专有的。──
# ⚠️ **它们在本仓里必须保持为空**：它们的取值就是内网路径、内部命令名、内部标记文件名，
#    正是不该公开的那一类东西。在你自己的验证机上从环境变量传进来。
# ⚠️ 一个非空默认值等于把内部字符串写进公开仓；而空默认值更糟——空串会让 `grep -qs ""`
#    匹配一切、让 `case` 模式退化成 `/*`、并让 `test -e "$ROOT/$MARKER"` 退化成测 `/`，
#    那会**永远通过、却什么都没守**。所以每条判据先查自己的输入，缺了就红。
#
#   CLEANROOM_PRIVATE_ROOT       absolute path of that environment's root       (C2 C3 C8 C11)
#   CLEANROOM_PRIVATE_MARKER     a filename that exists at that root            (C3)
#   CLEANROOM_PRIVATE_SHIMS      space-separated command names that forward into it (C2)
#   CLEANROOM_PRIVATE_ENV_PREFIX ERE matching its environment-variable names     (C1)
#   CLEANROOM_PRIVATE_TOKENS     ERE of strings identifying it inside files      (C10)
#   CLEANROOM_PRIVATE_NEAR       ERE of paths that are "too close" to it         (C11)
CLEANROOM_PRIVATE_ROOT=${CLEANROOM_PRIVATE_ROOT:-}
CLEANROOM_PRIVATE_MARKER=${CLEANROOM_PRIVATE_MARKER:-}
CLEANROOM_PRIVATE_SHIMS=${CLEANROOM_PRIVATE_SHIMS:-}
CLEANROOM_PRIVATE_ENV_PREFIX=${CLEANROOM_PRIVATE_ENV_PREFIX:-}
CLEANROOM_PRIVATE_TOKENS=${CLEANROOM_PRIVATE_TOKENS:-}
CLEANROOM_PRIVATE_NEAR=${CLEANROOM_PRIVATE_NEAR:-}

pass=0; fail=0
ck(){ local id=$1 desc=$2 exp=$3; shift 3
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then printf 'PASS  %-5s %s\n' "$id" "$desc"; pass=$((pass+1))
  else printf 'FAIL  %-5s %s\n        expected: %s\n        actual:   %s\n' "$id" "$desc" "$exp" "${out:-<no output>}"; fail=$((fail+1)); fi
}
# need <VAR-NAME> <value> — red, with the reason, when an input is missing. The empty
# value never reaches a grep / case / test.
# need —— 输入缺失时判红并说明理由；空值绝不参与 grep/case/test。
need(){ [ -n "$2" ] || { echo "$1 is not set; this assertion cannot be judged (must NOT count as a pass)"; return 1; }; }

c1(){ need CLEANROOM_PRIVATE_ENV_PREFIX "$CLEANROOM_PRIVATE_ENV_PREFIX" || exit 1
      n=$(env | grep -cE "$CLEANROOM_PRIVATE_ENV_PREFIX" || true)
      [ "$n" = 0 ] || { env | grep -E "$CLEANROOM_PRIVATE_ENV_PREFIX" | cut -d= -f1 | tr '\n' ' '; exit 1; }; }
c2(){ need CLEANROOM_PRIVATE_ROOT "$CLEANROOM_PRIVATE_ROOT" || exit 1
      need CLEANROOM_PRIVATE_SHIMS "$CLEANROOM_PRIVATE_SHIMS" || exit 1
      local hit=() c r
      # The assertion is NOT "this name does not exist". Short internal command names
      # collide with real system utilities more often than you would expect — plenty of
      # ordinary words are also real binaries on a stock Linux — and demanding that a
      # real command disappear is an **unimplementable assertion**: permanently red,
      # which trains people to ignore red.
      # The assertion is "the name does not resolve to a shim that forwards into that
      # private environment".
      # 判据不是「这个名字不存在」——短命令名与真实系统工具撞名的概率比想象中高（一台
      # 干净 Linux 上不少普通英文词本身就是真二进制），而要求一个真命令消失是
      # **不可实现的判据**：恒红，会训练出「看到红也照过」。判据是「这个名字解析到的
      # 东西不是一个转发进那套环境的壳」。
      for c in $CLEANROOM_PRIVATE_SHIMS; do
        r=$(command -v "$c" 2>/dev/null) || continue
        grep -qs "$CLEANROOM_PRIVATE_ROOT" "$r" 2>/dev/null && hit+=("$c -> $r")
      done
      [ ${#hit[@]} -eq 0 ] || { printf '%s; ' "${hit[@]}"; exit 1; }; }
c3(){ need CLEANROOM_PRIVATE_ROOT "$CLEANROOM_PRIVATE_ROOT" || exit 1
      need CLEANROOM_PRIVATE_MARKER "$CLEANROOM_PRIVATE_MARKER" || exit 1
      [ ! -e "$CLEANROOM_PRIVATE_ROOT/$CLEANROOM_PRIVATE_MARKER" ] \
        || { echo "exists: $CLEANROOM_PRIVATE_ROOT/$CLEANROOM_PRIVATE_MARKER"; exit 1; }; }
c4(){ [ ! -e /root/.claude.json ] || { echo "exists: /root/.claude.json ($(stat -c%s /root/.claude.json) bytes)"; exit 1; }; }
c5(){ local k; k=$(ls -1 /root/.ssh 2>/dev/null | grep -E '^id_' || true)
      [ -z "$k" ] || { echo "keys present: $(echo "$k" | tr '\n' ' ')"; exit 1; }; }
c6(){ local n
      # Count with a single readdir: `ls -d /proc/[0-9]*` hits a race between glob
      # expansion and stat when a process exits in between, and exits 2. Under
      # `set -euo pipefail` with `2>/dev/null` that looks like the assertion itself
      # failing (empty output, rc=2) rather than a race.
      # 用单次 readdir 计数：`ls -d /proc/[0-9]*` 会在 glob 展开与 stat 之间撞上退出的
      # 进程而 exit 2（竞态），表现得像判据本身不成立。
      n=$(ls /proc 2>/dev/null | grep -c '^[0-9]' || true)
      [ "${n:-0}" -le 25 ] || { echo "visible processes=$n (host order of magnitude)"; exit 1; }; }
c7(){ command -v tmux >/dev/null 2>&1 && { echo "tmux is executable: $(command -v tmux)"; exit 1; }
      [ ! -e /tmp/tmux-0 ] || { echo "exists: /tmp/tmux-0"; exit 1; }; }
c8(){ need CLEANROOM_PRIVATE_ROOT "$CLEANROOM_PRIVATE_ROOT" || exit 1
      git -C "$CLEANROOM_PRIVATE_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 \
        && { echo "the private git root is reachable"; exit 1; }; exit 0; }
c9(){ [ "${HOME:-}" != /root ] || { echo "HOME=$HOME"; exit 1; }
      [ -z "$(ls -A "${HOME:-/nonexistent}" 2>/dev/null)" ] || { echo "HOME is not empty: $(ls -A "$HOME" | head -5 | tr '\n' ' ')"; exit 1; }; }
c10(){ need CLEANROOM_PRIVATE_TOKENS "$CLEANROOM_PRIVATE_TOKENS" || exit 1
      local hit; hit=$(grep -rliE "$CLEANROOM_PRIVATE_TOKENS" /etc/profile.d 2>/dev/null || true)
      [ -z "$hit" ] || { echo "injecting files: $(echo "$hit" | tr '\n' ' ')"; exit 1; }; }
c11(){ need CLEANROOM_PRIVATE_ROOT "$CLEANROOM_PRIVATE_ROOT" || exit 1
      need CLEANROOM_PRIVATE_NEAR "$CLEANROOM_PRIVATE_NEAR" || exit 1
      local top; top=$(git rev-parse --show-toplevel 2>/dev/null || true)
      case "$top" in "$CLEANROOM_PRIVATE_ROOT"|"$CLEANROOM_PRIVATE_ROOT"/*) echo "cwd is inside the private repo: $top"; exit 1;; esac
      # "Not inside that repo" is not the same as "far enough away". The upstream
      # version of this assertion also hard-coded one host's big-disk path here, which
      # is precisely the kind of internal path that must not be published — so it
      # became a declared input instead.
      # ⚠️ It is fail-closed rather than "skip the second half when unset", and that is
      #    the whole point: an undeclared neighbourhood would leave C11 quietly weaker
      #    while still printing PASS. A weaker check that still says PASS is worse than
      #    a red one, because nobody ever looks at it again.
      # 「不在那个仓里面」不等于「离得够远」。上游这条判据在这里还写死了某台宿主的大盘
      # 路径——那正是不该公开的内网路径，所以改成显式声明的输入。
      # ⚠️ 它是 fail-closed，而不是「没声明就跳过后半段」：没声明的话 C11 会**悄悄变弱**
      #    却照样印 PASS，而一条变弱了还说 PASS 的判据比红着更糟——没有人会再看它一眼。
      if printf '%s' "$PWD" | grep -qE "$CLEANROOM_PRIVATE_NEAR"; then
        echo "cwd is inside the declared neighbourhood of the private environment: $PWD"; exit 1
      fi
      exit 0; }
c12(){ local und=(); for c in node npm claude codex tmux; do
        command -v "$c" >/dev/null 2>&1 && case ":$PATH:" in *":/mnt/.allowbin:"*)
          [ -e "/mnt/.allowbin/$c" ] || und+=("$c");; *) und+=("$c");; esac; done
       [ ${#und[@]} -eq 0 ] || { echo "reachable but undeclared: ${und[*]}"; exit 1; }; }
c13(){ [ -n "${CLEANROOM_HOST_PID:-}" ] || { echo "CLEANROOM_HOST_PID not provided; this assertion cannot be judged"; exit 1; }
       # ⚠️ This is the one assertion in the set whose GREEN can come from the wrong
       # reason: if the target process is **already dead**, `kill -0` fails too, so
       # "we are isolated" and "the target is gone" produce identical output.
       # ⇒ liveness must be attested from OUTSIDE the sandbox; from inside there is no
       # way to tell the two apart.
       # ⚠️ 本条是全套唯一一条「绿可以来自错误原因」的判据：目标进程**已死**时 kill -0
       # 也会失败，于是「隔离住了」与「目标没了」输出完全一样。⇒ 必须由箱外回验存活。
       [ "${CLEANROOM_HOST_PID_ATTESTED:-}" = 1 ] || {
         echo "CLEANROOM_HOST_PID has not been attested alive from outside the sandbox; cannot be judged (the runner must kill -0 both before and after the run)"; exit 1; }
       kill -0 "$CLEANROOM_HOST_PID" 2>/dev/null && { echo "can signal host pid $CLEANROOM_HOST_PID"; exit 1; }; exit 0; }
c14(){ local hit; hit=$(env | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | sort -u || true)
       [ -z "$hit" ] || { echo "email addresses present in the environment: $(echo "$hit" | wc -l) (masked): $(echo "$hit" | sed -E 's/^(.).*@(.).*$/\1***@\2***/' | tr '\n' ' ')"; exit 1; }; }

# C15 asks the opposite question from C1-C14. Those all ask "is anything from the
# private environment reachable?" -- they can all be green on a box that is clean AND
# cannot run this tool at all. DoD-1 is about a clean machine that WORKS, so the
# declared dependency of the switching half is asserted present, by version.
# ⭐ Everything else here is a leak check; a set made only of leak checks is silent on
#    the one thing the clean-machine claim is actually about.
# C15 问的方向与 C1–C14 相反:那些都在问「私有环境有没有漏进来」,而它们**可以在一台
# 干净但根本跑不动本工具的机器上全绿**。DoD-1 要的是「干净且能跑」,所以这里正面断言
# 切号那一半的已声明依赖存在、且版本够。
c15(){ command -v python3 >/dev/null 2>&1 || { echo "python3 not on PATH; the switching half cannot run here"; exit 1; }
       python3 - <<'PY' || exit 1
import sys
if sys.version_info < (3, 9):
    print(f"python3 is {sys.version.split()[0]}; account-switch needs >= 3.9 (zoneinfo)")
    raise SystemExit(1)
PY
       exit 0; }

ck C1  "no environment variables from that environment"  "0 of them"                          c1
ck C2  "no forwarding shim reachable on PATH"            "no name resolves into that root"    c2
ck C3  "that environment's repo root does not exist"     "its marker file is absent"          c3
ck C4  "no /root/.claude.json (in-use credentials)"      "file absent"                        c4
ck C5  "no id_* keys under /root/.ssh"                   "directory empty or absent"          c5
ck C6  "the host process table is not visible"           "visible processes <= 25"            c6
ck C7  "tmux unavailable and /tmp/tmux-0 invisible"      "neither present"                    c7
ck C8  "that environment's git root is unreachable"      "git rev-parse fails"                c8
ck C9  "HOME is not /root and is empty"                  "a brand-new empty HOME"             c9
ck C10 "no injection from /etc/profile.d"                "grep finds nothing"                 c10
ck C11 "cwd is neither in that repo nor beside it"       "neither"                            c11
ck C12 "undeclared dependencies are unreachable"         "node/npm/claude/codex/tmux all absent" c12
ck C13 "cannot signal host processes"                    "pid attested alive AND kill -0 fails" c13
ck C14 "no email address anywhere in the environment"    "0 (a direct guard for the no-real-accounts rule)" c14
ck C15 "the switching half's declared dependency is present" "python3 >= 3.9 on PATH"           c15
echo "----"; echo "cleanroom-assert: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
