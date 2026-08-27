#!/usr/bin/env bash
#
# Positive control for tools/dod4-scan.sh.
# tools/dod4-scan.sh 的正控。
#
# Injects one marker per range into a throwaway clone and requires ALL FIVE ranges
# to come back red. A scanner that has never been observed to go red is not a check
# — "0 hits" from an unproven scanner and "0 hits" from a range it never walked are
# the same output. Injecting a single file into the working tree only proves range A;
# it says nothing about B–E, which is exactly where the dangerous leaks sit.
# 往一次性 clone 里逐范围注入一个标记,要求五个范围**全部**转红。没红过的判据不算判据:
# 「未验证的扫描器报 0」和「压根没走到那个范围报 0」输出完全一样。只往工作树扔一个文件
# 只能证明范围 A,对 B–E 一个字都没说——而危险的泄漏恰恰在 B–E。
#
# Usage: tools/dod4-scan.posctrl.sh [repo-path]
# Exit:  0 all five ranges fired | 1 at least one range never fired | 9 setup error
#
# POSCTRL_ABLATE=<A|A-bin|B|C|D|E> plants every marker EXCEPT that one. The matching
# check must then go red, and every other check must stay green. This is the negative
# control for the control: a check that has never been observed to fail is not a check
# either, and the bug fixed on 2026-08-27 (see check() below) was exactly a check that
# could report a range green without that range having produced anything.
# POSCTRL_ABLATE=<A|A-bin|B|C|D|E> 只少种一个标记,对应那格必须转红、其余五格必须仍绿。
# 这是「给正控做的负控」:没红过的判据不算判据,对正控本身同样成立——2026-08-27 修掉的
# 那个 bug 正是「某格没产出任何东西,判据照样报绿」。

set -uo pipefail

ABLATE="${POSCTRL_ABLATE:-}"
case "$ABLATE" in
  ''|A|A-bin|B|C|D|E) ;;
  *) echo "posctrl: POSCTRL_ABLATE must be one of A A-bin B C D E (got '$ABLATE')" >&2; exit 9 ;;
esac
[ -n "$ABLATE" ] && echo "posctrl: ABLATION MODE -- range $ABLATE marker withheld; that range MUST go red." >&2

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-$(cd "$SELF_DIR/.." && pwd)}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dod4-posctrl.XXXXXX")" || exit 9
trap 'rm -rf "$WORK"' EXIT

git clone -q "$REPO" "$WORK/clone" 2>/dev/null || { echo "posctrl: clone failed" >&2; exit 9; }
cd "$WORK/clone" || exit 9
git config user.name  'POSCTRL-D-MARKER'
# Deliberately not an email-shaped string: dod4-scan.sh flags anything that looks
# like an address, on purpose, and this file must not permanently redden the scan
# of its own repo. git does not validate user.email, so a bare marker is fine.
# 刻意不用邮箱形状的串:dod4-scan.sh 有意咬住一切像地址的东西,而本文件不该让自己
# 所在仓的扫描恒红。git 不校验 user.email,裸标记即可。
git config user.email 'POSCTRL-D-MARKER'
if [ "$ABLATE" = D ]; then
  git config user.name  'ABLATED-IDENTITY'
  git config user.email 'ABLATED-IDENTITY'
fi

# Precondition: the scanner must exist INSIDE the clone, i.e. be committed. If it is
# only in the working tree, every range below would report SILENT and the message
# would blame traversal for what is really a missing file -- a failure text that
# describes the logic under test and never mentions the path is how a setup error
# gets misread as a real defect.
# 前置检查:扫描器必须存在于 clone 内(即已提交)。否则下面五个范围会全报 SILENT,
# 而文案会把「文件不存在」说成「遍历没走到」——失败文案只谈被测逻辑、不提路径,
# 正是环境错误被误读成真缺陷的典型路径。
if [ ! -f tools/dod4-scan.sh ]; then
  echo "posctrl: tools/dod4-scan.sh is absent from the clone of '$REPO'." >&2
  echo "posctrl: it exists in the working tree but is not committed, so the clone cannot see it." >&2
  echo "posctrl: commit tools/ first, then re-run. (This is a setup error, not a scan result.)" >&2
  exit 9
fi

# Site-local pattern files (gitignored, so they are never committed). Using a marker
# instead of a real secret keeps the control self-contained and safe to run anywhere.
mkdir -p tools
echo 'POSCTRL-[A-Z]-MARKER'  > tools/dod4-patterns.local.txt
echo 'POSCTRL-E-MARKER'      > tools/dod4-paths.local.txt
echo 'POSCTRL-D-MARKER'      > tools/dod4-identity.local.txt

# B — committed, then deleted. Invisible to any working-tree grep, still in the pack.
if [ "$ABLATE" != B ]; then
  echo 'POSCTRL-B-MARKER' > transient.txt
  git add transient.txt && git commit -qm 'posctrl B stage 1: add'
  git rm -q transient.txt && git commit -qm 'posctrl B stage 2: remove'
fi

# E — the path itself carries the marker; file content is harmless.
E_FILE='POSCTRL-E-MARKER.txt'
[ "$ABLATE" = E ] && E_FILE='posctrl-e-ablated.txt'
echo 'nothing sensitive in here' > "$E_FILE"
git add "$E_FILE" && git commit -qm 'posctrl E: path name'

# C — marker exists only in the commit message, in no file at any revision.
C_MSG='posctrl C: POSCTRL-C-MARKER appears only in this message'
[ "$ABLATE" = C ] && C_MSG='posctrl C: ablated, this message carries no marker'
echo 'still harmless' >> "$E_FILE"
git add -A && git commit -qm "$C_MSG"

# The identity that actually landed is asserted, not assumed. `git config` can fail
# (a concurrent writer holding .git/config.lock) and GIT_AUTHOR_*/GIT_COMMITTER_* in the
# environment override it outright -- in both cases range D emits nothing and the
# verdict below would read "range D is blind" for a reason that has nothing to do with
# the scanner. Same principle as the tools/dod4-scan.sh precondition above: a setup
# error must not be dressed up as a scan result.
# 落到 commit 上的身份要断言,不能假定:git config 可能失败(并发 writer 占着
# .git/config.lock),环境里的 GIT_AUTHOR_*/GIT_COMMITTER_* 更是直接压过它——两种情况下
# range D 都不会产出,而下面的判词会读成「range D 瞎了」,原因却与扫描器无关。
# 与上面 tools/dod4-scan.sh 那道前置检查同理:环境错误不许打扮成扫描结果。
want_id='POSCTRL-D-MARKER'
[ "$ABLATE" = D ] && want_id='ABLATED-IDENTITY'
got_id="$(git log -1 --format='%cn|%ce')"
if [ "$got_id" != "$want_id|$want_id" ]; then
  echo "posctrl: the clone's commits were authored as '$got_id', not '$want_id|$want_id'." >&2
  echo "posctrl: git config was overridden (GIT_AUTHOR_*/GIT_COMMITTER_* in the environment?)" >&2
  echo "posctrl: or could not be written. Range D cannot be exercised this way." >&2
  echo "posctrl: (This is a setup error, not a scan result.)" >&2
  exit 9
fi

# A — hidden file, and a binary file. The binary one is the reason dod4-scan.sh uses
#     grep -a: without it grep can stay completely silent on binary matches.
[ "$ABLATE" = A     ] || printf 'POSCTRL-A-MARKER\n' > .hidden-posctrl
[ "$ABLATE" = A-bin ] || printf '\x00\x01 POSCTRL-A-MARKER \x00\xff\n' > posctrl-blob.bin

# Run the CLONE's own copy, not this repo's: dod4-scan.sh resolves its pattern files
# relative to its own location, so invoking the original would read the original's
# patterns and never see the markers planted here -- every range would report SILENT
# for a reason that has nothing to do with traversal.
# 跑 clone 自己那份,不是本仓这份:dod4-scan.sh 按自身位置解析模式文件,跑原仓那份会读到
# 原仓的模式、看不见这里种下的标记——五个范围会全报 SILENT,而原因与遍历毫无关系。
# tr -d '\0': range A matches inside the binary fixture, and command substitution
# warns on NUL bytes. The warning is harmless but noisy in a control's output.
# tr -d '\0':范围 A 会在二进制夹具里命中,而命令替换遇 NUL 会告警。告警无害,
# 但正控的输出里不该有看着像出错的噪音。
out="$(bash "$WORK/clone/tools/dod4-scan.sh" "$WORK/clone" 2>&1 | tr -d '\0')"; rc=$?
# 🔴 The scan output is printed with non-printable bytes replaced, not raw.
#    The range-A fixture is deliberately binary, and `tr -d "\0"` above removes only the
#    NULs -- the 0xff survives, which is enough for grep to classify this whole file as
#    binary in a UTF-8 locale. The consequence is not cosmetic: the most natural way to
#    consume this script is
#        grep -q "POSCTRL_RESULT=FAIL" posctrl.log && exit 1
#    and on a raw log that grep returns 1 without printing anything, so the failure
#    branch NEVER fires. A control whose own output cannot be read by the thing checking
#    it is a false green, and it fails in the safe-looking direction.
#    ⭐ The earlier code knew about the NUL warning and fixed exactly that -- the noise --
#    while leaving the byte that changes how every later reader treats the stream.
# 🔴 扫描输出印出来时把不可打印字节替换掉,不原样吐。范围 A 的夹具刻意是二进制,
#    上面的 `tr -d "\0"` 只删了 NUL,0xff 还在——在 UTF-8 locale 下足以让 grep 把整份
#    输出判为二进制。后果不是观感问题:消费本脚本最自然的写法是
#        grep -q "POSCTRL_RESULT=FAIL" posctrl.log && exit 1
#    而在原始日志上这条 grep 什么都不打、返回 1 ⇒ **失败分支永远不会触发**。
#    自己的输出没法被检查它的东西读到,这是假绿,而且是往「看起来没事」那个方向坏。
#    ⭐ 旧代码知道 NUL 告警那一层并且正好修了它——修的是噪音——却留下了那个真正改变
#    后续所有读者如何对待这条流的字节。
printf '%s\n' "$out" | LC_ALL=C sed 's/[^[:print:]\t]/?/g'
echo "=== posctrl verdict ==="

# Each range is checked against the ONE piece of evidence only that range can produce.
# Checking merely for the tag would be far weaker: this script's own source contains
# every marker as a literal, so "[B-blob" would light up from the script's own blob --
# a file that is still present in the working tree, which proves nothing about B's
# unique reach. The decisive B evidence is transient.txt, deleted from HEAD.
# 每个范围只认「唯有该范围能产出」的那一条证据。只查标签会弱得多:本脚本正文里就写着
# 全部标记,于是 "[B-blob" 会被脚本自己的 blob 点亮——那文件在工作树里还在,对 B 的独有
# 能力什么都没证明。B 的决定性证据是已从 HEAD 删除的 transient.txt。
fail=0

# Two defects were fixed here on 2026-08-27; both made a check answer a question other
# than the one it was asked. Keep the shape below or they come straight back.
#
# (1) NO PIPE. The old form was `printf '%s' "$out" | grep -qF "$2"`. `grep -q` exits at
#     the first match and closes the pipe, while bash's printf builtin flushes through
#     stdio in 4096-byte chunks -- so for any output over 4096 bytes (a normal run is
#     ~4.8KB, and the first match sits at byte ~491) the second write takes SIGPIPE and
#     the left-hand side exits 141. `set -o pipefail` above then makes the whole
#     pipeline non-zero, and a range that DID fire is printed as SILENT. Measured
#     directly: PIPESTATUS=[141,0] -- printf killed, grep matched -- 8 times in 400 runs
#     idle, and markedly worse under process pressure, which is why it looked like it
#     followed heavy git operations. It was never range-specific and never the
#     scanner's fault: in every captured failure the "absent" evidence was present in
#     the very output being searched. A here-string has no reader to outlive.
#
# (2) ANCHORED, POSITIONED EVIDENCE. This script's source contains every check string as
#     a literal, and ranges A and B scan this file inside the clone -- so an unanchored
#     search for "[D-identity] POSCTRL-D-MARKER" was satisfied by this file's own check
#     line echoed back through range A, whether or not range D produced anything.
#     Measured: with the commit identity overridden so range D emitted nothing at all,
#     the old check still printed "fired OK". Each pattern below therefore pins the
#     range tag to the start of the line AND the payload to the position that range's
#     real output puts it in, so no other range's line can stand in for it. The comment
#     at the top of this block already warned about exactly this for range B; the fix
#     it describes was simply never applied to the other five.
#
# (1) 不要管道:旧写法 `printf '%s' "$out" | grep -qF "$2"`。grep -q 命中即退出并关闭管道,
#     而 bash 的 printf 内建按 4096 字节分批刷出——输出超过 4096 字节时(正常一轮约 4.8KB,
#     首个命中在约第 491 字节),第二次写就吃到 SIGPIPE、左侧退出 141;上面的 pipefail 把
#     整条管道判为非零,于是**真的红过的那一格被印成 SILENT**。实测 PIPESTATUS=[141,0]
#     ——printf 被杀、grep 命中——空载 400 次里 8 次,进程压力下明显更频繁,所以看起来像是
#     「跟在重 git 操作后面」。它既不挑范围,也不是扫描器的错:每一次抓到的失败里,被判
#     「不存在」的证据都**就在**被搜的那份输出里。here-string 没有会被熬死的读端。
# (2) 锚定并定位证据:本脚本正文写着全部判据字符串,而范围 A/B 会扫到 clone 里的本文件
#     ——不锚定地搜 "[D-identity] POSCTRL-D-MARKER",范围 A 回显的本文件判据行就能满足它,
#     无论 range D 有没有产出。实测:把 commit 身份改掉、range D 一个字都没产出时,旧判据
#     照样印 "fired OK"。所以下面每条都把范围标签锚在行首、把载荷钉在该范围真实输出里的
#     位置,别的范围的行顶替不了。本块顶部的注释早就为范围 B 讲过这件事,只是那个修法
#     从没被套用到另外五格。
# (3) The line that MATCHED is printed, not just the verdict. Both defects above could
#     only survive because "POSCTRL_RESULT=PASS" was a bare summary: it asserted that
#     six ranges had fired without ever showing what any of them produced, so a check
#     answering the wrong question read exactly like a check answering the right one.
#     A reader can now tie every green line to the specific output that made it green.
# (3) 印出**命中的那一行**,不只印判词。上面两个缺陷之所以能活下来,正因为
#     "POSCTRL_RESULT=PASS" 是个光秃秃的汇总:它声称六格都红过,却从不出示任何一格到底
#     产出了什么——于是「答错问题的判据」和「答对问题的判据」读起来一模一样。
#     现在每一条绿都能被追回到让它变绿的那一行输出。
check() {                               # $1 label, $2 anchored ERE evidence, $3 why
  local hit
  if hit="$(grep -aE -m1 -e "$2" <<< "$out")"; then
    printf '  RANGE %-12s fired  OK   (%s)\n' "$1" "$3"
    # LC_ALL=C so [:print:] is judged byte-wise: the range A fixture is deliberately
    # binary, and in a UTF-8 locale its stray bytes slip through the class and get
    # dumped raw into the log. / LC_ALL=C 让 [:print:] 按字节判定:范围 A 的夹具刻意是
    # 二进制,UTF-8 locale 下它那些杂字节会漏过字符类、原样吐进日志。
    printf '  %-14s   evidence: %.96s\n' '' "$(printf '%s' "$hit" | LC_ALL=C sed 's/[^[:print:]]/?/g')"
  else
    printf '  RANGE %-12s SILENT **  expected evidence absent: %s\n' "$1" "$2"; fail=1
  fi
}
check A-worktree '^\[A-worktree\] \./\.hidden-posctrl:'    'hidden file'
check A-binary   '^\[A-worktree\] \./posctrl-blob\.bin:'   'binary file -- proves grep -a'
check B-blob     '^\[B-blob transient\.txt\] '             'deleted from HEAD, still in the pack'
check C-message  '^\[C-message\] .*posctrl C: POSCTRL-C-MARKER appears only in this message$' 'commit message only'
check D-identity '^\[D-identity\] POSCTRL-D-MARKER <POSCTRL-D-MARKER>$' 'committer identity'
check E-path     '^\[E-path\] POSCTRL-E-MARKER\.txt$'      'path name itself'

# The scan must also have reported failure overall; a control that fires per-range
# but still exits 0 would mean the verdict logic, not the traversal, is broken.
if [ "$rc" -ne 1 ]; then
  echo "  VERDICT       : scan exited $rc, expected 1 (DIRTY)"; fail=1
else
  echo "  VERDICT       : scan exited 1 (DIRTY)  OK"
fi

# The verdict carries which pattern set the scan underneath it was actually using.
# A PASS says the scanner can go red; it says nothing about whether that particular run
# was configured to look for anything real. Those are different claims and used to be
# reported as one.
# 判词带上「底下那次扫描用的是哪一份模式集」。PASS 说的是「扫描器能红」,
# 它没说那一轮到底配没配上真要找的东西——这是两个断言,以前被合成了一个。
pattern_src=example-only
for b in dod4-patterns dod4-paths dod4-identity dod4-allow; do
  [ -f "$WORK/clone/tools/${b}.local.txt" ] && { pattern_src=site; break; }
done
[ "$fail" -eq 0 ] && { echo "POSCTRL_RESULT=PASS (all five ranges proven to go red) patterns=$pattern_src"; exit 0; }
echo "POSCTRL_RESULT=FAIL (at least one range is blind) patterns=$pattern_src"; exit 1
