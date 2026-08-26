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

set -uo pipefail

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
echo 'POSCTRL-B-MARKER' > transient.txt
git add transient.txt && git commit -qm 'posctrl B stage 1: add'
git rm -q transient.txt && git commit -qm 'posctrl B stage 2: remove'

# E — the path itself carries the marker; file content is harmless.
echo 'nothing sensitive in here' > 'POSCTRL-E-MARKER.txt'
git add 'POSCTRL-E-MARKER.txt' && git commit -qm 'posctrl E: path name'

# C — marker exists only in the commit message, in no file at any revision.
echo 'still harmless' >> 'POSCTRL-E-MARKER.txt'
git add -A && git commit -qm 'posctrl C: POSCTRL-C-MARKER appears only in this message'

# A — hidden file, and a binary file. The binary one is the reason dod4-scan.sh uses
#     grep -a: without it grep can stay completely silent on binary matches.
printf 'POSCTRL-A-MARKER\n' > .hidden-posctrl
printf '\x00\x01 POSCTRL-A-MARKER \x00\xff\n' > posctrl-blob.bin

# Run the CLONE's own copy, not this repo's: dod4-scan.sh resolves its pattern files
# relative to its own location, so invoking the original would read the original's
# patterns and never see the markers planted here -- every range would report SILENT
# for a reason that has nothing to do with traversal.
# 跑 clone 自己那份,不是本仓这份:dod4-scan.sh 按自身位置解析模式文件,跑原仓那份会读到
# 原仓的模式、看不见这里种下的标记——五个范围会全报 SILENT,而原因与遍历毫无关系。
out="$(bash "$WORK/clone/tools/dod4-scan.sh" "$WORK/clone" 2>&1)"; rc=$?
echo "$out"
echo "=== posctrl verdict ==="

fail=0
for tag in '\[A-worktree\]' '\[B-blob' '\[C-message\]' '\[D-identity\]' '\[E-path\]'; do
  label="$(printf '%s' "$tag" | tr -d '\\[]')"
  if printf '%s' "$out" | grep -qE "$tag"; then
    echo "  RANGE ${label} : fired  OK"
  else
    echo "  RANGE ${label} : SILENT -- this range was never traversed"; fail=1
  fi
done

# The scan must also have reported failure overall; a control that fires per-range
# but still exits 0 would mean the verdict logic, not the traversal, is broken.
if [ "$rc" -ne 1 ]; then
  echo "  VERDICT       : scan exited $rc, expected 1 (DIRTY)"; fail=1
else
  echo "  VERDICT       : scan exited 1 (DIRTY)  OK"
fi

[ "$fail" -eq 0 ] && { echo "POSCTRL_RESULT=PASS (all five ranges proven to go red)"; exit 0; }
echo "POSCTRL_RESULT=FAIL (at least one range is blind)"; exit 1
