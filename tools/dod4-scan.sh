#!/usr/bin/env bash
#
# DoD-4 leak scan — five explicitly declared ranges.
# DoD-4 泄漏面扫描 —— 五个显式声明的范围。
#
#   A  worktree   every file, including hidden and binary (.git excluded)
#   B  blobs      every blob in every commit — catches committed-then-deleted
#   C  messages   full commit message bodies
#   D  identity   author / committer names and emails
#   E  paths      tree entry names themselves
#
# Why the range list is printed on every run: a grep over the working tree covers
# range A only and is structurally blind to B–E. "Committed a secret, noticed,
# deleted it in the next commit" is the single most common pre-open-source leak,
# and it lives in range B where no worktree grep can ever see it. So a bare
# "DoD-4 passed" means nothing unless it also says which ranges were scanned.
# 为什么每次运行都打印范围表:只 grep 工作树等于只覆盖 A,对 B–E 结构性全盲。
# 「提交了凭据、发现了、下个 commit 删掉」是开源前最常见的一种泄漏,它就躺在
# 范围 B 里,任何工作树 grep 都永远看不见。所以脱离范围说「DoD-4 通过」没有意义。
#
# Usage:  tools/dod4-scan.sh [repo-path]      default: the repo containing this script
# Exit:   0 clean | 1 hits found | 9 setup error
#
# Positive control: tools/dod4-scan.posctrl.sh — proves each of the five ranges is
# actually traversed. A scanner that has never been shown to go red is not a check.
# 正控见 tools/dod4-scan.posctrl.sh —— 逐范围证明它会红。没红过的判据不算判据。

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-$(cd "$SELF_DIR/.." && pwd)}"

cd "$REPO" 2>/dev/null || { echo "dod4-scan: cannot enter '$REPO'" >&2; exit 9; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "dod4-scan: '$REPO' is not a git repo" >&2; exit 9; }

load_patterns() {                       # $1 = base name -> joined ERE on stdout
  local base="$1" f line joined=""
  for f in "$SELF_DIR/${base}.example.txt" "$SELF_DIR/${base}.local.txt"; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      joined="${joined:+$joined|}$line"
    done < "$f"
  done
  printf '%s' "$joined"
}

# Source list is computed in the current shell, NOT inside load_patterns: that runs
# in a command substitution, i.e. a subshell, so anything it assigns is discarded.
# The first version of this script did exactly that and printed an empty source list
# while still scanning correctly -- a scan whose declared scope is silently blank.
# 模式来源在当前 shell 里算,不放进 load_patterns:后者在命令替换(子 shell)里跑,
# 赋值会被丢弃。本脚本第一版正是如此:扫描本身没错,但声明出来的范围是空的。
list_sources() {
  local base f out=""
  for base in dod4-patterns dod4-paths dod4-identity; do
    for f in "$SELF_DIR/${base}.example.txt" "$SELF_DIR/${base}.local.txt"; do
      [ -f "$f" ] && out="$out $(basename "$f")"
    done
  done
  printf '%s' "${out# }"
}

CONTENT_PAT="$(load_patterns dod4-patterns)"
PATH_PAT="$(load_patterns dod4-paths)"
IDENT_PAT="$(load_patterns dod4-identity)"
[ -n "$CONTENT_PAT" ] && [ -n "$PATH_PAT" ] && [ -n "$IDENT_PAT" ] || {
  echo "dod4-scan: pattern files missing or empty under $SELF_DIR" >&2; exit 9; }

# The pattern files are by definition full of the strings being hunted, so they are
# excluded from the content ranges. Declared here rather than done silently — a scan
# that quietly skips files reads exactly like a scan that found nothing.
# 模式文件按定义就装满了被搜的字符串,故排除在内容范围之外。这里明写而不是静默跳过:
# 静默跳过的扫描和「扫了没发现」长得一模一样。
is_pattern_file() { case "$(basename "$1")" in dod4-patterns.*|dod4-paths.*|dod4-identity.*) return 0 ;; *) return 1 ;; esac; }

hits="$(mktemp)"; trap 'rm -f "$hits"' EXIT

# --- A: worktree, hidden + binary included. -a is mandatory: without it grep may
#        print nothing at all for a binary file, turning a hit into a silent zero.
#        -a 是必须的:不加它,grep 对二进制文件可能一个字都不打,命中被静默吞成 0。
while IFS= read -r -d '' f; do
  is_pattern_file "$f" && continue
  grep -aHnE "$CONTENT_PAT" "$f" 2>/dev/null | sed 's|^|[A-worktree] |'
done < <(find . -path ./.git -prune -o -type f -print0) >> "$hits"

# --- B: every blob in every commit, including objects no longer reachable from HEAD's tree
while read -r obj path; do
  [ "$(git cat-file -t "$obj" 2>/dev/null)" = blob ] || continue
  is_pattern_file "$path" && continue
  git cat-file -p "$obj" 2>/dev/null | grep -anE "$CONTENT_PAT" | sed "s|^|[B-blob $path] |"
done < <(git rev-list --objects --all 2>/dev/null | awk 'NF>1{print $1" "$2}') >> "$hits"

# --- C: commit messages, full body
git log --all --format='%H %B' 2>/dev/null | grep -anE "$CONTENT_PAT" | sed 's|^|[C-message] |' >> "$hits"

# --- D: author / committer identities, checked against IDENT_PAT (see that file for why)
git log --all --format='%an <%ae>|%cn <%ce>' 2>/dev/null | tr '|' '\n' | sort -u \
  | grep -aE "$IDENT_PAT" | sed 's|^|[D-identity] |' >> "$hits"

# --- E: tree entry names
git rev-list --objects --all 2>/dev/null | awk 'NF>1{print $2}' | sort -u \
  | grep -aE "$PATH_PAT" | sed 's|^|[E-path] |' >> "$hits"

echo "repo:    $REPO"
echo "ranges:  A worktree | B blobs(incl. deleted) | C messages | D identity | E paths"
echo "sources: $(list_sources)"
echo "skipped: files named dod4-{patterns,paths,identity}.* (they hold the patterns themselves)"
echo "---"
cat "$hits"
n=$(wc -l < "$hits" | tr -d ' ')
echo "---"
if [ "$n" -eq 0 ]; then echo "SCAN_RESULT=CLEAN hits=0 ranges=A,B,C,D,E"; exit 0
else echo "SCAN_RESULT=DIRTY hits=$n ranges=A,B,C,D,E"; exit 1; fi
