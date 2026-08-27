# Requirements / 运行前提

Linux only. macOS and Windows are **unverified** — see "Portability" at the bottom for
what specifically would break.
只保证 Linux。macOS 与 Windows**未验证**——具体会在哪里坏，见底部「可移植性」。

⚠️ This list covers **this milestone**, which reads quota and keeps a ledger. Account
switching arrives later and brings its own dependencies; they are listed separately at
the bottom so that "what do I need today" stays answerable.
⚠️ 本清单覆盖**本里程碑**（读额度、落账）。切号在后续里程碑到来，它自带依赖，
单列在底部，好让「我今天到底需要什么」这一问始终答得出。

## Required — nothing works without these / 必需

| what / 什么 | why / 为什么 | check / 怎么查 |
|---|---|---|
| `bash` **≥ 4.1** | `declare -A`, `exec {fd}>`, `mapfile` | `bash --version` |
| `jq` | every state read and write, and all JSON parsing / 全部状态读写与 JSON 解析 | `jq --version` |
| `date` `awk` `grep` `sed` and the rest of coreutils | timestamps, panel parsing, floating-point arithmetic | preinstalled on any distribution |

⚠️ `jq` is the one that is genuinely missing on minimal images, and it is the one
whose absence is most expensive: without it every reading comes back empty, which is
**indistinguishable from "this account has no quota data"**. That is why
`quota-sentinel deps` checks it up front and refuses to continue, rather than letting
you discover it from a wrong answer.
⚠️ `jq` 是最小镜像里真正常缺的那个，也是缺了代价最大的那个：没有它，每次读数都返回空，
而「读数恒空」与「这个账号没有额度数据」**长得一模一样**。所以 `quota-sentinel deps`
开头就查它并拒绝继续，而不是让你从一个错答案里发现它。

## Required for the panel reader / 面板读数那条链需要

The authoritative reading comes from driving a dedicated Claude Code session that types
`/usage`. That needs:
权威读数来自驱动一个专发 `/usage` 的专用 cc 会话。它需要：

| what / 什么 | why / 为什么 |
|---|---|
| `tmux` | it is the thing that drives that session. **This is not a dependency on any fleet tooling** — the mechanism *is* tmux-driven, and that is the core of the project. / 它就是驱动那个会话的东西。**这不是对任何编队工具的依赖**——机制本身就是 tmux 驱动的，那正是本项目的核心。 |
| `claude` (Claude Code CLI), **already logged in** | it is what actually fetches the numbers / 真正去取数的是它 |
| `flock` (util-linux) | mutual exclusion between the poller and manual commands / 轮询与人工命令之间的互斥 |

Without `tmux` the panel chain is unavailable and the tool says so; the other commands
still work. Without a logged-in `claude` there is nothing to read.
没有 `tmux` 时面板链不可用，工具会明说；其他命令照常。没有登录过的 `claude` 就没有东西可读。

## Required for the OAuth reader / OAuth 直查需要

| what / 什么 | why / 为什么 |
|---|---|
| `curl` | the direct read-only query against the usage endpoint / 直查用量接口 |
| network access to `api.anthropic.com` | — |

## NOT required by this milestone / 本里程碑**不**需要

Stated explicitly, because an over-long dependency list is its own kind of wrong
answer — it makes people install things they do not need and blame the wrong component
when something fails.
显式写出来，因为一份过长的依赖清单本身也是一种错答案：它让人装上用不到的东西，
并在出问题时怪错组件。

| what / 什么 | note / 说明 |
|---|---|
| `python3` | **verified by removal**: with `python3` made unusable inside a clean sandbox, `deps`, `status` and every detector still run. It becomes required when account switching lands (that tool is Python). / **靠移除验证过**：在干净沙箱里让 `python3` 不可用后，`deps`、`status` 与全部判据照常。切号落地后它才成为必需（那个工具是 Python 写的）。 |
| `tzdata` | **verified by removal**: with `/usr/share/zoneinfo` emptied, this tool runs and honestly reports the host's actual offset. It does not consult a time-zone database at all — see below. It becomes required when account switching lands (that tool calls `ZoneInfo` at import time, so a missing `tzdata` is an **import-time crash**, not a late failure). / **靠移除验证过**：清空 `/usr/share/zoneinfo` 后本工具照常跑，并如实报出宿主的真实偏移量。它根本不查时区库——见下。切号落地后它才成为必需（那个工具在 import 期就调 `ZoneInfo`，缺 `tzdata` 是**导入期崩**，不是跑到那行才崩）。 |
| `docker` | only the container liveness probe used it, and that is not extracted / 只有容器可用性探测用它，而那部分未抽取 |
| `git` | only the original regression suite used it, and that is a later milestone / 只有原回归套件用它，那是后续里程碑 |

## Time zones — read this before filing a bug about wrong times / 时区

This tool **never consults a time-zone database when rendering a timestamp**. It
resolves the host's UTC offset **once** at startup and does arithmetic on top of a UTC
render from then on.
本工具**渲染时刻时从不查时区库**。它在启动时**一次性**解析出宿主的 UTC 偏移量，
此后全是在 UTC 渲染上做算术。

Why it is built that way, and why you should not "fix" it back:
为什么这么做，以及为什么不要把它「改回去」：

- `TZ=Some/Zone date` on a host without `tzdata` **silently falls back to UTC and
  reports success.** Measured directly: with zoneinfo removed,
  `TZ=Asia/Shanghai date '+%z %Z'` prints `+0000 Asia`. Nothing errors. Every
  timestamp is then wrong by a whole offset, and looks perfectly plausible.
  缺 `tzdata` 的宿主上，`TZ=某/区 date` 会**静默回退 UTC 并报告成功**。实测：移除
  zoneinfo 后，`TZ=Asia/Shanghai date '+%z %Z'` 打印 `+0000 Asia`，一条错都不报。
  此后每个时刻都整整差一个偏移量，而且看起来完全合理。
- `jq`'s `strftime` always renders UTC and ignores `TZ`, while `date -d @N` uses the
  local zone. **Their output is indistinguishable.** A sampling log read with the wrong
  one showed 14:52 as 06:52, which led to "the sampler has been dead for eight hours" —
  it had been running the whole time.
  `jq` 的 `strftime` 恒按 UTC 渲染、不看 `TZ`，而 `date -d @N` 看本地时区。
  **两者输出长得一模一样。**用错的那个读采样日志，把 14:52 读成 06:52，据此断定
  「采样器已经停了八小时」——它一直在正常跑。

⇒ Every timestamp this tool prints carries its offset, and the ledger stores a
`_times_readable` block rendered at that same offset alongside the raw epoch seconds.
⇒ 本工具打印的每个时刻都带偏移量，台账里另存一份 `_times_readable`，与原始 epoch 秒并列。

If the host's offset cannot be parsed, the tool **refuses to start** and tells you to
set `QUOTA_TZ_OFFSET_SEC` explicitly. It does not guess. A guessed offset is exactly
the silent eight-hour error described above.
若宿主的偏移量解析不出来，工具**拒绝启动**，并让你显式设 `QUOTA_TZ_OFFSET_SEC`。
它不猜。猜出来的偏移量正是上面那种静默差八小时的错。

```sh
QUOTA_TZ_OFFSET_SEC=28800 quota-sentinel status   # pin to UTC+8
```

## Portability / 可移植性

Linux is the only verified platform, and the reason is concrete rather than vague: the
extracted code uses GNU-specific flags throughout. On macOS/BSD these fail:
Linux 是唯一验证过的平台，理由是具体的而不是含糊的——抽出来的代码通篇使用 GNU 专有
flag。在 macOS/BSD 上，下列会失败：

`date -d` · `date +%s%3N` · `date -u -d @N` · `stat -Lc` / `stat -c` · `readlink -f` ·
`grep -oE` · `sed -E` · `cp -a` · `mv -f` · `sort -k1,1 -rn` · `tail -n +N`

⚠️ Also worth knowing: the clean-machine sandbox used to verify this repo reuses the
host's `/usr`, `/bin` and `/lib`. It therefore proves **"this does not depend on the
environment it came from"** — it does **not** prove "this runs on another distribution".
A script that depends on one machine's particular `jq` behaviour would pass it happily.
⚠️ 另外值得知道：用来验证本仓的干净机器沙箱复用宿主的 `/usr`、`/bin`、`/lib`。
它证明的是**「不依赖它出身的那套环境」**，**不是**「在别的发行版上能跑」。
一个依赖本机 `jq` 特有行为的脚本，在里面照样绿。
