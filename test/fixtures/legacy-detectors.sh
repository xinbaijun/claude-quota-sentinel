# legacy-detectors.sh — the pre-refactor detectors, frozen. / 重构前的旧判据，冻结件。
#
# WHAT THIS IS / 这是什么
# ----------------------------------------------------------------------
# Four functions and six regexes as they existed **before** the rewrite this project
# came out of. They are dead code here: nothing in the tool calls them. They exist so
# that the regression suite can assert, for each of three real incidents, that the old
# detector **actually got it wrong** on the same input the new one gets right.
# 这是本项目所源出的那次重写**之前**的四个函数与六条正则。它们在本仓是死代码，工具不调用
# 它们。它们存在的唯一理由是：让回归套件对三次真实事故逐条断言「旧判据在这个输入上确实错」，
# 而新判据在同一输入上对。
#
# WHY IT IS A FILE AND NOT A `git show` / 为什么是文件而不是 `git show`
# ----------------------------------------------------------------------
# Upstream, the control group was fetched live: `git show <sha>:scripts/sentinel-daemon`
# against the private repository, with `|| exit 1` **before any test case ran**. That
# commit does not exist in this repository and never will, so the whole suite would
# have exited 1 on line one. Freezing the text here is what lets the control group
# survive the move.
# 上游的对照组是现取的：对着私有仓 `git show <sha>:scripts/sentinel-daemon`，且
# `|| exit 1` 发生在**任何一条用例之前**。那个 commit 在本仓不存在、也不会存在，
# 于是整套回归会在第一行就退出 1。把文本冻在这里，对照组才活得过这次搬迁。
#
# PROVENANCE — the four things a hash cannot tell you / 哈希答不了的四件事
# ----------------------------------------------------------------------
#   1. source commit / 来源 SHA : 54bcfa0d0bbecab6bd85c95fd69c356037cc1503
#      (short `54bcfa0`; it is `5ae5d8e^`, the parent of the extraction refactor and
#       therefore the last commit that still carried the old quota detectors)
#   2. source path  / 来源路径 : scripts/sentinel-daemon
#      ⚠️ that path is in the ORIGINAL private repository. It does not exist here, and
#         you will not find it by searching this repo. / 那是**原仓**里的路径，本仓没有。
#   3. how it was taken / 取得命令 (re-runnable on a machine that has the source repo):
#         git show 54bcfa0:scripts/sentinel-daemon > /tmp/old
#         { grep -E '^IDLE_CURSOR_REGEX=' /tmp/old
#           grep -E '^(USAGE_MENU_OPT1_REGEX|USAGE_MENU_OPT2_REGEX|USAGE_MENU_FOOTER_REGEX|USAGE_BANNER_REGEX|USAGE_RESET_TIME_REGEX)=' /tmp/old
#           echo; sed -n '/^usage_menu_present() {/,/^}/p'      /tmp/old
#           echo; sed -n '/^tail_after_last_dot() {/,/^}/p'     /tmp/old
#           echo; sed -n '/^usage_banner_active() {/,/^}/p'     /tmp/old
#           echo; sed -n '/^parse_usage_reset_epoch() {/,/^}/p' /tmp/old
#         } | sha256sum
#      Whole-file fingerprint of that `git show` output, for cross-checking:
#         sha256 dc3b0bdaa08ec14dd375f108afa36f7b367c3a75dd28bac726100d0c4cea0ff1  (2224 lines)
#   4. when, and by whom / 取得时刻与执行者 : 2026-08-28 10:52 +0800, by the milestone
#      that migrated this suite; taken on the machine that holds the source repository.
#
# ⚠️ WHAT THE HASH DOES AND DOES NOT PROVE / 哈希证明什么、不证明什么
# ----------------------------------------------------------------------
#   proves      : this text has not been edited since it was frozen (integrity).
#   proves      : two readers of this file are reading the same bytes.
#   DOES NOT    : that the text matches the real upstream history (correctness). If the
#                 freeze copied the wrong thing, the hash protects the mistake just as
#                 faithfully. That is what item 3 above is for — re-run it and compare.
#   DOES NOT    : that the original is still retrievable (availability). A checksum
#                 guards integrity, not availability; the only defence against loss is a
#                 second copy of the bytes, not a second copy of the hash. **The private
#                 repository is the only other copy of these four functions**, and the
#                 assertion in the test suite will keep passing long after that repo is
#                 gone, because it only ever compares this file against itself.
#                 ⇒ that is why the text below is embedded in full rather than
#                   referenced. It is short; losing it is not worth saving 37 lines.
#   保证：自冻结以来没被改过；两个读者读到同一份字节。
#   不保证：与上游真实历史一致（冻错了，哈希会忠实地保护那个错误 —— 用第 3 条复核）。
#   不保证：原件还取得回来。校验值保完整性不保可得性；要可得就得有第二份**实体**，
#           不是第二个哈希。私有仓是这四个函数**仅存的**另一份副本，而套件里那条断言
#           在原仓消失之后仍会照常通过 —— 它只拿这份文件和它自己比。⇒ 所以下面是全文
#           内嵌而不是引用：一共 37 行，为省这点篇幅而承担丢失风险不划算。
#
# ⚠️ NO ESCAPE HATCH / 没有逃生口
# ----------------------------------------------------------------------
# Upstream this was `OLD_REF="${OLD_REF:-54bcfa0}"` — overridable from the environment.
# That is deliberately gone. An overridable control group is one `OLD_REF=HEAD` away
# from silently comparing the new detector against itself, which is green, fast, and
# meaningless. Change the text here and the suite goes red on the checksum.
# 上游那句是可被环境变量覆盖的 `OLD_REF`。这里**刻意去掉**：一个可覆盖的对照组，离
# 「拿新判据和它自己比」只差一个环境变量，而那是绿的、快的、毫无意义的。

# ── The frozen text, verbatim. Do not reformat; the checksum covers every byte. ──
# ── 冻结原文，逐字节。不要重排格式，校验值覆盖每一个字节。──
QS_LEGACY_SRC=$(cat <<'LEGACY_EOF'
IDLE_CURSOR_REGEX='^[^[:alnum:]]*❯[^[:alnum:]]*$'
USAGE_MENU_OPT1_REGEX='1\.[[:space:]]+Stop and wait for limit to reset'
USAGE_MENU_OPT2_REGEX='2\.[[:space:]]+Switch to usage credits'
USAGE_MENU_FOOTER_REGEX='Enter to confirm.*Esc to cancel'
USAGE_BANNER_REGEX="You.{0,3}ve hit your [A-Za-z0-9 -]*limit"
USAGE_RESET_TIME_REGEX='resets( at)? [0-9]{1,2}(:[0-9]{2})?[[:space:]]?(am|pm)'

usage_menu_present() {
  local t="$1" t20
  printf '%s\n' "$t" | tail -10 | grep -qE "$IDLE_CURSOR_REGEX" && return 1
  t20=$(printf '%s\n' "$t" | tail -20)
  echo "$t20" | grep -qE "$USAGE_MENU_OPT1_REGEX" || return 1
  echo "$t20" | grep -qE "$USAGE_MENU_OPT2_REGEX" || return 1
  printf '%s\n' "$t" | tail -8 | grep -qE "$USAGE_MENU_FOOTER_REGEX"
}

tail_after_last_dot() {
  printf '%s\n' "$1" | tac | awk '/^●[[:space:]]/{exit} {print}'
}

usage_banner_active() {
  tail_after_last_dot "$1" | grep -qE "$USAGE_BANNER_REGEX"
}

parse_usage_reset_epoch() {
  local text="$1" m timestr tz today epoch now
  m=$(printf '%s\n' "$text" | grep -oE "${USAGE_RESET_TIME_REGEX}( \([A-Za-z_/+-]+\))?" | tail -1)
  [[ -z "$m" ]] && return 1
  timestr=$(printf '%s' "$m" | grep -oE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]?(am|pm)')
  tz=$(printf '%s' "$m" | grep -oE '\([A-Za-z_/+-]+\)' | tr -d '()')
  [[ -n "$tz" ]] || tz=$(date +%Z)
  today=$(TZ="$tz" date +%Y-%m-%d 2>/dev/null) || return 1
  epoch=$(TZ="$tz" date -d "$today $timestr" +%s 2>/dev/null) || return 1
  now=$(date +%s)
  (( epoch <= now )) && epoch=$(( epoch + 86400 ))
  echo "$epoch"
}
LEGACY_EOF
)

# sha256 of exactly the bytes above (the heredoc body, with its single trailing
# newline). Recomputed by the suite on every run; see the "how it was taken" command
# in the header for the independent way to arrive at the same number.
# 上面那段字节（含唯一一个结尾换行）的 sha256。套件每次运行都重算一遍。
QS_LEGACY_SHA256=3578ee96fa36a5201fb180592119ee1cd2813b4b6d7ff688a693efc286a75e44

# legacy_call <fn> [args...] — run one frozen detector in a SUBSHELL.
#
# ⚠️ The subshell is not tidiness, it is a correctness requirement. The frozen text
#    assigns `IDLE_CURSOR_REGEX`, and the current implementation reads
#    `${IDLE_CURSOR_REGEX:-<default>}`. Sourcing the old text into the test's own shell
#    would therefore hand the OLD regex to the NEW detector — the control group would
#    quietly reconfigure the thing it is supposed to be compared against, and the
#    suite would still be green. Upstream sidestepped this by renaming on load; a
#    subshell gets the same isolation while keeping the text byte-verbatim.
# ⚠️ 用子 shell 不是为了整洁，是正确性要求：冻结文本会赋值 `IDLE_CURSOR_REGEX`，而现行
#    实现读的正是 `${IDLE_CURSOR_REGEX:-…}`。把旧文本 source 进测试自己的 shell，等于
#    把**旧**正则塞给**新**判据——对照组会悄悄重新配置它本该对照的那个东西，而套件照样绿。
#    上游靠加载时改名绕开；子 shell 给到同样的隔离，同时让文本保持逐字节原样。
legacy_call() {
  local fn="$1"; shift
  ( eval "$QS_LEGACY_SRC" && "$fn" "$@" )
}
