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
# Exit:   0 clean (with site patterns) | 1 hits found | 3 clean but EXAMPLE PATTERNS ONLY
#         | 9 setup error
#
# 🔴 Why exit 3 exists.
#    The site-local pattern files are gitignored by construction, and the example ones
#    are committed. So on ANY fresh clone the pattern set is non-empty but contains none
#    of the strings this repository actually needs to keep out -- and the old code only
#    refused to run when the pattern set was *entirely* empty. The result was a scan that
#    printed a verdict identical, character for character, to a properly configured run:
#    `SCAN_RESULT=CLEAN hits=0`. On the clean machine of DoD-1, and on whatever machine
#    runs the regression suite, that verdict was unconditionally true.
#    ⭐ A check that cannot fail is not evidence, and one that is worded exactly like the
#    real thing is worse than no check: it is a real check's output with nothing behind it.
# 🔴 为什么有 exit 3。站点本地模式文件按构造被 gitignore、example 那份已提交 ⇒ **任何 clone**
#    上模式集都非空、却不含本仓真正要挡的那些串,而旧代码只在模式集**全空**时才拒绝运行。
#    于是它印出的判词与配置正确的那一次**逐字相同**:`SCAN_RESULT=CLEAN hits=0`。
#    在 DoD-1 那台干净机器上、在跑回归的任何一台机器上,这句判词是**恒真**的。
#    ⭐ 不可能失败的检查不是证据;而措辞与真检查一字不差的那种,比没有检查更糟——
#    它是一份真检查的输出,后面什么都没有。
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
list_allow() {
  local f out=""
  for f in "$SELF_DIR/dod4-allow.example.txt" "$SELF_DIR/dod4-allow.local.txt"; do
    [ -f "$f" ] && out="$out $(basename "$f")"
  done
  printf '%s' "${out# }"
}

list_sources() {
  local base f out=""
  for base in dod4-patterns dod4-paths dod4-identity; do
    for f in "$SELF_DIR/${base}.example.txt" "$SELF_DIR/${base}.local.txt"; do
      [ -f "$f" ] && out="$out $(basename "$f")"
    done
  done
  printf '%s' "${out# }"
}

# Is ANY site-local pattern file present? This is what separates a scan that could
# actually find something from one that merely cannot fail.
have_site_patterns() {
  local base
  for base in dod4-patterns dod4-paths dod4-identity dod4-allow; do
    [ -f "$SELF_DIR/${base}.local.txt" ] && return 0
  done
  return 1
}

ALLOW_PAT="$(load_patterns dod4-allow)"     # may legitimately be empty / 允许为空
CONTENT_PAT="$(load_patterns dod4-patterns)"
PATH_PAT="$(load_patterns dod4-paths)"
IDENT_PAT="$(load_patterns dod4-identity)"
PATH_ALLOW_PAT="$(load_patterns dod4-paths-allow)"   # range E only; may be empty
[ -n "$CONTENT_PAT" ] && [ -n "$PATH_PAT" ] && [ -n "$IDENT_PAT" ] || {
  echo "dod4-scan: pattern files missing or empty under $SELF_DIR" >&2; exit 9; }

# The pattern files are by definition full of the strings being hunted, so they are
# excluded from the content ranges. Declared here rather than done silently — a scan
# that quietly skips files reads exactly like a scan that found nothing.
# 模式文件按定义就装满了被搜的字符串,故排除在内容范围之外。这里明写而不是静默跳过:
# 静默跳过的扫描和「扫了没发现」长得一模一样。
# ⚠️ `*.local.txt` under tools/ is skipped too. Those files are the site-local pattern
#    lists and the real-name -> placeholder table: their contents ARE the strings being
#    hunted, so scanning them makes the scanner match itself and go **permanently red**
#    — and a check that is always red teaches people to click past red. They are
#    gitignored by construction (see .gitignore), so they cannot reach ranges B-E.
#    Residual risk, stated rather than hidden: a real secret parked in one of those
#    files is not scanned. It also cannot be committed.
# ⚠️ tools/ 下的 `*.local.txt` 也跳过。那是站点本地模式表与真名->占位符对照表,内容**就是**
#    被搜的那些串,扫它们会让扫描器匹配到自己而**恒红**——而一条永远红的检查会训练出
#    「看到红也照过」。它们按构造已被 gitignore,进不了范围 B-E。
#    残余风险(写出来而不是藏起来):放在那些文件里的真凭据不会被扫到;它也提交不上去。
is_pattern_file() {
  case "$1" in */tools/*.local.txt|./tools/*.local.txt|tools/*.local.txt) return 0 ;; esac
  case "$(basename "$1")" in dod4-patterns.*|dod4-paths.*|dod4-paths-allow.*|dod4-identity.*|dod4-allow.*) return 0 ;; *) return 1 ;; esac
}

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
#     The path-allow list is applied HERE and only here. It excuses a NAME, never any
#     content: a file listed there is still scanned by ranges A and B like any other.
#     See tools/dod4-paths-allow.example.txt for why a rename cannot be used instead.
#     路径豁免只在这里生效,且只赦免**名字**:列进去的文件在范围 A/B 里照扫不误。
git rev-list --objects --all 2>/dev/null | awk 'NF>1{print $2}' | sort -u \
  | grep -aE "$PATH_PAT" \
  | { if [ -n "$PATH_ALLOW_PAT" ]; then grep -avE "$PATH_ALLOW_PAT"; else cat; fi; } \
  | sed 's|^|[E-path] |' >> "$hits"

# --- Allowance pass. NOT a line-level ignore: each hit line has the allowed
#     substrings deleted and is then re-tested against CONTENT_PAT, so a line that also
#     carries a real secret still survives. A line-level ignore is how an allowlist
#     turns into a silent hole, and this file exists to not have one.
#     ⚠️ Ranges D and E are deliberately NOT filtered. D is author identity and E is
#     path names; neither can contain a documentation placeholder for a good reason,
#     and narrowing the filter is free here.
# --- 白名单过滤。**不是**逐行忽略:每条命中行先删掉白名单子串,再拿 CONTENT_PAT 重测,
#     所以同一行里若还有真凭据,它照样留下来。逐行忽略正是白名单变成静默漏洞的方式。
#     ⚠️ 范围 D/E 刻意不过滤:一个是作者身份、一个是路径名,都不该出现文档占位符。
if [ -n "$ALLOW_PAT" ]; then
  kept="$(mktemp)"
  while IFS= read -r line; do
    case "$line" in
      '[D-identity]'*|'[E-path]'*) printf '%s\n' "$line" >> "$kept"; continue ;;
    esac
    # ⚠️ The match is a here-string, not the tail of a pipe. Under `set -o pipefail`
    #    (set at the top of this file) a `grep -q` that exits on its first match leaves
    #    the upstream stage writing into a closed pipe; that stage dies of SIGPIPE and
    #    the pipeline reports 141 **even though the pattern matched** — so a real hit
    #    would be silently dropped from the results and the scan would print CLEAN.
    #    ⚠️ Honest scope: unlike the detectors in lib/, this particular shape was NOT
    #    reproduced here (360 attempts across two input sizes, zero drops — the
    #    producer is `sed`, not bash's builtin `printf`). It is hardened anyway because
    #    the failure direction is a silent DoD-4 pass, which is the one direction where
    #    nobody goes looking.
    # ⚠️ 这里用 here-string 而不是管道末端。本文件开着 pipefail，而 grep -q 一命中就退出，
    #    上游写进已关闭的管道 → SIGPIPE → **整条管道回报 141，尽管命中了** ⇒ 一条真命中会被
    #    悄悄从结果里丢掉，扫描印出 CLEAN。⚠️ 口径要诚实：与 lib/ 里那几处不同，这个形状
    #    **没能复现**（两种输入尺寸共 360 次，零丢失；这里的上游是 sed，不是 bash 内建
    #    printf）。仍然加固，因为它的失效方向是「静默的 DoD-4 通过」——那正是没人会去查的方向。
    _line_filtered=$(printf '%s' "$line" | sed -E "s/$ALLOW_PAT//g")
    if grep -qaE "$CONTENT_PAT" <<<"$_line_filtered"; then
      printf '%s\n' "$line" >> "$kept"
    fi
  done < "$hits"
  mv -f "$kept" "$hits"
fi

echo "repo:    $REPO"
echo "ranges:  A worktree | B blobs(incl. deleted) | C messages | D identity | E paths"
echo "sources: $(list_sources)"
echo "allowed: $( [ -n "$ALLOW_PAT" ] && echo "$(list_allow) (deleted from a line, then the line is re-tested)" || echo "(none)" )"
echo "skipped: dod4-{patterns,paths,identity,allow}.* and tools/*.local.txt (they hold the patterns themselves; all gitignored)"
echo "path-allow: $( [ -n "$PATH_ALLOW_PAT" ] && echo "dod4-paths-allow.* (range E names only; contents still scanned)" || echo "(none)" )"
echo "---"
cat "$hits"
n=$(wc -l < "$hits" | tr -d ' ')
echo "---"
if [ "$n" -gt 0 ]; then
  echo "SCAN_RESULT=DIRTY hits=$n ranges=A,B,C,D,E patterns=$(have_site_patterns && echo site || echo example-only)"
  exit 1
fi
if have_site_patterns; then
  echo "SCAN_RESULT=CLEAN hits=0 ranges=A,B,C,D,E patterns=site"
  exit 0
fi
# Clean, but with nothing site-specific to be clean OF. Said out loud, and with a
# distinct exit status, so a caller cannot mistake it for a configured pass.
echo "SCAN_RESULT=CLEAN-BUT-UNCONFIGURED hits=0 ranges=A,B,C,D,E patterns=example-only" >&2
echo "dod4-scan: no tools/*.local.txt present, so this scan searched only the published" >&2
echo "dod4-scan: example patterns. It cannot have found the real strings of this repo." >&2
echo "dod4-scan: see docs/REDACTION.md for what belongs in each local file." >&2
exit 3
