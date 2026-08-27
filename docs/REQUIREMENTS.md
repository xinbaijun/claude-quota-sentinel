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

## 🔴 The first thing that will happen to you / 你第一次跑最可能撞上的事

**On a machine that has never logged into `claude`, this tool reads no quota at all.**
It prints `⚠️ cannot read cachedUsageUtilization` and stops there.

That is not a bug and not a missing dependency — it is the shape of the whole design.
There is no public API for the authoritative reading. The number comes from
`~/.claude.json`, and **Claude Code is the only thing that writes it**. No login, no
file; no file, no reading.

⇒ Order of operations: install `claude`, log in, use it at least once, **then** run
this tool. Verifying the install with `quota-sentinel status` before you have ever
logged in will look exactly like the tool being broken.

**一台从未登录过 `claude` 的机器上，本工具读不到任何额度**，只会打印
`⚠️ cannot read cachedUsageUtilization` 然后停在那里。

这不是缺陷，也不是缺依赖——它就是整个设计的形状：权威读数没有公开接口，那个数来自
`~/.claude.json`，而**只有 Claude Code 自己会写它**。没登录就没有那个文件，没有文件就没有读数。

⇒ 次序：装 `claude` → 登录 → 至少用过一次 → **然后**才跑本工具。
在还没登录过的时候用 `quota-sentinel status` 验证安装，看起来会和「工具坏了」一模一样。

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
| ~~`python3`~~ | **superseded — account switching has landed.** See "Required for the switching half" below. The earlier finding still holds for everything else: with `python3` unusable, `deps`, `status` and every detector run normally. / **已被取代——切号已落地**，见下方「切号那一半需要」。其余部分的旧结论不变。 |
| ~~`tzdata`~~ | **superseded — and the prediction it made turned out not to apply.** See "Required for the switching half" below. / **已被取代，而且它当时的预测并不成立**，见下方那节。 |
| `docker` | only the container liveness probe used it, and that is not extracted / 只有容器可用性探测用它，而那部分未抽取 |
| `git` | only the original regression suite used it, and that is a later milestone / 只有原回归套件用它，那是后续里程碑 |

## Required for the switching half / 切号那一半需要

Reading and recording quota needs nothing here. Only `account-switch` — the program
that actually moves credentials — does.

| what / 什么 | when / 何时需要 | check / 怎么查 |
|---|---|---|
| `python3` **≥ 3.9** | whenever `QUOTA_SWITCH_MODE` is not `off`. 3.9 is the floor because `zoneinfo` arrived in 3.9. / 只要 `QUOTA_SWITCH_MODE` 不是 `off`。3.9 是下限，因为 `zoneinfo` 从 3.9 才有。 | `python3 --version`, or `quota-sentinel deps` |
| `tzdata` | **only if you set `QUOTA_FALLBACK_TZ` to a zone name.** Leave it empty — the default — and no time-zone database is consulted at all. / **仅当你把 `QUOTA_FALLBACK_TZ` 设成区域名时**。留空（默认）就完全不查时区库。 | `python3 -c "from zoneinfo import ZoneInfo; ZoneInfo('Asia/Shanghai')"` |

### The `tzdata` story changed, and the change is the point / `tzdata` 这条变了，而变化本身才是重点

An earlier revision of this file predicted that a missing `tzdata` would be an
**import-time crash**, because the program it describes called `ZoneInfo("Asia/Shanghai")`
at module top level. That was an accurate reading of the code at the time. It no longer
applies, because that hard-coded zone was itself the defect: a published tool has no
business assuming one particular part of the world, and it should not drag in a
dependency to do so.

What replaced it: the zone is resolved from `QUOTA_FALLBACK_TZ`, matching the
convention the shell side already uses. Empty means this machine's own offset, which
needs no database. A named zone with no `tzdata` present now fails **immediately and by
name**:

```
account-switch: QUOTA_FALLBACK_TZ='Asia/Shanghai' could not be resolved: 'No time zone found with key Asia/Shanghai'
account-switch: install the tzdata package, or leave QUOTA_FALLBACK_TZ empty to use this machine's local zone.
```

🔴 Why it fails instead of falling back: the shell equivalent, `TZ=<name> date`, does
**not** fail on a host without `tzdata` — it silently renders UTC. You get a plausible
timestamp that is simply wrong by your whole offset. This repo already documents that
trap for the shell side, and the switching half must not reintroduce it: these
timestamps name **backup directories**, and a timestamp that is quietly eight hours off
is how somebody rolls back the wrong one. ⭐ Failing is recoverable. Being quietly wrong
is not.

⚠️ Verified, not assumed — and the first attempt at verifying it was invalid. Setting
`PYTHONTZPATH` to a nonexistent directory looked like it removed the zone database, but
the PyPI `tzdata` package was installed as a fallback and the lookup succeeded anyway,
so the "test" would have passed no matter what the code did. The check only became
worth anything once the simulation itself was checked: `ZoneInfo('Asia/Shanghai')` must
raise `ZoneInfoNotFoundError` *before* the test of our behaviour means anything.
⚠️ 这条是验过的，但**第一次验法是无效的**：把 `PYTHONTZPATH` 指向不存在的目录看着像
拿掉了时区库，实际上 PyPI 的 `tzdata` 包还在当兜底、查找照样成功——那个「测试」无论代码
怎么写都会通过。**先确认模拟真的移除了那个能力**，对我方行为的检验才开始有意义。

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
