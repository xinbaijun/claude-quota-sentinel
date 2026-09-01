# claude-quota-sentinel

Watch Claude subscription quota across several of your own accounts, switch when a
threshold is reached, and keep an audit trail of every switch.
在你自己的多个 Claude 账号之间盯额度、到线切号，并为每一次切换留下可追溯的账目。

**Nine of the ten guard entries below ship an executable guard that can be made to go red
on demand, and every entry is annotated with the incident that forced it into existence.**
That is the point of this repository — more than the switching itself, which several other
projects do more comfortably (see
[What this does not do](#what-this-does-not-do--不解决什么)).
⚠️ **The denominator is stated, not implied**: the remaining entry (**G-3**) documents a guard
whose executing half **was not extracted into this repository**, and a handful of named
mechanisms inside otherwise-proven entries are **unproven rather than proven**. Both lists
are written out in
[What the red-state claim covers](#what-the-red-state-claim-covers--这句总括声称的分母).
⭐ A blanket claim whose denominator nobody can state is not a stronger claim, it is an
unfalsifiable one.
**下面十条里有九条带着可执行的守卫、且都能当场证明它会红；十条都标着逼它出现的那次事故。**
这才是本仓的重点——切号本身有别的项目做得更顺手（见「不解决什么」）。
⚠️ **分母是写出来的，不是暗示的**：剩下的那一条（**G-3**）记的那条守卫，其**执行的那一半没有
被抽取进本仓**；另外还有若干条被点名的机制，落在「已证明会红」的条目里但**自身未被证明**。
两张单子都逐条写在
[这句总括声称的分母](#what-the-red-state-claim-covers--这句总括声称的分母) 里。
⭐ 一句没人说得出分母的总括声称不是更强的声称，是一句无法否证的声称。

> A one-line locator, so you know within ten seconds whether this is your problem at all:
> **a credential's "expires in 2 hours" tells you almost nothing about whether the account
> works** — we measured one that showed *expired 2 days ago* and worked fine, and another
> that showed *2 hours left* and was dead. If you have ever ranked accounts by their
> credential expiry, that is the class of thing this repo is about.
> 一行定位句，好让你十秒内判断这是不是你的问题：**凭据上那句「还有 2 小时过期」几乎
> 不能说明账号能不能用**——实测有账号显示「已过期 2 天」却好好的，也有显示「2 小时后
> 才过期」却已经废了。如果你曾经按凭据过期时间给账号排过序，本仓讲的就是这一类事。

> ✅ **SUPERSEDED 2026-08-31 — this repository may be made public, and a release ships from
> THIS repository.** A 🔴🔴 banner here said the opposite until the owner, shown what the
> names actually are, lifted that line on 2026-08-31.
> ⚠️ **The measurement it rested on is unchanged and is not retracted**: the **git objects**
> contain real given names (the working tree is clean; the object layer is not), and
> **`force-push` does not delete remote objects** — measured on this repository: from a
> fresh clone, superseded commits fetched **by SHA** still come back with their old
> contents. What changed is the **disposition**, not the finding. Range-by-range counts and
> the full before/after:
> [docs/REDACTION.md](docs/REDACTION.md#real-names-in-the-git-objects--git-对象里的真实人名).
> ✅ **2026-08-31 作废——本仓可以转 public，且发布就从本仓推出。** 这里原本是一条 🔴🔴
> 相反的横幅，仓主看过那些名字实际是什么之后，于 2026-08-31 解除了它。
> ⚠️ **它所依据的测量没有变，也不是撤回**：**git 对象**里确有真实名字（工作树干净、对象层
> 不干净），且 **`force-push` 不删除远端对象**——本仓实测：从全新 clone 按 **SHA** 去 fetch
> 已被取代的 commit，旧内容照样取得出来。变的是**处置决定**，不是**发现**。

## Quick start / 一分钟跑起来

✅ **The URL below is the real one and stays the real one.** Until 2026-08-31 this
paragraph warned that the URL pointed at a private repository, that a public release would
live *somewhere else*, and that **this line must be changed when that happens**. That
instruction is now retired: the release ships from **this** repository, so there is no
other URL coming and nothing here to change (see the banner above).
✅ **下面这个 URL 就是正式的那个，而且不会再换。** 2026-08-31 之前这段写的是：该 URL 指向
一个私有仓、公开版会在**别处**、**到那时这一行必须改**。该指令现已作废——发布就从**本仓**
推出，不会再有另一个 URL，这一行也没有什么要改的了（见上面的横幅）。

```sh
git clone https://github.com/xinbaijun/claude-quota-sentinel.git
cd claude-quota-sentinel

# 1. What is on this machine right now, read-only. / 先只读地看一眼这台机器的现状。
./quota-sentinel status

# 2. Ask the OAuth usage endpoint directly for one account. / 直接问一次用量接口。
./account-probe --json

# 3. Run one reading cycle, which also decides. Dry-run is the DEFAULT:
#    QUOTA_SWITCH_MODE is off | dry-run | on, and dry-run decides and records
#    without touching any credential.
#    跑一轮读数（它同时会做决策）。dry-run 是**默认**：QUOTA_SWITCH_MODE 取
#    off | dry-run | on，dry-run 只判定、只记账，不动任何凭据。
./quota-sentinel read-once

# 4. Read back what it decided and why. / 把它决定了什么、为什么，读回来。
./quota-sentinel switches
```

⚠️ On a brand-new install step 4 prints `no switch ledger yet at …` and **exits 1** —
there is genuinely nothing to show yet. Mentioned because a non-zero exit on your first run
is otherwise alarming, and a README that lets you discover that yourself has wasted your
time.
⚠️ 全新安装时第 4 步会打印 `no switch ledger yet at …` 并**以 1 退出**——确实还没有东西可看。
写在这里，是因为第一次跑就拿到非零退出码本来会让人以为出事了，
而一份让你自己去发现这件事的 README 是在浪费你的时间。

Nothing above writes a credential: `QUOTA_SWITCH_MODE` defaults to **dry-run**. The switch
itself only happens with `QUOTA_SWITCH_MODE=on`, and
[what it touches](#what-it-touches-and-how-to-audit-it-first--它会动你哪些文件怎么先审再用)
is listed before you get there.
以上没有一条会写凭据：`QUOTA_SWITCH_MODE` 默认就是 **dry-run**。真正切号只在
`QUOTA_SWITCH_MODE=on` 时发生，而
「它会动你哪些文件」在你走到那一步之前就已经列在下面。

**Requirements**: Linux only. `bash` >= 4.1, `jq`, `curl`; `tmux` and a logged-in
`claude` for the panel reader; **`python3` >= 3.9 for the switching half** (3.9 is the
floor because `zoneinfo` arrived there). **`tzdata` is a CONDITIONAL dependency — needed
only if you set `QUOTA_FALLBACK_TZ` to a zone name**; left empty (the default) no
time-zone database is consulted at all. Full list, including what is *not* required and
why: [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md).
**运行前提**：仅 Linux。`bash` >= 4.1、`jq`、`curl`；面板读数那条链另需 `tmux` 与已登录
的 `claude`；**切号那一半另需 `python3` >= 3.9**（3.9 是下限，因为 `zoneinfo` 从 3.9 才有）。
**`tzdata` 是条件依赖——只有当你把 `QUOTA_FALLBACK_TZ` 设成区域名时才需要**；
留空（默认）则完全不查时区库。

---

## What it touches, and how to audit it first / 它会动你哪些文件，怎么先审再用

This is near the top on purpose: this tool writes **credential files**, and you should be
able to decide whether to trust it before you read anything else.
放在靠前是有意的：本工具会写**凭据文件**，你应当在读别的东西之前就能决定要不要信它。

| Path / 路径 | Read / Write | What / 是什么 |
|---|---|---|
| `~/.claude.json` | **write** | the account identity the client uses. A switch replaces this file **whole**, never field-by-field / 客户端使用的账号身份。切号**整文件替换**，不做字段级手术 |
| `~/.claude/.credentials.json` | **write** | the OAuth tokens themselves / OAuth 令牌本体 |
| `~/claude-backups/…` | **write** | a timestamped copy taken *before* each switch / 每次切号**之前**的带时间戳副本 |
| `$QS_STATE_DIR/quota-state.json` | write | the ledger: readings, guard fence, cadence / 台账：读数、守卫围栏、节奏 |
| `$QS_STATE_DIR/switches.jsonl` | append | one line per switch decision, never rewritten / 每次切号决策一行，只追加不改写 |
| `$QS_STATE_DIR/quota.log` | append | the human-readable log / 人读日志 |
| `$QS_STATE_DIR/quota-panel-observations.jsonl` | append | one line per 10s screen sample: the parsed numbers, the account, the cadence, and a **sha256 of the visible screen**. ⚠️ The screen TEXT is stored only when you set `QUOTA_PANEL_TEXT_CAPTURE=1` — see **K15**. Pruned to 7 days / 每 10 秒一条：解析值、账号、节奏，以及**可见屏的 sha256**。⚠️ 屏幕**原文**只在你设了 `QUOTA_PANEL_TEXT_CAPTURE=1` 时才存，见 **K15**。保留 7 天 |
| `$QS_STATE_DIR/quota-source-samples.jsonl` | append | one line per reading, structured fields only, never screen text / 每次读数一条，只有结构化字段，从不含屏幕原文 |

⚠️ **That table is the set you should decide about, not the complete file listing.** The
locks, the shadow-sampling state and event files, the cross-account snapshot and the
statusline owner directory all live under `$QS_STATE_DIR` as well, all structured records.

Everything this tool **persists** is under `$QS_STATE_DIR`, `~/.claude*` or
`~/claude-backups`. **It also writes short-lived temporary files outside those roots**, and
they are named here rather than waved at: `${TMPDIR:-/tmp}/quota-sentinel-oauth-body.*` and
`…-oauth-header.*` (`lib/reading.sh:871-872`), a bare `mktemp` for the same body
(`account-probe:186`), and `${TMPDIR:-/tmp}/.qs-probe-err.$$` (`account-probe:310`). All
four are `mktemp`-created `0600` and `rm -f`'d on the normal path; the OAuth **token** is
not among them — it travels on an anonymous pipe fd, never a file.
⚠️ And before reading any of that as "nothing else on the machine changes": read the red
line below. This tool starts a `claude` client inside a tmux session, and **that** process
writes wherever it writes.
⚠️ **上表是「你需要拿主意」的那几个，不是完整文件清单。** 各种锁、影子采样的 state 与事件
文件、跨账号快照、statusline 归属目录也都在 `$QS_STATE_DIR` 下，都是结构化记录。

本工具**持久化**的东西都在 `$QS_STATE_DIR`、`~/.claude*` 或 `~/claude-backups` 里。
**它另外还会在这三个根之外写短命临时文件**——这里逐个点名而不是含糊带过：
`${TMPDIR:-/tmp}/quota-sentinel-oauth-body.*` 与 `…-oauth-header.*`
（`lib/reading.sh:871-872`）、同样内容的一个裸 `mktemp`（`account-probe:186`）、
以及 `${TMPDIR:-/tmp}/.qs-probe-err.$$`（`account-probe:310`）。四处都是 `mktemp` 建的
`0600`，正常路径上都会 `rm -f`；OAuth **令牌不在其中**——它走匿名 pipe fd，不落文件。
⚠️ 在把上面任何一句读成「机器上别的什么都不会变」之前，先看下面那条红线：本工具会在一个
tmux 会话里起一个 `claude` 客户端，而**那个**进程写它自己要写的东西。

🔴 **It also starts a process, and the table above is a file table — so read this line too.**
`read-once`, `monitor-ensure` and `monitor-restart` will **create and keep** a tmux session
named `$QUOTA_MONITOR_SESSION` and run `$QUOTA_MONITOR_LAUNCH` in it (default
`DISABLE_AUTOUPDATER=1 claude`). **That process stays alive after the command returns.**
It is how the panel reader works, and it is not optional on that path.
⚠️ **Sandboxing it with `HOME` does not work**, which is the first thing anyone tries —
see **K14**. `tmux new-session` is called with no `-e`, so the process inherits the tmux
**server's** environment, not yours.
🔴 **它还会起一个进程，而上面那张是文件表——所以这一行也要读。**
`read-once`、`monitor-ensure`、`monitor-restart` 会**创建并保持**一个名为
`$QUOTA_MONITOR_SESSION` 的 tmux 会话，在里面跑 `$QUOTA_MONITOR_LAUNCH`（默认
`DISABLE_AUTOUPDATER=1 claude`）。**命令返回之后那个进程还活着。**
面板读数就是这么工作的，在那条路上它不是可选项。
⚠️ **用 `HOME` 沙箱化它不管用**，而那正是所有人第一个会试的办法——见 **K14**。
`tmux new-session` 调用时没有带 `-e`，所以那个进程继承的是 tmux **server** 的环境，不是你的。

**Audit it before you let it act**, in this order:

1. `./quota-sentinel env` — print the resolved configuration and every path it will use,
   **before** it uses any of them.
2. `./quota-sentinel status` — read-only, touches no credential.
3. ⚠️ **STOP — this is the first step with a side effect, and it is a process, not a
   file.** `./quota-sentinel read-once` is dry-run for *credentials*, but it will start a
   tmux session running a real `claude` bound to whichever account the **tmux server's**
   `HOME` points at — not necessarily the one `env` just printed. If you only want to look,
   **steps 1, 2 and `./account-probe --json` already cover every read-only need**; stop
   here until you have read **K14**.
   Once you do run it: read `quota.log` for the `🔎 dry-run: … would switch A -> B` line,
   then `tmux kill-session -t "$QUOTA_MONITOR_SESSION"` if you did not want a resident
   session.
4. `diff` the two credential files against a backup after your first real switch.
5. `./quota-sentinel switches` — read the ledger back out.

**先审再用**，按这个顺序：先 `env`（把它将要用的路径先打出来给你看），再 `status`（只读）。
⚠️ **第 3 步 `read-once` 是第一个有副作用的步骤，而且副作用是一个进程不是一个文件**：
它对**凭据**是空跑，但会起一个 tmux 会话、在里面跑一个真实 `claude`，
而那个 `claude` 绑的是 **tmux server 的 `HOME`** 指向的账号——**不一定**是 `env` 刚打给你看的那个。
只想看的话，**第 1、2 步加 `./account-probe --json` 已经覆盖全部只读需求**；
在读完 **K14** 之前就停在这里。真要跑了之后：去 `quota.log` 看那行 `🔎 dry-run:`，
不想留常驻会话就 `tmux kill-session -t "$QUOTA_MONITOR_SESSION"`。
最后第一次真切之后拿备份 `diff` 两个凭据文件，再用 `switches` 把流水账读出来。

**If it goes wrong**: every switch writes a timestamped backup *before* touching anything,
and `account-switch --rollback` restores the most recent one. Take this seriously —
switching to an account that turns out to be exhausted interrupts whatever is running,
and it has happened to us (see **K13**).
**出事怎么退回来**：每次切号都会在动手**之前**写一份带时间戳的备份，
`account-switch --rollback` 还原最近一份。这条要认真对待——切到一个其实已经耗尽的账号
会当场打断正在做的事，我们自己遇到过（见 **K13**）。

**Who runs it periodically?** This repo deliberately ships **no** daemon or service unit.
Use cron or a systemd timer:
**谁来周期性跑它？** 本仓**不提供**常驻方案，请自行 cron 或 systemd：

```cron
* * * * * cd /path/to/claude-quota-sentinel && ./quota-sentinel read-once >>~/.qs-cron.log 2>&1
```

---

## The architecture trade-off, before any incident / 先说架构取舍，再讲事故

Read this first, or the incident list below reads as "this tool is buggy" rather than
"this road costs this much".
先读这一节，否则下面那串事故会被读成「这工具毛病多」，而不是「这条路要付这个代价」。

There are two ways to survive a quota limit:

- **Reactive** — do nothing until a request actually fails, then switch. Zero dependency
  on any upstream quota reading. **Structurally immune to every "the number was wrong"
  failure in this document**, because it never reads a number.
- **Predictive** (what this is) — read the remaining quota, project forwards, switch
  *before* the wall. You get to switch while nothing is broken; the price is that **you
  are now betting on a number**, and most of the incidents below are that bet going wrong.

活过额度上限有两条路：**反应式**（等请求真的失败了再切，零上游依赖，**结构上免疫本文
所有「数字读错了」类故障**，因为它根本不读数字）与**预测式**（本项目：读剩余额度、
向前外推、在撞墙**之前**切）。预测式的好处是切号发生在一切还正常的时候；代价是
**你从此押注在一个数字上**，而下面多数事故就是这个赌注出错的样子。

> A retry library answers "what do I do when a request has failed". This project answers
> "how do I know, **before** anything has failed, that it is about to" — and the ugly part
> of that question is: by the time the curve reaches the line you drew, it is often already
> too late.
> 重试库回答的是「请求失败了怎么办」；本项目回答的是「**在还没失败之前**，怎么知道快要
> 失败了」——而这个问题难看的地方在于：等曲线涨到你画的那条线，往往已经晚了。

**If the reactive trade-off suits you better, take it.** Nothing here is an argument that
predictive is the right answer in general.
**如果反应式更适合你，就用反应式。**本文没有任何一句是在论证预测式普遍更好。

---

## Where this sits among similar projects / 它在同类项目里的位置

Six mechanisms exist for "use a different Claude account". They fail differently, which
matters more than their feature lists.
「换一个 Claude 账号」有六种机制，它们**失效方式不同**，这比功能清单要紧。

| Family / 族 | Mechanism / 机制 | **We are here?** | The structural risk of that family / 该族的结构性风险 |
|---|---|---|---|
| **A** | swap the credential files in place / 原地交换凭据文件 | 🔴 **yes / 是** | **several processes read and write one shared credential file** — drift after a switch, someone switching behind your back, a half-finished write / **共享凭据文件被多进程同时读写**——切完之后身份漂移、别人在你背后切了号、写到一半崩了 |
| **B** | proxy injects a token per request / 代理逐请求注入 | no | every token concentrated in one long-lived process; **must track the upstream's private request format** / token 全集中在一个常驻进程；**必须跟着上游私有请求体格式走** |
| **C** | write the credential then `exec` / 写完就 exec | no | correct only at launch; **it does not know the quota changed afterwards** / 只在启动瞬间正确；**启动之后额度变了它不知道** |
| **D** | shell shim picks per invocation / 逐次调用选号 | no | every invocation queries upstream ⇒ **the querying itself becomes the load** / 每次调用都查一次 ⇒ **查询本身成为负担** |
| **E** | atomic symlink re-point / 目录级原子 symlink | no | described as planned, not implemented — no evidence either way / 公开描述为计划中、尚未实现，无实证 |
| **F** | one config dir per account / 每账号一个配置目录 | no | 🔴 **it is not switching at all**: isolation picks who at *launch*; a quota decision has to change who *at run time* / 🔴 **它根本不是「切换」**：隔离在**启动时**决定用谁，额度判断要在**运行中**换人 |

**Every guard this project is proud of grows on family A's risk.** If you want to avoid
that entire class of problem, use a family B project instead — that is a legitimate
choice, not a consolation prize.
**本项目最值钱的守卫，全都长在 A 族那个风险上。** 想避开这一整类问题，就去用 B 族的
项目——那是一个正当选择，不是安慰奖。

### Evidence grading / 证据分级

Claims in this document are graded, because they are not equally strong:
本文的断言分档，因为它们强度不同：

- 🟩 **read the source** — our own code, or a competitor's code we actually opened.
- 🟨 **read the README only** — a claim about *their documentation*, never about the world.
- 🟦 **read the primary page** — official docs or an issue, fetched in full.

🔴 **"Their README does not mention X" only ever supports "their README does not mention
X".** Where our evidence stops at their documentation, this document says
"their README does not address this" and **not** "they do not have it". Our side can point
at line numbers; their side is a document. The two are not symmetric, and pretending
otherwise would be the easiest way for this comparison to become dishonest.
🔴 **「对方 README 未提及 X」只能推出「对方 README 未提及 X」。** 凡是我方证据只到
「对方文档没写」的，本文一律写「对方 README 未就此作说明」，**不写**「它没有」。
左边是我们的代码（能指到函数），右边是一份文档，两边证据强度不对等。

---

## What it does / 解决什么

### Where the numbers come from / 它怎么知道你的额度

Readings come from two upstreams: the client's own `/usage` panel (primary) and a direct
OAuth query (used when the panel is unreadable). Both write into **one** ledger through
`quota_reading_apply` (`lib/reading.sh`), **arbitrated by observation time, not by
source**, and **every reading is tagged on disk with where it came from**.

The tag is not decoration. The panel goes blind under upstream rate limiting: across ten
days of logs that happened **27 times, 22 of them (81%) while utilisation was already
≥85%**, median 6.4 minutes, the worst running from 91% to 100% without a single reading in
between. Approaching the threshold the panel polls *more* often, and asking more often is
exactly what gets you limited — so its coverage collapses precisely when it matters. The
OAuth line is fixed at 180s and does not collapse. The two do not fail at the same times,
which is the whole reason for having both.

读数有两条上游：客户端 `/usage` 面板（主）与 OAuth 直查（面板读不到时顶上）。两条都经
`quota_reading_apply`（`lib/reading.sh`）写进**同一本**台账，**按观测时刻定胜负、不按来源**，
并且**每条读数落盘时都标着来源**。

标来源不是为了好看：面板会因上游限流而读不到东西——翻 10 天日志，这种失明发生 **27 次，
其中 22 次（81%）落在使用率已 ≥85% 的危险区**，中位 6.4 分钟，最长一次从 91% 一路瞎到
100%。面板逼近阈值时查得更勤，而问得越勤越容易被限流 ⇒ 它的覆盖恰好在最需要的时候塌掉。
OAuth 固定 180s 不塌。两条上游失败时机不重合，这正是要两条的全部理由。

### When it switches / 它什么时候换号

Two windows, two lines, **pointing in opposite directions**: five-hour at 90, weekly at 99.

That is not an oversight. The two windows differ by an order of magnitude in burn rate
(five-hour measured peak ~1.3%/min, weekly ~0.2%/min) **and** in unit value: at the
measured conversion constant of 0.120, **one weekly point is worth about 8.3 five-hour
points**. So leave headroom on the five-hour line — 4 points is what a comfortable switch
needs — and as little as possible on the weekly one, because every weekly point left
unspent throws away 8.3 five-hour points of capacity.

两个窗口两条线，**方向相反**：五小时 90，周 99。这不是疏忽。两者烧速差一个数量级
（五小时实测峰值 ~1.3%/分钟，周 ~0.2%/分钟），单位价值也差一个数量级——按实测换算常数
0.120，**1 个周额度点 ≈ 8.3 个五小时点**。所以五小时要留余量（留 4 点才够从容切号），
周额度要尽量少留（每早 1 点就扔掉 8.3 个五小时点的产能）。

⚠️ **A known gap, stated rather than hidden**: upstream also had a separate *accept* line
strictly below the switch line, so a candidate sitting exactly on the line is not accepted
and immediately switched away from again. The switching half here was rewritten and has no
such constant — `quota_switch_pick` uses the same threshold as both. The anti-flap margin
is therefore **1 point, not 2**. This is measured and asserted in the test suite rather
than left to be discovered.
⚠️ **一处明写的缺口**：上游另有一条**严格低于**切换线的「接受线」，用来防止接纳一个恰好
在线上的候选、下一轮又把它切走。本仓切号那一半是重写的，没有这个常量——
`quota_switch_pick` 用同一个阈值兼任两者 ⇒ 防抖余量是 **1 点而不是 2 点**。
这一条在回归里被测出来并写下来，而不是留给你去发现。

### After a switch / 换完之后

`quota_switch_perform` (`lib/switch.sh`) hands the credential move to `account-switch`,
**reads the identity back**, and only then moves the guard fence. Every decision — switch,
dry-run, blocked, failed, or *somebody else's* switch — appends one line to the ledger via
`quota_account_switch_record` (`lib/switch.sh`), which can answer: when, from whom to whom,
who did it, and what the quota was at the time.

`quota_switch_perform`（`lib/switch.sh`）把凭据交给 `account-switch` 后**回读一次身份**，
确认无误才挪守卫围栏。每一个决策——切号、空跑、无处可切、失败，以及**别人**切的号——
都经 `quota_account_switch_record`（`lib/switch.sh`）往流水账追加一行，能回答：
什么时候、从谁到谁、谁切的、当时额度多少。

---

## Incidents and the guards they forced / 事故与它们逼出来的守卫

Organised **by failure surface, not by incident number and not chronologically** — you
arrive here with a symptom, not with a date. Each entry follows the same four parts:
**the shape of the problem / what to do instead / why / when you should NOT do this**.

按**失效面**组织，不按事故编号、不按时间线——你是带着症状来的，不是带着日期来的。
每条四段：**问题形态 / 正确做法 / 为什么 / 什么时候不该这么做**。

Every guard named below **exists in this repository** and can be made to go red — with the
exceptions listed in [What the red-state claim covers](#what-the-red-state-claim-covers--这句总括声称的分母),
which you should read before treating this sentence as a blanket guarantee. The evidence is
the `test/posctrl.sh` table at the end **plus `tools/switch-selftest.sh`** (G-8's control
lives there, and `posctrl.sh` does not run it). Guards are cited as
`file :: function()` rather than line numbers, **because line numbers drift and a stale
line reference is worse than none**.
下面点名的每一条守卫**都在本仓真实存在**且能被证明会红——例外逐条列在
「这句总括声称的分母」一节，把本句当无条件保证之前请先读那一节。证据是末尾
`test/posctrl.sh` 那张表**外加 `tools/switch-selftest.sh`**（G-8 的控在后者里，
而 `posctrl.sh` 不跑它）。守卫按 `文件 :: 函数()` 引用而不是行号，**因为行号会漂，而一个失效的行号
引用比没有更糟**。

### G-1 · A number that went up can still be older than the one before it
### G-1 · 涨上去的数，仍然可能比上一个更旧

- **Shape / 问题形态** — you guard readings with monotonicity: "utilisation may not go
  down". Two real sequences: `97% → 0% → 97%` and `0% → 99%`. The middle `0%` was the
  genuine window reset; the high values on either side were **late frames from the
  previous window**. `97 > 0` is an increase, so monotonicity stopped neither. Both caused
  a wrong switch; the second pushed the computed "wait until" 24 hours into the future.
  用单调性守读数（「用量不许变低」）。两条真实序列：`97% → 0% → 97%` 与 `0% → 99%`。
  中间那个 `0%` 才是真的窗口重置，两侧的高值是**上一个窗口迟到的帧**。`97 > 0` 是上涨，
  单调性一条都拦不住。两次都因此错切账号，第二次把「等到几点」推到了 24 小时之后。
- **Instead / 正确做法** — decide **which window a frame belongs to first**, and only then
  compare values inside that window: `lib/monitor.sh :: quota_frame_stale()`, with
  `quota_window_sample_relation()` and the horizon clamp in `quota_panel_reset_epoch()`.
  **先判这一帧属于哪个重置窗口，再判窗口内的数值**。
- **Why / 为什么** — freshness alone is not enough (a late frame really did *arrive*
  just now); monotonicity alone is not enough (an old window's high value is an increase).
  This family's signature is: **every step is reasonable, the combination is badly wrong,
  and nothing errors.**
  只做新鲜度不够（迟到的帧**本身是新到达的**）；只做单调性不够（旧窗口高值是上涨）。
  这一族的特征是：**每一步都合理，合起来错得离谱，且全程无报错。**
- **When you should not / 例外** — if your source stamps every reading with the window it
  belongs to, you do not need any of this; just read the field. This guard exists because
  ours does not.
  如果你的数据源本身给每条读数标了所属窗口，这一整套都不需要，直接读那个字段就行。
  这条守卫存在，是因为我们的数据源没有。

### G-2 · A guard that fails closed can fail closed forever
### G-2 · fail-closed 的守卫可能永远地关着

- **Shape / 问题形态** — a switch **succeeded**, but the identity check included a
  lagging cache field that came back empty from a restore. The guard failed closed —
  "identity missing" — so the tool did not accept its own successful switch, and every
  round afterwards was blocked as account drift. **Three hours of standstill**, and the
  log was a wall of correct-looking "account guard blocked" lines.
  一次切号**执行成功**，但身份判据里混进了一个从恢复流程回来时为空的滞后缓存字段。
  守卫 fail closed 判「身份缺失」——工具不认自己刚做成的切号，此后每一轮都被判账号漂移。
  **停摆三小时**，而日志里每一行都在正确地报告「账号漂移，已拦截」。
- **Instead / 正确做法** — identity is **only** the authoritative pair (email + account
  UUID), never a cache: `lib/state.sh :: quota_account_guard()`. A stale cache means
  "panel numbers may belong to the old account", which is a *different* question handled
  elsewhere; it must not block identity.
  身份**只**用权威那一对（email + 账号 UUID），绝不含缓存字段。缓存不一致的真实含义是
  「面板缓存的数值可能属于旧账号」，那是**另一个问题**，由别处处理，不该阻塞身份认定。
- **Why / 为什么** — it was a **deadlock**, not a misjudgement: the guard required a cache
  field, the cache field needed a successful query, and the query had to pass the guard.
  ⭐ **fail-closed did not become safety here, it became permanent refusal** — and it
  looked exactly like a guard working correctly.
  它是**死锁**不是错判：守卫要缓存字段一致才放行，缓存字段要跑一次查询才更新，
  而查询要先过守卫。⭐ **fail-closed 在这里没有变成安全，变成了永久拒绝**，
  而且读起来像守卫在正常工作。
- **When you should not / 例外** — if nothing else on the machine can write that file, a
  simple read-back at switch time is enough and this persistent fence is overkill. The
  fence earns its keep only because the file is **shared**.
  如果机器上没有别的东西会写那个文件，切号时回读一次就够了，这条持久围栏是多余的。
  它值钱的全部前提是那个文件**是共享的**。

### G-3 · "The command did not error" is not "the account works"
### G-3 · 「命令没报错」不等于「账号能用」

- **Shape / 问题形态** — three accounts measured on one day: one whose credential said
  *expired 2 days 14 hours* **worked** (refresh renewed it); one saying *expired 23 hours*
  was **dead** (token revoked, refresh revoked with it); one saying *expires in 2 hours*
  was **dead** (the organisation had disabled subscription access). Meanwhile a liveness
  check that ran a slash command returned a plausible success sentence for an account
  whose token had been **revoked** — because in that mode the slash command never calls
  the API at all.
  同一天实测三个账号：显示「已过期 2 天 14 小时」的**能用**（刷新续上了）；显示
  「已过期 23 小时」的**废了**（token 被吊销，刷新一起失效）；显示「2 小时后才过期」的
  **废了**（组织停用了订阅访问）。同时，一个用斜杠命令做的存活检查，对一个**已被吊销**
  的账号返回了一句看着像成功的套话——因为那个模式下斜杠命令根本没调 API。
- **Instead / 正确做法** — treat expiry and usability as unrelated, and make the check
  require the account to **do something only a working account can do**. The three
  counter-examples above are kept verbatim at the top of `account-probe` as evidence.
  把「过期时间」与「可用性」当成无关的两件事，并让检查要求账号**做一件只有能用的账号
  才做得到的事**。上面三个反例原样保存在 `account-probe` 抬头，作为证据。
- **Why / 为什么** — ⭐ **a check that is always true and a correct check produce
  identical output.** The revoked account passed, every time, confidently.
  ⭐ **一条恒真的判据和一条正确的判据，输出长得一模一样。**那个被吊销的账号每次都
  自信地通过。
- **When you should not / 例外** — a real liveness probe **costs a real request** and, if
  it triggers a token refresh, **changes the thing it is measuring** (see K4). If you only
  need "is the file parseable", do not pay for this.
  真的活体探测**要花一次真实请求**，而且一旦触发 token 刷新就会**改变被测对象**（见 K4）。
  如果你只需要「文件解析得动」，别买这个。
- ⚠️ **Scope, and it matters**: the executing prober needs Docker and **was not
  extracted**. What ships is the *evidence and the reasoning*, plus `account-probe`'s
  **read-only** usage query — **not** a liveness prober, and there is no `--health` flag
  here. So this entry tells you what to build if you need it; it does not hand you one.
  See **K-gap** and **K4**.
  ⚠️ **射程，而且这一格要紧**：执行这条判据的探测器需要 Docker，**未随抽取过来**。
  本仓带来的是**证据与推理**，加上 `account-probe` 的**只读**用量查询——
  **不是**活体探测器，也没有 `--health` 这个 flag。所以本条告诉你「要的话该怎么造」，
  不是交给你一个现成的。见 **K-gap** 与 **K4**。

### G-4 · Time errors never look like errors
### G-4 · 时间错误从不表现为错误

- **Shape / 问题形态** — three separate incidents, none of which raised anything: (a) a
  fallback that read the zone via a bare abbreviation, which the C library treated as
  UTC+0 — the same "resets 3:10pm" was recorded once as 15:10 and once as 23:10; (b) a
  log reader that rendered epochs as UTC, making a *working* sampler look like it had been
  dead for eight hours — **the investigator was misled by their own tool**; (c) a
  "Resets 7:50pm" seen at 19:50, naively rolled forward a day, producing a reset *later*
  than a genuinely older frame's — which silently broke "compare by reset time" entirely.
  三次独立事故，没有一次报错：(a) 兜底取时区拿到一个裸缩写，C 库当成 UTC+0——同一句
  "resets 3:10pm" 一次记成 15:10 一次记成 23:10；(b) 读日志的工具按 UTC 渲染 epoch，
  把一个**正常工作**的采样器读成「已经停了八小时」——**排查者被自己的工具骗了**；
  (c) 19:50 看到 "Resets 7:50pm"，裸解析加一天，得出的 reset 比真正更旧的帧还晚，
  于是「按重置时刻比新旧」这条判据整个静默失效。
- **Instead / 正确做法** — render with an explicit offset and **never consult a zone
  database at render time** (`lib/state.sh :: quota_fmt_ts()` uses `date -u -d @(ts+offset)`,
  which is a UTC render plus arithmetic); parse with an explicit offset
  (`lib/reading.sh :: quota_iso_epoch()`); clamp day roll-over to the window horizon
  (`lib/monitor.sh :: quota_panel_reset_epoch()`); self-check the offset at the parse entry
  (`lib/detect.sh :: quota_parse_reset_epoch()`). Log epoch **and** rendered time together,
  so nobody has to convert by hand and get it wrong the way (b) did.
  渲染一律带偏移量且**不查时区库**；解析走显式偏移；跨日回卷钳制在窗口视界内；
  解析入口做偏移自检。日志里 epoch 与渲染时刻**一起写**，免得读的人自己换算、
  重演 (b)。
- **Why / 为什么** — a time bug presents as **a perfectly plausible number**. There is no
  exception to catch and no line to grep for.
  时间错误表现为**一个看起来完全合理的数字**。没有异常可捕获，也没有关键字可 grep。
- **When you should not / 例外** — if you control both ends of the wire and can agree on
  epoch integers, do that instead; all of this is the cost of parsing rendered human time.
  如果两端都归你、能约定用 epoch 整数，就用整数；上面这一整套是「解析给人看的时间」
  的代价。
- ⚠️ **Scope**: this discipline covers the bash side. `account-switch` (Python) resolves a
  zone database **only when you hand it a zone name** via `QUOTA_FALLBACK_TZ`, and when it
  cannot resolve one it **fails loudly** (`SystemExit` plus a message naming both ways
  out). The shell equivalent `TZ=<name> date` on the same machine **silently falls back to
  UTC** — a plausible timestamp that is simply wrong by your offset. **That contrast is the
  rule, not an exception to it**: what this discipline exists to prevent is silent
  degradation, not failure.
  ⚠️ **射程**：这条纪律覆盖 bash 那一侧。`account-switch`（Python）**只在你显式给了区域名**
  （`QUOTA_FALLBACK_TZ`）时才去解析时区库，解析不到时**响亮失败**（`SystemExit` +
  同时给出两条出路的文案）。而同一台机器上 shell 的 `TZ=<name> date` 会**静默回退 UTC**
  ——给你一个看着合理、只是差了你那个偏移量的时刻。**这个对比正是本条纪律本身，
  不是它的例外**：它防的是静默降级，不是失败。

### G-5 · Anchoring a predicate to someone else's UI text
### G-5 · 把判据锚在别人的 UI 文案上

- **Shape / 问题形态** — the limit-detection predicate matched a menu option's wording
  verbatim. The client reworded that option. The branch then matched **zero times for 28
  days**, while a second branch kept firing 165+ times, so the system as a whole looked
  fine. **No error, no alert** — in the logs, "this predicate can no longer match" and
  "this situation happened not to occur" are the same thing.
  撞限判据逐字锚了一个选单选项的文案。客户端改了那句文案。此后该分支**连续 28 天零命中**，
  而另一条分支跑了 165+ 次，所以整体看起来一直在工作。**没有报错、没有告警**——在日志里，
  「这条判据再也命中不了」与「这段时间恰好没发生」长得一模一样。
- **Instead / 正确做法** — three things at once. Move the decision's source of truth off
  the rendered text entirely (drive the client to fetch real numbers). Make the fallback UI
  predicate **structural**, not word-anchored: `lib/detect.sh :: quota_menu_present()`.
  And freeze the **old** implementation into the suite as a control that asserts it now
  fails on the new wording (`test/fixtures/legacy-detectors.sh`).
  三件事一起做：把决策事实的来源整个搬离渲染文本；兜底 UI 判据改成**结构判据**、不逐字
  锚文案；把**旧实现**冻进回归当对照组，断言它在新文案上必须失效。
- **Why / 为什么** — ⭐ **testing only the new implementation is always green**, because
  the new one really does work on the new samples. The only thing that can go red is the
  control asserting the *old* one must fail here. **That is the entire reason this project
  keeps controls**, and why "the tests were migrated but the controls were lost" counts as
  not done.
  ⭐ **只测新实现永远是绿的**，因为新实现在新样本上确实工作。能让它红的只有那条
  「旧判据在这里必须失败」的对照组。**这就是本项目坚持保留正控的全部理由。**
- **When you should not / 例外** — if the UI is yours, or contractually stable, word
  anchoring is fine and much simpler. The rule is about text you **do not control**.
  如果那段 UI 是你自己的、或有稳定性约定，锚文案完全可以，而且简单得多。
  这条规矩说的是**不归你控制**的文本。

### G-6 · The investigator becomes the event source
### G-6 · 排查者变成事件源

- **Shape / 问题形态** — the predicate matched a rate-limit banner anywhere on screen. A
  user **quoted** that banner in conversation as an illustration; the watcher immediately
  judged that session to be limited, opened an episode, and pushed **three false "quota
  restored" messages** into it. Another session that was busy *analysing rate-limit logs*
  was pulled in the same way.
  判据只要屏幕上出现那句撞限提示就判定撞限。一个用户在对话里**引用**了那句话作说明，
  监控当场把该会话判成撞限、建 episode、并往里连发**三次伪「额度已恢复」**；
  另一个正在**分析撞限日志**的会话被同样抓了进去。
- **Instead / 正确做法** — grade the evidence and add disproofs:
  `lib/detect.sh :: quota_banner_present()` splits strict (a structural rendering the
  client produces) from weak (text match only, which must be cross-checked against real
  numbers before it counts — `quota_banner_confirmed()`). Three disproofs: the line starts
  with the user's input prefix (so the user typed or quoted it); it sits before the last
  top-level output block (so it is a superseded old notice); it is below the input area
  blank line (so it is the editor).
  把证据分级并加否证：strict（客户端渲染出来的结构证据）与 weak（只有文本命中，必须与
  真实数值交叉验证才可采信）。三道否证：该行以用户输入行前缀开头、位于最后一个顶级
  输出块之前、位于输入区空行之后。
- **Why / 为什么** — ⭐ **the more carefully someone works on this problem, the more
  likely the system decides they are having it.** Worse, the historical hit count becomes
  self-contaminated, so even "what is the baseline rate" stops being answerable. And this
  one is not a silent failure — it actively **injected instructions into working sessions**.
  ⭐ **越是有人在认真处理这个问题，越容易被系统判成正在发生这个问题。**更糟的是历史
  命中数被自激污染，连「基线是多少」都不再可信。而且它不是静默失效——它**主动往正在
  工作的会话里灌指令**。
- **When you should not / 例外** — if your detector only ever reads machine-generated
  channels that no human can write into, none of this applies. It applies the moment your
  input is a screen that people also type on.
  如果你的检测器只读机器生成、人写不进去的通道，这一整套都不适用。它适用的前提是：
  你的输入是一块人也会往上打字的屏幕。

### G-7 · Comparing a same-named metric across subjects
### G-7 · 跨主体比较同名指标

- **Shape / 问题形态** — accumulating deltas of two windows to derive a conversion
  constant produced **−0.434** on the first real run. Physically impossible: both windows
  only climb. The cause was that the sample included a period when the monitor was still
  attached to the **previous account**, so the value bounced between two accounts' numbers.
  Cleaned up, the true value is **0.120**, and independent segments all land in 0.10–0.125.
  累加两个窗口的增量算换算常数，首次实测算出 **−0.434**——物理上不可能，两个窗口都只会
  往上涨。根因是样本里混进了监控还挂在**上一个账号**那段时间的读数，数值在两个账号之间
  来回蹦。清干净之后真值是 **0.120**，各独立分段都落在 0.10–0.125。
- **Instead / 正确做法** — accumulate **only** when the account is unchanged *and* neither
  percentage went backwards: `lib/state.sh :: quota_ratio_update()`.
  ⚠️ **Until 2026-08-31 this function was only ever stubbed, never actually called by the
  suite**: replacing it wholesale with `{ return 0; }` left the run at `PASS 197 FAIL 0`.
  The control is now the `换算常数：增量只能在同一主体内累加` block plus the
  `ratio-cross-subject` ablation.
  ⚠️ **2026-08-31 之前这个函数在整套回归里只被打桩、从未被真实调用**：把它整个换成
  `{ return 0; }` 之后仍是 `PASS 197 FAIL 0`。现在的控是「换算常数」那一块断言加
  `ratio-cross-subject` 消融。
  只在「账号未变」且「两个百分比都没回退」同时成立时才计入。
- **Why / 为什么** — the negative number was **luck**: it was obviously wrong. The same
  contamination producing 0.08 or 0.15 would have looked entirely reasonable, and the
  thresholds are built on this constant. ⭐ **The number itself never tells you the subject
  changed** — the only defence is at the point of accumulation, not on the result.
  负数是**运气**——一眼就看得出不对。同一类污染算出 0.08 或 0.15 会**看起来完全合理**，
  而整套阈值都建立在这个常数上。⭐ **数值本身不会告诉你它换了主体**，
  防线只能在累加入口，不能靠事后看结果合不合理。
- **When you should not / 例外** — if every sample already carries its subject and you
  group before aggregating, you get this for free. The guard exists because the samples
  arrived as a flat series.
  如果每个样本本来就带着主体、且你先分组再聚合，这条自然成立。这条守卫存在是因为
  样本是以一条扁平序列到达的。

### G-8 · Migrating only the side that writes
### G-8 · 迁移只改了写入的那一侧

- **Shape / 问题形态** — when the backup directory moved, only the **writing** side was
  updated; the **reading** side still scanned only the new location. Measured: two accounts
  had credentials that existed **only in the old directory**, and one of them was **in
  active service** — a change described as "just moving a directory" would have made a
  live account vanish from the roster.
  备份目录换位置时只改了**写入**的一侧，**读取**的一侧仍然只扫新位置。实测：有两个账号的
  凭据**只存在于旧目录里**，其中一个**当时还是在役账号**——一次「只是换个目录」的改动
  会让一个正在用的账号从名册里当场消失。
- **Instead / 正确做法** — the reading side scans **both** locations, and the old one is
  scanned permanently: `account-switch :: backup_roots()`.
  读的一侧新旧位置都扫，且旧位置永久保留扫描。
  ⚠️ **Until 2026-08-31 this guard had no assertion, no ablation and no self-test case** —
  `backup_roots` / `backup_candidates` appeared **zero** times in the suite, in
  `test/posctrl.sh` and in `tools/switch-selftest.sh`. Dropping the old root (the incident
  verbatim) left all three fully green. The control is now
  `tools/switch-selftest.sh :: S7` + its negative control `S7n`; it plants a backup that
  exists **only** in the old flat layout and requires `backup_candidates()` to find it.
  ⭐ The pre-existing `S4` cannot cover this: it plants its own backups in the **new**
  directory, so it stays green precisely when the old root is dropped. **"There is a
  rollback test" was not the same claim as "the old root is still scanned."**
  ⚠️ **2026-08-31 之前这条守卫零断言、零消融、零自检用例**：`backup_roots` /
  `backup_candidates` 在回归套件、`test/posctrl.sh`、`tools/switch-selftest.sh` 里的出现
  次数都是 **0**，把旧根丢掉（事故原形）之后三者全绿。现在的控是
  `tools/switch-selftest.sh :: S7` 与负控 `S7n`：种一份**只**存在于旧扁平布局的备份，
  要求 `backup_candidates()` 找得到它。⭐ 原有的 S4 覆盖不了这一格——它自己种的备份在
  **新**目录里，旧根被丢掉时它恰好照常绿。**「有一条回滚测试」和「旧根仍在被扫描」
  从来不是同一句话。**
- **Why / 为什么** — the self-check for this kind of change almost always passes, because
  you verify "did the new file land in the right place" while the defect is in "can the old
  files still be found". It does not error; **the roster just quietly gets shorter**, and
  the entries it loses are the oldest — which are the most likely to be your main accounts.
  这类改动的自检几乎必然通过：你验证的是「新文件写对了地方吗」，而缺陷在「老文件还
  找得到吗」。它不报错，**只是名册悄悄变短**，而变短的那几条恰恰是历史最久、
  最可能是主力的那几个。
- **When you should not / 例外** — if you migrate the data itself and can prove the old
  location is empty, scanning it forever is dead weight. Keep it only while both may exist.
  如果你把数据本身也迁移了、并且能证明旧位置已空，那么永久扫描旧位置就是负担。
  只在「两处都可能有东西」期间保留它。

### G-9 · Tests that can reach production
### G-9 · 测试有能力碰到生产

- **Shape / 问题形态** — twice, and neither was a bug in the code under test. Once a newly
  added ledger path was not redirected to a temporary directory, and the suite wrote **14
  switch records that never happened** into the real ledger. Once the suite **touched live
  sessions**. The post-mortem on the first was blunt: *"enumerating them one by one does
  not work — the second time it was missed the same way."* The second had a precise root
  cause: isolation had been **implicit, unwritten and unguarded** — four functions could
  reach real sessions, they happened to be reached only via two paths, and both those
  paths' cases happened to be stubbed. Adding a new caller turned a side path into a main
  road and the tests walked down it.
  两次，都不是被测代码的问题。一次是新增的台账路径没被改指到临时目录，回归把**14 条从未
  发生过的切号记录**写进了真实台账。一次是回归**动了正在工作的会话**。第一次的检讨很直白：
  「**逐个列举这个办法本身不成立，第二次照样漏。**」第二次的根因很准：隔离此前是
  **隐式的、没写下来、也没人守的**——有四个函数会摸真实会话，它们碰巧只从两条路进入，
  而那两条路的用例碰巧都打了桩。加了个新调用方，岔路变成大路，测试就走了进去。
- **Instead / 正确做法** — three gates, none optional, all in `test/quota-sentinel.test.sh`:
  ① a **construct-time** assertion that enumerates every `QUOTA_*` variable and aborts
  (`exit 3`) under **either** of two predicates: the value points into the real state
  directory, **or** it points somewhere under `$HOME` that is not the sandbox. It tests
  *"could this write"*, not *"did it write"*.
  ⚠️ The second predicate was added because the first was **structurally blind** to the two
  most dangerous paths here — the credential files live under `$HOME` but *not* under the
  state directory, so predicate ① could never warn about them, and that family was still
  guarded only by each case remembering to redirect it. ⭐ The G-9 fix replaced enumeration
  with a structural check, but the *predicate* of that check still covered one family only; ② **default deny** — any session call that was not explicitly stubbed
  is refused and recorded, and restoring a stub restores it to the gate, not to the real
  tool; ③ a **control on the gate itself** — one case deliberately violates it and asserts
  the violation was recorded.
  三道闸，缺一不可：①**构造期**断言（枚举全部状态路径变量，任何一个指向真目录就
  `exit 3`）——它测的是「**有没有可能写**」而不是「有没有真的写」；②**默认拒绝**——
  任何未显式打桩的会话调用一律拦下并记录，恢复打桩时恢复到这道闸、不是恢复到真实工具；
  ③**闸本身的正控**——故意违规一次，断言违规确实被记下来了。
- **Why / 为什么** — ① is the difference between a probabilistic argument and a structural
  one: *"whether it wrote is a matter of chance; whether it points there is a matter of
  construction."* Without ②, the isolation holds **by coincidence** and will break during
  some refactor unrelated to any of this. Without ③, the first two are decoration —
  **a predicate that has never gone red tells you nothing when it is green.**
  ①把一个概率论证换成了结构论证：「**写没写是概率问题，指没指对是构造问题**」。
  没有②，隔离是「碰巧成立」的，会在某次与此无关的重构之后突然失效。没有③，前两道就是
  摆设——**一条从来没红过的判据，绿了也不说明问题。**
- **When you should not / 例外** — if your test process genuinely cannot reach production
  (no credentials, no network, a sealed container), you already have ② for free from the
  environment. Buy these gates when the same process **can** reach both.
  如果你的测试进程结构上就够不着生产（无凭据、无网络、封闭容器），②已经由环境免费提供。
  这几道闸值得买的前提是：同一个进程**够得着**两边。

### G-10 · Anything on a command line is readable by anyone
### G-10 · 命令行上的东西，任何人都读得到

- **Shape / 问题形态** — account addresses were passed to `jq` as `--arg e "$email"`, so
  they sat in that process's `/proc/<pid>/cmdline`, which is **world-readable**. The
  reading loop runs these on **every beat**, so the exposure was continuous rather than
  switch-only. Worse, the monitor's launch command carried four ownership values inside a
  `--settings` JSON — and that process **lives for the whole session**, so an address was
  readable for hours rather than for the microseconds a `jq` call lasts.
  账号地址用 `--arg e "$email"` 交给 `jq`，于是躺在该进程的 `/proc/<pid>/cmdline` 里，
  而那是**世界可读**的。读数主轮**每一拍**都在跑这些 ⇒ 暴露是持续的，不只在切号期间。
  更糟的是 monitor 的启动命令把四个归属值放进 `--settings` JSON，而那个进程**活整个
  会话** ⇒ 一个地址可读数小时，而不是一次 `jq` 调用的那几微秒。
- **Instead / 正确做法** — values travel in the **environment**
  (`QS_JQ_X="$addr" jq … '$ENV.QS_JQ_X'`), and the launch command's ownership values move
  into a `0600` file whose *path* is the only thing left on the command line
  (`lib/reading.sh :: quota_monitor_launch_command()`).
  值改走**环境变量**；启动命令的归属四值改走 `0600` 文件，命令行上只剩一个不敏感的路径。
- **Why / 为什么** — ⚠️ **say precisely what this buys**: `/proc/<pid>/cmdline` is
  world-readable while `/proc/<pid>/environ` is readable **only by the same UID**. So the
  accurate claim is **"no longer readable by ANY user"**, *not* "the address is no longer
  exposed". On a box where you are root anyway, root could always read `environ`.
  ⚠️ **买到什么要说准确**：`cmdline` 世界可读，`environ` **只同 UID 可读** ⇒ 准确说法是
  「**不再对任意用户可读**」，**不是**「地址不再暴露」。在一台你本来就是 root 的机器上，
  root 一直都读得到 `environ`。
- **Is this live on YOUR machine? / 这条在你的机器上是不是活的？** — three questions, each
  with the command that answers it. ⭐ Whether this guard is worth anything is a property of
  **your** host, so the entry hands you the measurement instead of a number from ours.
  三问，每一问都附上回答它的命令。⭐ 这条守卫值不值钱，取决于**你的**宿主 ⇒
  本条给你的是**测法**，不是我们那台机器上的数字。
  1. **Is `/proc` hiding other users' processes?**
     `grep ' /proc ' /proc/self/mountinfo` — look for `hidepid=` or `subset=pid` among the
     options. With neither, `/proc/<pid>/cmdline` is readable by **every local user**.
     **`/proc` 有没有把别人的进程藏起来**：在挂载选项里找 `hidepid=` 或 `subset=pid`；
     两个都没有，`/proc/<pid>/cmdline` 就是**每个本地用户**都读得到。
  2. **Is there anybody to read it?**
     `getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1, $7}'` — name and login
     shell. ⚠️ **What this prints is local ACCOUNTS, not "people who can log in":** an
     account whose 7th field is `/sbin/nologin` or `/bin/false` normally cannot get a
     shell (though a service account may still have some other way in — decide per line,
     do not subtract blindly).
     ⭐ Same discipline as question 3: **this is a list to read line by line, not a count
     to quote.** Service accounts routinely make up a large share of what this prints, so
     an "N other users can see your addresses" summary is easy to get wrong by a wide
     margin — in either direction.
     **有没有人来读**：打印的是名字与登录 shell。⚠️ **它列出的是本地【账号】，不是
     「能登录的人」**：第 7 列是 `/sbin/nologin` 或 `/bin/false` 的通常拿不到 shell
     （但服务账号仍可能有别的入口——**逐行判断，不要盲目相减**）。
     ⭐ 与第 3 问同一条纪律：**这是一份要一条条读的清单，不是一个可以拿去当结论的计数。**
     服务账号往往占了打印结果里相当一部分 ⇒ 一句「有 N 个别的用户看得到你的地址」
     **很容易错得很离谱，而且两个方向都可能错**。
  3. **Is anything of yours on a command line right now?**
     `ps -eo pid,args | grep -F '@' | grep -v grep` — ⚠️ that is a substring match on `@`,
     **not** an address detector: **read the hits, do not count them.**
     **此刻你的东西在不在某条命令行上**：⚠️ 那是对 `@` 的子串匹配，**不是**地址检测器——
     **命中要一条条读，不要拿去当数字用。**
  ⚠️ **If you are root, questions 1 and 3 tell you less than they look like they do**: root
  reads everything regardless, so "I can see it" is no evidence that a non-root user can.
  Question 1 is the one that decides.
  ⚠️ **你如果是 root，第 1、3 问的信息量比看起来少**：root 本来就什么都读得到，
  「我看得见」不构成「非 root 也看得见」的证据。**做判断的是第 1 问。**
- **Why the remedy works, in one line you can run / 修法为什么有效——一行就能自己验** —
  ```sh
  ls -l /proc/$$/cmdline /proc/$$/environ
  # -r--r--r--  cmdline   <- any local user / 任何本地用户
  # -r--------  environ   <- owner only     / 仅属主
  ```
  ⭐ Without this second half a reader cannot tell why moving a value from one to the other
  helps at all. It is also the exact bound on the claim: **"no longer readable by ANY
  user"**, not "no longer exposed".
  ⭐ 没有这后半句，读者根本读不出「把值从前者挪到后者」为什么有用。它同时也正是这条声称的
  边界：是「**不再对任意用户可读**」，不是「不再暴露」。
- **When you should not / 例外** — on a single-user machine this buys you very little, and
  `--arg` is more readable. Pay for it when the machine has other users, or other people's
  processes, that you would rather not hand a list of your account addresses to.
  单用户机器上这条买不到多少东西，而 `--arg` 更好读。值得买的前提是：这台机器上还有
  别的用户或别人的进程，而你不想把自己的账号地址清单送给他们。
  ⭐ The three questions above are how you find out which of those two you are on, instead
  of assuming.
  ⭐ 上面那三问，就是把「我属于哪一种」**真去查一遍**而不是想当然的办法。
- ⚠️ **Two things this does not cover, stated rather than implied**: the static check
  recognises an address **by variable name**, so it answers "did a known address-bearing
  variable get put back on a command line" and *not* "is there an address in argv"; the
  runtime control answers the second question by sampling `ps` and by recording **every**
  `jq` invocation exhaustively, but only along paths that actually ran.
  ⚠️ **两处覆盖不到的地方，明写而不是暗示**：静态判据按**变量名**认地址，它答的是
  「已知持有地址的变量有没有又被放回命令行」，**不答**「argv 里有没有地址」；
  运行时正控用 `ps` 采样并**穷举**记录每一次 `jq` 调用来答后一问，但只看得见真跑到的路径。

---

## Known failure modes / 已知会怎么坏

The test this section has to pass: after reading an entry you can answer **"will this bite
me, on my machine, with my usage?"** Anything that does not reach that bar is disclaimer
boilerplate and should be deleted rather than padded.
本节的判据：读完一条，你必须能回答「**我这台机器、我这个用法，会不会踩到**」。
写不到这个程度的条目就是免责声明套话，该删掉而不是凑数。

Each entry: **when it bites / what it looks like / how to tell it is this one / what to do
now**.
每条四段：**什么条件下会坏 / 表现成什么样 / 怎么确认是不是这条 / 现在怎么办**。

### K1 · A spike from standstill is invisible
### K1 · 从静止直接起飞的飙升看不见

- **When** — usage is flat, then a batch of work starts all at once.
  **条件**：用量原本持平，然后一批活同时开工。
- **Looks like** — two consecutive readings are identical, the rate logic concludes "not
  climbing" and keeps the slow tier, and the entire spike happens **inside that window**.
  Measured: two readings both 47%, and a climb of 53 points in 5m14s occurred between them.
  **表现**：两轮读数完全相同，流速判据据此判「没在涨」、维持慢档，而整个飙升发生在
  **这个窗口内部**。实测：两轮都是 47%，而 5 分 14 秒涨 53 点就发生在中间。
- **How to tell** — a switch that happened at or near 100% with no intermediate readings
  in `quota.log`.
  **怎么确认**：切号发生在 100% 附近，且 `quota.log` 里中间没有任何读数。
- **What to do now** — the rate logic here is **reactive by construction**: it needs two
  differing readings before it can speed up. Upstream had a leading indicator (a count of
  active sessions, which moves *before* the percentage does); that source **was not
  extracted**. Lower `QUOTA_USAGE_INTERVAL_MID`/`_FAR` manually if your workload starts in
  bursts. Cross-reference **K12**, which is the same blind spot on the cadence.
  **怎么办**：本仓的流速判据**结构上是反应式的**，它需要两个不同的读数才能提速。
  上游有一个先行指标（活跃会话数，它在百分比动起来**之前**就变），那个数据源**未抽取**。
  如果你的负载是突发式的，手工调低 `QUOTA_USAGE_INTERVAL_MID`/`_FAR`。
  与 **K12** 交叉引用——那是同一条节拍上的另一个盲点。

### K2 · With the panel blind, OAuth is the only upstream left
### K2 · 面板失明期间只剩 OAuth 一条上游

- **When** — the panel is rate-limited (frequent near the threshold) *and* the OAuth
  endpoint is also limited.
  **条件**：面板被限流（逼近阈值时常见）**且** OAuth 也被限流。
- **Looks like** — **no reading at all**, not a wrong reading. `.fetched_ts` stops
  advancing.
  **表现**：**完全没有读数**，不是错读数。`.fetched_ts` 停止前进。
- **How to tell** — `quota.log` shows both the panel failure and an OAuth `rate_limited`
  outcome in the same period.
  **怎么确认**：同一时段 `quota.log` 里既有面板失败，也有 OAuth 的 `rate_limited`。
- **What to do now** — decisions **fail closed** on a stale ledger, so it will not switch
  on an old level; it simply does nothing until a reading returns. Do not "fix" this by
  polling harder — asking more often is what caused the limiting.
  **怎么办**：台账陈旧时决策**fail closed**，它不会按旧水位切号，只是在读数回来之前什么
  都不做。不要靠「查得更勤」去修它——问得越勤正是被限流的原因。

### K3 · The retired/paused lists are maintained by hand
### K3 · 退役/暂停名单是人工维护的

- **When** — an account recovers, and nobody removes it from the list.
  **条件**：某个账号恢复了，而没人把它从名单里删掉。
- **Looks like** — it is excluded from candidates forever, silently. Also: the lists
  affect **candidate selection only** and do **not** affect the *current* account.
  **表现**：它被永久排除出候选，而且是静默的。另外：名单**只影响挑候选**，
  **不影响当前账号**。
- **How to tell** — `./quota-sentinel status` shows the account, but it never appears in
  `quota_switch_ranked_candidates` output.
  **怎么确认**：`status` 里看得到那个账号，但它从不出现在候选排序输出里。
- **What to do now** — edit `QUOTA_RETIRED_ACCOUNTS` / `QUOTA_DISABLED_ACCOUNTS`. There is
  **no auto-detection and no circuit breaker** in this repo — that is a deliberate
  omission, see the reasoning under **K13**.
  **怎么办**：改 `QUOTA_RETIRED_ACCOUNTS` / `QUOTA_DISABLED_ACCOUNTS`。本仓**没有自动探测、
  也没有熔断**，这是有意省掉的，理由见 **K13**。

### K4 · Why there is no liveness prober here, and what it would cost you
### K4 · 为什么本仓没有活体探测器，以及它会让你付什么代价

⚠️ **Read the classification first**: unlike the other entries, this is **not** something
this repo will do to you. `account-probe` is **read-only** — it queries the usage endpoint
with the existing access token, refreshes nothing and writes no credential. It is listed
here because the reason we ship no prober is itself a failure mode you will meet if you
build one.
⚠️ **先看分类**：与本节其他条目不同，这**不是**本仓会对你做的事。`account-probe` 是
**只读**的——它用现有 access token 查用量接口，不刷新任何东西、不写任何凭据。
它列在这里，是因为「我们为什么不带探测器」这个理由本身，就是你自己造一个时会遇到的故障。

- **When it bites / 什么条件下会坏** — you build a check that copies credentials somewhere
  and makes a **real** call to see whether the account still works.
  你造了一个检查：把凭据拷到某处、发一次**真实**请求，看账号还能不能用。
- **What it looks like / 表现成什么样** — the **first** test succeeds, which gives you
  confidence the approach works. Measured: an account tested successfully at one point was
  `OAuth access token has been revoked` **sixteen minutes later**, using the same backup.
  The cause is that an OAuth refresh **rotates the refresh token** — the old one is void
  immediately and the server issues a new one. That new credential was written into the
  throwaway environment and **never written back**, then overwritten by the next account's
  test. The only usable credential was lost, and the source still held the now-dead token.
  ⭐ **The probe destroyed the account it was probing.**
  **第一次**测试是成功的，于是你得到「这办法可行」的信心。实测：一个账号测试成功，
  **16 分钟后**拿同一份备份再测，得到「access token 已被吊销」。根因是 OAuth 刷新会
  **轮换 refresh token**：旧的当场作废，服务端发一个新的。那份新凭据被写进一次性环境、
  **没有写回来源**，随后测下一个账号时被覆盖 ⇒ 唯一可用的凭据永久丢失，
  而来源里留着的是已作废的旧 token。⭐ **探测动作亲手毁掉了被探测的账号。**
- **How to tell it is this one / 怎么确认是不是这条** — a second probe of the same account
  fails with a revocation error while the first succeeded, and no code changed in between.
  同一个账号第二次探测报吊销错误，而第一次是成功的，中间没有改过任何代码。
- **What to do now / 现在怎么办** — if you build one, it **must write the rotated
  credential back**, into a per-account, timestamped store with restrictive permissions,
  before touching the next account. And know that such a store is credential material that
  now exists on your disk. This repo does not ship this path at all — see **K-gap**.
  你要造的话，它**必须把轮换出来的新凭据写回去**，按账号+时间戳收进权限受限的独立存放点，
  再去动下一个账号；并且要知道那个存放点从此是你磁盘上的凭据材料。本仓不提供这条路，
  见 **K-gap**。
- ⭐ **The general shape**: *the observation changed the observed object* — and the first
  observation succeeded, so the cost only appears on the second and is irreversible.
  ⭐ **普遍形状**：**观测改变了被观测对象**，而且第一次观测是成功的 ⇒
  代价在第二次才出现，且不可逆。

### K5 · Runtime files on disk contain account addresses
### K5 · 运行时落盘文件含账号邮箱

- **When** — always, in normal operation.
  **条件**：正常运行时一直如此。
- **Looks like** — the state ledger, the log, the JSONL event files and the switch ledger
  all record which account a reading or a switch belongs to. **This is the largest PII
  surface of running this tool.**
  **表现**：状态台账、日志、各 JSONL 事件文件与切号流水账都会记下读数或切号属于哪个账号。
  **这是本工具运行期最大的 PII 面。**
- **How to tell** — `grep @ "$QS_STATE_DIR"/*`.
- **What to do now** — put `$QS_STATE_DIR` somewhere with appropriate permissions and
  include it in whatever you already do about local secrets. Note that **G-10 does not help
  here**: that guard is about *command lines*, which other users can read; these are files
  under your own control.
  **怎么办**：把 `$QS_STATE_DIR` 放在权限合适的位置，并纳入你本来就有的本地敏感数据处置。
  注意 **G-10 在这里帮不上忙**：那条守卫管的是**命令行**（别的用户读得到），
  而这些是你自己控制的文件。

### K6 · Verified on exactly one Linux baseline
### K6 · 只在一种 Linux 基线上验证过

- **When** — your `bash`, `jq`, `curl` or libc differ from the verification host —
  especially Alpine/musl, `jq` older than 1.6, or `bash` older than 4.1.
  **条件**：你的 `bash`/`jq`/`curl`/libc 与验证机不同——尤其是 Alpine（musl）、
  `jq` 早于 1.6、`bash` 早于 4.1。
- **Looks like** — usually **not** a startup failure. A `jq` expression returns empty, or a
  `date` flag is not recognised, and the layer above swallows it as "no reading this round".
  You see occasional missing readings, not an error.
  **表现**：多半不是启动失败。某个 `jq` 表达式返回空、某个 `date` flag 不被识别，
  被上层当成「这一轮没读到数」吞掉——你会看到读数偶尔缺失，而不是一条错误。
- **How to tell** — run `bash --version`, `jq --version`, `date -d @0 -u`, `stat -Lc %i .`.
  Any one erroring or printing a different shape is this.
  **怎么确认**：跑上面四条命令，任何一条报错或输出形状不同就是这条。
- **What to do now** — the verification sandbox reuses the host's `/usr`, `/bin`, `/lib`,
  so **"does not depend on the internal workflow layer" is proven; "runs on any
  distribution" is not**. Run the four commands as a self-check. Reports from other
  distributions are the single most useful thing you could send back.
  **怎么办**：验证沙箱复用宿主的 `/usr`、`/bin`、`/lib` ⇒ **「不依赖那套内部工作流层」
  已证，「在任意发行版上能跑」未证**。先跑那四条自查。别的发行版上的反馈是本仓最需要的。

### K7 · A green sandbox does not prove the repo is clean
### K7 · 沙箱跑绿证明不了仓里干净

- **When** — always. This is about how to read our own claims.
  **条件**：一直如此。这条讲的是「怎么读我们自己的声称」。
- **Looks like** — `tools/cleanroom-assert.sh` passing tells you the environment is clean.
  It **does not** isolate the network, and "there are no internal paths or real addresses
  in this repo" is a conclusion from **source and history scanning**, never from a green
  sandbox.
  **表现**：`cleanroom-assert.sh` 全绿说明环境干净。它**不隔离网络**，而且「仓里没有内网
  路径和真实地址」是**源码与历史扫描**的结论，**不是**沙箱跑绿能证明的。
- **How to tell** — read which ranges a leak-scan report names. A working-tree grep covers
  range A only.
  **怎么确认**：看泄漏扫描报告点了哪几个范围。只 grep 工作树只覆盖范围 A。
- **What to do now** — run `tools/dod4-scan.sh` and read its range breakdown, and read
  [docs/REDACTION.md](docs/REDACTION.md), which states what the scanner **structurally
  cannot** see (anything colliding with ordinary English words needs human review).
  **怎么办**：跑 `tools/dod4-scan.sh` 并读它的分范围输出，并读 `docs/REDACTION.md`——
  那里写明了扫描器**结构上看不见**什么（与普通英文词撞名的那一类只能靠人工复核）。

### K8 · `tzdata` is a conditional dependency, and the condition is one env var
### K8 · `tzdata` 是条件依赖，条件就是一个环境变量

- **When it bites / 什么条件下会坏** — you set `QUOTA_FALLBACK_TZ` to a **zone name**
  (e.g. `Asia/Shanghai`) on a machine with no time-zone database — common on minimal
  container images. Left empty (the default) this never bites, because no zone database is
  consulted at all.
  你在一台没有时区库的机器上（最小化容器镜像常见）把 `QUOTA_FALLBACK_TZ` 设成一个
  **区域名**。留空（默认）永远碰不到这条，因为那条路根本不查时区库。
- **What it looks like / 表现成什么样** — **every** invocation of `account-switch` exits
  with `SystemExit` while resolving the display zone, and the message already names both
  ways out. ⚠️ **`--help` is not affected**: the default-empty path never touches the
  database, so `--help` returns 0 with an empty stderr even on a machine that has no
  `tzdata` at all.
  `account-switch` 的**每一次**调用都会在解析显示时区时 `SystemExit`，文案已经把两条出路
  写给你了。⚠️ **`--help` 不受影响**：默认空值那条路根本不碰库，所以哪怕机器上完全没有
  `tzdata`，`--help` 也是 exit 0、stderr 0 字节。
- **How to tell it is this one / 怎么确认是不是这条** —
  `QUOTA_FALLBACK_TZ=<the name you set> ./account-switch --list`.
  ⚠️ **Do not use `--help` to test this** — it gives a **false negative**, for the reason
  in the line above.
  `QUOTA_FALLBACK_TZ=<你设的那个名字> ./account-switch --list`。
  ⚠️ **不要用 `--help` 判**，理由见上一行：它会给你**假阴性**。
- **What to do now / 现在怎么办** — install `tzdata`, or leave `QUOTA_FALLBACK_TZ` empty
  and use the machine's local zone. Full table in
  [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md).
  装 `tzdata`，或把 `QUOTA_FALLBACK_TZ` 留空、用本机时区。完整表见 REQUIREMENTS。

> ⚠️ **Why this entry used to be wrong, kept on purpose.** Until 2026-08-30 this entry
> claimed `tzdata` was a **hard** dependency that failed **at import time**, and told you to
> test it with `--help`. All three were false: `from zoneinfo import ZoneInfo` is a plain
> stdlib import that never reads a database — the read happens on the `ZoneInfo(name)`
> **call** — and on a machine with no zone database `--help` exits 0 with an empty stderr.
> ⭐ The mechanism sentence read perfectly plausibly, which is exactly the failure shape
> **G-4** is about; and `docs/REQUIREMENTS.md` in this same repository had already recorded
> that prediction as overturned. This entry was written from the older material without
> checking it against the repository it ships in. Kept here because the test this K-list
> has to pass is *"after reading an entry you can answer whether it will bite you"* — and
> an entry that tells you to run the one command that cannot detect the problem fails that
> test in the most direct way possible.
> ⚠️ **这一条以前为什么是错的，留在这里是有意的。** 到 2026-08-30 为止本条声称 `tzdata` 是
> **硬**依赖、在 **import 期**抛，并叫你用 `--help` 去测。三件全假：
> `from zoneinfo import ZoneInfo` 是纯 stdlib import，**从不读库**——读库发生在
> `ZoneInfo(name)` 这次**调用**上；而在没有时区库的机器上 `--help` 是 exit 0、stderr 0 字节。
> ⭐ 那段机制描述读起来完全合理，而这正是 **G-4** 讲的那个失效形状；何况**同一个仓**的
> `docs/REQUIREMENTS.md` 早就把那个预测记成已被推翻。本条当时是照旧素材写的，
> 没有拿它所在的这个仓核过一遍。留着，是因为 K 清单要过的判据是
> 「**读完一条你能回答我会不会踩到**」——而一条叫你去跑唯一那条**测不出问题**的命令的条目，
> 是以最直接的方式没过这个判据。

### K9 · The frozen control group is only pinned to itself
### K9 · 冻结对照组只跟自己对得上

- **When** — you rely on the legacy-detector controls as evidence about upstream history.
  **条件**：你把对照组正控当成关于上游历史的证据来用。
- **Looks like** — `test/fixtures/legacy-detectors.sh` carries a content hash that is
  verified on every run. That hash proves **the fixture has not been edited**; it does not
  by itself prove the fixture matches upstream's real historical implementation.
  **表现**：对照组带一个每次运行都校验的内容哈希。那个哈希证明**夹具没被改过**，
  它本身不证明夹具与上游真实历史一致。
- **How to tell** — read the four provenance fields recorded next to the hash.
- **What to do now** — treat the controls as "this predicate fails on this sample", which
  is what they actually assert and is enough for their purpose. ⚠️ **A checksum answers
  integrity, not correctness** — those are different questions and this one is the first.
  **怎么办**：把正控读成「这条判据在这个样本上会失败」，那正是它实际断言的、
  也够用了。⚠️ **校验值答的是完整性不是正确性**，两者是不同的问题。

### K10 · Three registered, unlocated flapping cases came across with the code
### K10 · 三条已登记但未定位的抖动用例随代码一起搬过来

- **When** — unknown; they were never located.
  **条件**：未知，它们从未被定位。
- **Looks like** — intermittent assertion flapping in the detector family.
  **表现**：判据族里断言间歇性抖动。
- **How to tell** — you cannot, reliably. That is the point of this entry.
  **怎么确认**：可靠地确认不了。这正是本条存在的意义。
- **What to do now** — ⚠️ **do not read a green run as evidence that they are fixed.**
  A probable mechanism has since been identified for a related family (`pipefail` turning a
  `grep -q` SIGPIPE into "no match"), and that one **is** fixed — but the original three
  were never tied to it, so they stay listed as *observed, unattributed, unreproduced*.
  **怎么办**：⚠️ **不要因为某次全绿就把它们当已修。**后来在相邻族里定位到一个很可能的
  机制（`pipefail` 把 `grep -q` 的 SIGPIPE 变成「没命中」），那一条**确实**修了——
  但原来那三条从未与它对上，所以仍按「**观测到、未归因、未复现**」记着。

### K11 · A third upstream brings back the duplicate-observation trap
### K11 · 第三条上游一来，重复采信这个坑立刻回来

- **When** — you add a third reading source.
  **条件**：你加第三个读数源。
- **Looks like** — one observation consumed several times, each re-running the decision
  chain. Monotonicity does not stop it, because **91 == 91 is not a decrease**.
  **表现**：同一条观测被连续采信多次，每次重跑一遍决策链。单调性挡不住，
  因为 **91 == 91 不算变低**。
- **How to tell** — repeated identical decisions in `switches.jsonl` with the same reading.
- **What to do now** — the two current upstreams both carry their own observation time, so
  arbitration by time already deduplicates them and this does not occur today. **If you add
  a source that does not carry a timestamp, you must supply one at ingest** — a percentage
  repeats, an instant does not. This is a note for contributors, not a capability claim.
  **怎么办**：当前两条上游都自带观测时刻，按时刻定胜负已经把它去重了，所以今天碰不到。
  **如果你加的源不带时刻，必须在入口处给它盖一个**——百分比会重复，时刻不会。
  这是给贡献者的注意事项，不是一条能力声称。

### K12 · Three snapshot reconciliation items that the tests cannot cover
### K12 · 快照影子期三项对账，回归覆盖不到

- **When** — you turn the snapshot source on.
  **条件**：你打开快照那条源。
- **Looks like** — three open questions that only real running time can answer: whether
  readings for **other** accounts are trustworthy (a different code path — different token,
  different credential file — and the existing consistency evidence comes **entirely from
  the current account**); the real rate of transport-level failures; and **the effect of
  snapshot refreshes on the polling cadence**, which is untested.
  **表现**：三个只能靠真实运行回答的问题——**其他账号**的快照读数是否可信（那是另一条
  代码路径：不同 token、不同凭据文件，而已有的一致性证据**全部来自当前账号**）；
  传输层失败的真实发生率；以及**快照刷新对轮询节拍的影响**，未测。
- **How to tell** — compare the shadow reconciliation lines in `quota.log` against the
  ledger over a period.
  **怎么确认**：拿一段时间的影子对账日志与台账对照。
- **What to do now** — leave it in shadow (it is reconciliation-only and changes no state
  by design) until you have your own evidence. ⚠️ The third item is **the same blind spot
  as K1** — do not read K1 as the only cadence gap.
  **怎么办**：在你自己攒够证据之前让它保持影子（它按设计只对账、不改状态）。
  ⚠️ 第三项与 **K1 是同一族**——别以为节拍上只有 K1 一个盲点。

### K13 · An automatic switch can land on an already-exhausted account
### K13 · 自动切号可能切到一个已经耗尽的账号

- **When** — the candidate's numbers are stale or wrong at the moment of choosing.
  **条件**：挑候选那一刻，候选的数字是旧的或错的。
- **Looks like** — the switch succeeds, and then **whatever is running is interrupted**
  with a subscription/limit error, needing a manual switch back. **This happened twice in a
  single day and has never been located.**
  **表现**：切号成功，然后**正在做的事当场被打断**（报订阅或额度类错误），需要人工切回。
  **一天内发生两次，至今未定位。**
- **How to tell** — `switches.jsonl` shows an `auto` switch immediately followed by a
  manual one back.
  **怎么确认**：`switches.jsonl` 里一条 `auto` 切号后面紧跟一条人工切回。
- **What to do now** — ⚠️ **This is listed as unlocated, not as fixed and not as
  explained.** It sits on the candidate enumeration / ranking / accept-line logic, which
  **is** in this repo. Run in the default `dry-run` mode first and read the decisions it *would* have
  made before you let it act. Note that the accept-line gap under
  [When it switches](#when-it-switches--它什么时候换号) narrows the anti-flap margin, which
  is a plausible contributor but **has not been demonstrated to be the cause** — saying so
  would be exactly the "an explanation that fits is not the mechanism" error this project
  keeps a note about.
  **怎么办**：⚠️ **本条按「未定位」记，既不写成已修、也不写成已知原因。**
  它落在候选枚举/排序/接受线这套逻辑上，而那套**在本仓**。先用 dry-run 跑一段，
  读它「本来会怎么做」，再让它动手。上面提到的接受线缺口会缩小防抖余量，
  它是一个**可能的**促成因素，但**没有被证明是原因**——写成原因就正好犯了
  「一个能解释你手上数据的机制，和造成它的机制，是两件事」那个错。

### K14 · The isolation you set up does not reach the monitor half
### K14 · 你设的隔离到不了 monitor 那一半

- **When it bites / 什么条件下会坏** — you try to confine this tool to a sandbox, or to a
  non-default account, by setting environment variables before running it. This is the
  first thing anyone does, and it is what the audit steps above tell you to do.
  你想把这个工具限制在一个沙箱、或一个非默认账号里跑，办法是运行前设环境变量。
  这是所有人第一个会做的事，也正是上面那几步审计教你做的事。
- **What it looks like / 表现成什么样** — the **bash half obeys you**: `QS_STATE_DIR`,
  `QUOTA_CLAUDE_JSON`, `QUOTA_STATE` all take effect, and `quota-sentinel env` prints
  exactly the values you set. The **monitor half does not**: it is started through
  `tmux new-session`, which is called with **no `-e`**, so the process inherits the tmux
  **server's** environment. `HOME` is not in tmux's `update-environment` list, so the
  `claude` it runs uses the server's `HOME` — i.e. **a different account from the one you
  just configured**, reading that account's real `/usage` panel.
  ⭐ **Nothing reports an error, and `env` keeps printing your value.** The command exits 0.
  **bash 那一半听你的**：`QS_STATE_DIR`、`QUOTA_CLAUDE_JSON`、`QUOTA_STATE` 都生效，
  `quota-sentinel env` 打出来的正是你设的值。**monitor 那一半不听**：它经
  `tmux new-session` 起，而那一行**没有 `-e`**，于是进程继承 tmux **server** 的环境。
  `HOME` 不在 tmux 的 `update-environment` 列表里，所以它跑的那个 `claude` 用的是
  server 的 `HOME`——**也就是另一个账号**，读的是那个账号的真实 `/usage` 面板。
  ⭐ **没有任何报错，而且 `env` 照样打你设的那个值。** 命令 exit 0。
- **How to tell it is this one / 怎么确认是不是这条** —
  ```sh
  pid=$(tmux list-panes -t "$QUOTA_MONITOR_SESSION" -F '#{pane_pid}')
  tr '\0' '\n' < /proc/$pid/environ | grep '^HOME='
  ```
  If that `HOME` is not the one you set, this is it.
  如果那个 `HOME` 不是你设的那个，就是这条。
- **What to do now / 现在怎么办** — pass the environment explicitly on the session
  (`tmux new-session -e HOME=… -e …`), or start a tmux server that already has the
  environment you want, and only then run this tool.
  ⚠️ **Until you have done one of those, do not treat "I set `HOME`" as isolation.**
  在会话上显式传环境（`tmux new-session -e HOME=… -e …`），
  或者先起一个环境就对的 tmux server，再跑这个工具。
  ⚠️ **在做到之前，不要把「我设了 `HOME`」当成隔离。**
- ⭐ **Why this is stated as a broken assumption rather than a tip**: the failure is
  silent, and every signal you would normally check agrees with you. This repository's own
  regression suite is only safe from it because of a **global default-deny tmux gate**
  (see **G-9** gate ②) — **there is no equivalent gate on the product side.** The lesson
  G-9 records ("isolation was implicit, unwritten and unguarded") was closed **in the
  tests** and is still open **in the tool**.
  ⭐ **为什么写成「你的前提不成立」而不是一条提示**：这个失效是静默的，而你通常会去核的
  每一个信号都和你说的一样。本仓自己的回归之所以不出事，靠的是一道**全局默认拒绝的
  tmux 闸**（见 **G-9** 第②道）——**产品侧没有对应的闸**。G-9 记下的那句教训
  （「隔离此前是隐式的、没写下来、也没人守的」）在**回归里**被收口了，在**工具里**还开着。
- ⚠️ **Scope / 射程**: this entry documents the behaviour; it does **not** change it.
  Whether the launch path should pass the environment explicitly is a change to a running
  mechanism and is deliberately left as an open item rather than slipped into a
  documentation milestone.
  ⚠️ 本条**只记录**这个行为，**不改**它。启动路径该不该显式传环境属于改动在跑机制，
  **有意**留作公开未达项，而不是塞进一个文档里程碑里顺手改掉。

### K15 · The debugging switch records the whole screen, not the panel
### K15 · 调试开关记的是整张屏，不是那块面板

- **When it bites / 什么条件下会坏** — you set `QUOTA_PANEL_TEXT_CAPTURE=1` to investigate
  something and forget to set it back; or you point the monitor at a session that shows
  anything besides `/usage`. Either way the sampler is `tmux capture-pane -p`, which
  returns **the whole visible pane**, not the four lines it parses.
  你为了查一件事设了 `QUOTA_PANEL_TEXT_CAPTURE=1`，然后忘了改回去；或者你让 monitor
  盯着一个不止显示 `/usage` 的会话。两种情况下采样都是 `tmux capture-pane -p`，
  它返回的是**整个可见 pane**，不是它要解析的那四行。
- **What it looks like / 表现成什么样** — **nothing**. No error, no log line, no change in
  behaviour. `quota-panel-observations.jsonl` just starts carrying, once every 10 seconds
  for seven days, every visible line of that pane.
  **什么都看不出来**：不报错、日志里没有一行、行为不变。只是
  `quota-panel-observations.jsonl` 开始每 10 秒一条、留七天地装下那个 pane 上的每一行。
- **How to tell it is this one / 怎么确认是不是这条** —
  ```sh
  jq -r 'select(.panel_text_captured) | .observed_at' \
     "$QS_STATE_DIR/quota-panel-observations.jsonl" | tail -3
  ```
  Any output means capture was on for those records. Every record states which way it was
  written, so a file with the switch flipped mid-run is still readable line by line.
  有输出就说明那些记录是开着 capture 写的。每条记录都写明自己是按哪种方式写的，
  所以开关中途翻过的文件仍然可以逐行读懂。
- **What to do now / 现在怎么办** — set it back to `0` when the investigation window ends,
  and lower `QUOTA_PANEL_RETENTION_SEC` while it is on. Two measurements, each with its
  own scope, because the ratio depends on **your** pane: with capture **on**, on the
  extraction host, 2026-08-31, 10s sampling, 7-day retention — 247 MB across 73,828
  records ≈ 3.3 KB each; with the **default**, from a synthetic 7-line frame here — ≈ 0.56
  KB each. ⇒ ≈ **6×** at that host's frame size. ⭐ Not "an order of magnitude": only the
  `panel_text` part grows with your pane, so the multiple is whatever your pane is, and
  the first number is one host with one configuration and one panel layout. Sample your
  own file rather than assuming either transfers. ⚠️ The first figure is **an observation
  from a different machine, relayed here, not measured in this repo**; only the ≈ 0.56 KB
  was measured here. It is kept — while other measurements from that host were deliberately
  removed — because it is a **capacity** observation that exposes no weakness and is the
  evidence for why this default exists; what was removed was a **security posture**. See
  the note at `QUOTA_PANEL_TEXT_CAPTURE` in `lib/config.sh`. The file is `0600`, but it is
  a plain file: if you back up `$QS_STATE_DIR`, you back this up too.
  查完就设回 `0`；开着的期间把 `QUOTA_PANEL_RETENTION_SEC` 调小。两个数、各带各的口径，
  因为比例取决于**你的** pane：capture **开** —— 抽取宿主 2026-08-31 实测、10s 采样、
  7 天保留：247 MB / 73,828 条 ≈ 每条 3.3 KB；**默认** —— 本仓用一帧 7 行的合成夹具实测
  ≈ 每条 0.56 KB。⇒ 在那台宿主的帧尺寸下约 **6 倍**。⭐ 不是「一个数量级」：只有
  `panel_text` 那部分随你的 pane 增长，倍数就是你的 pane 有多大；而前一个数是一台机器、
  一套配置、一种面板排版。请量你自己那份文件，别假定其中任何一个对你也成立。
  ⚠️ 前一个数是**另一台机器上的观测、转述到这里的，不是本仓量的**；只有 ≈ 0.56 KB 是本仓
  实测。同一台宿主的别的实测被有意拿掉了而它留着，是因为它是**容量**观测、不暴露任何弱点，
  且它正是「这个默认值为什么存在」的证据；拿掉的那些是**安全姿态**。
  详见 `lib/config.sh` 里 `QUOTA_PANEL_TEXT_CAPTURE` 那段。
  文件是 `0600`，但它就是个普通文件：你备份 `$QS_STATE_DIR`，就一起备份了它。
- ⭐ **Why the default is off rather than "documented"** — this default decides what ends
  up on **someone else's** disk. Here the monitored session only ever runs `/usage`, so
  the frames only ever held quota numbers; that is a property of how **we** run it, not of
  this tool, and it stops being true the moment anyone else installs it.
  ⭐ **为什么是默认关，而不是「写进文档」** —— 这个默认值决定的是**别人**的磁盘上会留下
  什么。在我们这边被监控的会话只跑 `/usage`，帧里只有额度数字；那是**我们**的用法的性质，
  不是这个工具的性质，换一个人装上就不再成立。
- ⚠️ **What the default still stores / 默认下仍然存的东西** — the sha256 of every frame is
  always recorded. It does not let anyone read a screen back, but it does let someone who
  can **guess** a screen confirm the guess. Stated because "we only store a hash" is
  routinely read as "we store nothing".
  每一帧的 sha256 一律记录。它不让任何人**读回**一张屏，但它让**猜得出**某张屏的人确认自己
  猜对了。写出来是因为「我们只存了哈希」经常被读成「我们什么都没存」。

- ⚠️ **One screen-grabbing path this switch does not cover / 有一条取屏路径这个开关管不到** —
  `quota_capture_pane_tail` (`lib/state.sh`) runs its own `tmux capture-pane -S -50`. It
  currently has **zero call sites**, so nothing happens today; it is named here because
  "dead code" and "covered by the default" are not the same statement, and only the first
  one is true of it. If a future change reconnects it, the frame it returns is outside
  everything described above.
  `quota_capture_pane_tail`（`lib/state.sh`）自己会跑 `tmux capture-pane -S -50`。
  它目前**零调用点**，所以今天什么也不会发生；写在这里是因为「它是死代码」与
  「它被这个默认值覆盖了」是两句不同的话，**只有前一句对它成立**。将来哪次改动把它接上，
  它取回来的那一屏不在上面任何一句的射程里。

### K-gap · Guards that did not come across / 没有随抽取过来的守卫

Two incident stories above (**G-3** liveness probing, and **K4**'s prober) are told for
their *reasoning and evidence*. The executing guard needed Docker and a prepared container
and **was not extracted** — so there is **no `--health` flag in this repository at all**,
and `account-probe`'s only modes are the read-only ones its `--help` lists. That is stated
plainly rather than softened to "optional", because a reader who goes looking for a flag we
described will not find one. Also absent: the all-exhausted wait state machine,
so the "denominator" half of the roster discipline (excluding dead accounts from *"is
everything full?"*, not merely from candidates) has **no subject here** — it is described
in `docs/PROVENANCE.md` under what was not extracted, rather than implied to exist.
上面两条事故（G-3 活体探测、K4 的探测器）讲的是**推理与证据**。执行那条判据的东西需要
Docker 与一个配好的容器，**未随抽取过来** ⇒ **本仓根本没有 `--health` 这个 flag**，
`account-probe` 只有它 `--help` 列出的那几个只读模式。这里直说而不是软化成「可选」，
因为一个照着我们的描述去找那个 flag 的读者会找不到。同样缺席的还有全撞限等待状态机，因此名册纪律里「**分母**」那一半
（把死账号排除出「是不是全都满了」，而不只是排除出候选）在本仓**没有对象**——
这一点写在 `docs/PROVENANCE.md` 的未抽取清单里，而不是被暗示成存在。

---

## What this does not do / 不解决什么

Each item says what to use instead. "We do not do X" on its own is not useful.
每条都写清「那你该用什么」。光说「我们不做 X」没有用。

- **Not a polished product.** No installer, no GUI, no menu bar. **Want those? Use
  [claude-swap](https://github.com/realiti4/claude-swap)** — it installs via
  `uv tool install` / `pipx install`, has a dashboard and a macOS menu bar, and supports
  macOS/Linux/Windows/WSL. Its feature surface is considerably larger than this repo's.
  🟨 *That description comes from its README; we did not read its code.*
  **不是开箱即用的产品**：没有安装包、没有图形界面、没有菜单栏。**要这些请用 claude-swap**
  ——它有安装包、有面板、有 macOS 菜单栏、支持四个平台，功能面比本仓完整得多。
  🟨 *以上描述来自它的 README，我们没有读它的代码。*
- **Linux only.** The GNU-specific flags that would break elsewhere are enumerated in
  [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) — `date -d`, `stat -Lc`, `readlink -f`,
  `grep -oE`, `sed -E`, `sort -k1,1 -rn`, and others — rather than a vague "untested on
  macOS".
  **只承诺 Linux**：会在别处坏掉的 GNU 专有 flag 已逐条列在 REQUIREMENTS，
  不是含糊说一句「未在 macOS 测过」。
- **No orchestration layer.** Extracted from a multi-session scheduling system; session
  enumeration, task dispatch, screen archiving and daemon integration **did not come with
  it** — and neither did the capabilities that depended on them (see K1, K-gap).
  **不搬工作流层**：抽取自一套多会话调度系统，但会话枚举、任务派发、屏幕留档、守护进程
  集成**一律不随之而来**，依赖它们的能力也就没有。
- **Not a proxy gateway.** It does not intercept or rewrite API traffic.
  **不做代理网关**：不拦截、不改写 API 流量。
- **No team account pool.** Explicitly unsupported — see the terms note below.
  **不做团队共享账号池**：明确不支持，理由见下面条款一节。
- **Nothing that evades limits.** See below.
  **不做任何形式的封禁规避**：见下。
- **Not tracked upstream.** Extracted at a fixed commit; upstream changes after it are
  **not** followed and **not** synced back.
  **不承诺与上游同步**：抽取自一个固定 commit，之后的上游改动不追平、不双向同步。

## Terms / 条款

Not legal advice; read the primary sources yourself, and note the retrieval date on
anything you rely on.
不构成法律意见；请自己读原文，并给你依赖的任何一条记下取得日期。

🔴 **The two halves of this project are not covered the same way, and merging them into one
sentence would be the dishonest move.** Switching between your own accounts by replacing
credential files runs an unmodified client, for which the consumer terms carry an explicit
allowance. **Querying the usage endpoint directly is a different matter**: it is not a
documented public interface, no allowance covers it, and that section ends with wording
reserving enforcement without prior notice.
🔴 **本项目的两半不受同一条款覆盖，把它们合成一句话正是不诚实的做法。**
在自己的账号之间换凭据文件、跑未经修改的客户端，这一半有明文豁免可依；
**直接查用量接口是另一回事**：它不是文档化的公开接口，没有任何豁免覆盖它，
而那一节末句写着可不经预先通知即执行。

- **Say what it actually does.** Not "it reads your quota" but **"it uses a full session
  credential to call an undocumented endpoint"**. If that sentence bothers you, that is the
  correct reaction to have *before* installing rather than after.
  **把它实际在做的事说出来**：不是「读一下额度」，而是「**它用完整会话凭据读一个未公开的
  端点**」。如果这句话让你不安，那正是**装之前**该有的反应。
- **Individual rotation and team sharing are different.** The clause that lands on concrete
  behaviour is the one about not sharing account login information with others. Rotating
  **your own** accounts does not fall under it; **a shared team pool does** — which is why
  the previous section says that is unsupported.
  **个人轮换与团队共用不是一回事**：能落到具体行为上的那条是「不得与他人共享账号登录
  信息」。轮换**你自己的**账号不落在里面；**团队共用正好落在里面**——这就是上一节写明
  不支持的原因。
- **Wording discipline, applied to ourselves.** This tool is not described as a way around
  a limit. What it does is **choose which of several accounts you own is the current one**.
  ⭐ Describing it as "bypassing limits" would be us handing it to that clause.
  **措辞纪律，对我们自己也适用**：本工具不写成「绕开额度限制的手段」。
  它实际做的是「**在你自有的多个订阅之间选择当前使用哪一个**」。
  ⭐ 把它描述成「绕过限制」，是我们自己把它往那条条文上送。

## Relationship to the official position / 与官方的关系

The canonical request for account switching was closed by a maintainer as **completed**,
with the answer being **one config directory per account plus a shell alias** (via
`CLAUDE_CONFIG_DIR`). 🟦 *Read the issue in full.*

⚠️ **That is isolation, not switching, and the difference is the whole reason this exists**:
isolation decides *who* at **launch time**; a quota decision has to change *who* **at run
time**. ⚠️ **This is not a refusal.** Maintainers have not commented on automatic
failover one way or the other, and we are not going to represent silence as a position.

官方那条 canonical 请求由维护者以 **completed** 关闭，给出的答案是
**每账号一个配置目录 + alias**。🟦 *整页读过。*
⚠️ **那是「隔离」不是「切换」，而这个差别正是本项目存在的理由**：隔离在**启动时**决定用谁，
额度判断要在**运行中**换人。⚠️ **这不是「官方拒绝了」**——维护者从未就自动故障转移表过态，
我们不会把沉默说成一个立场。

There **is** an official field: the status-line stdin JSON carries `rate_limits`. Three
documented constraints, and they decide what it can be used for: it is pushed **only
inside a session**; it covers **only the currently logged-in account**; and it appears
**only after the first API response**. 🟦 *From the official status-line documentation.*
There is also **no timestamp in that payload** — `resets_at` is when the *window* resets,
not when the reading was taken — so a consumer **cannot tell from the data how old it is**.

官方确实有一个**字段**：状态行 stdin JSON 里的 `rate_limits`。三条文档化的硬限制决定了它能
干什么：**只在会话内推**、**只覆盖当前登录那一个账号**、**只在首个 API 响应之后出现**。
🟦 *出自官方状态行文档。* 而且**该 payload 里没有任何读数时刻**——`resets_at` 是**窗口**
重置时刻不是读数时刻 ⇒ 拿到数的人**无法从数据本身知道它多旧**。

> The official field answers "what percentage has the account I am using consumed right
> now". This project answers "**can the accounts I am *not* using take over, and will
> switching to one of them walk straight into a wall**".
> 官方给的是「你正在用的这个账号此刻用了百分之几」；我们给的是「你没在用的那些账号能不能
> 顶上、顶上去会不会当场把自己打死」。

⚠️ **A structural consequence worth stating**: because the stdin reading only refreshes
while a session is active, it **freezes at the last API response when the session stops —
and nothing tells you it froze**. That is itself a textbook "known failure mode", and it is
why this project does not build its floor on that channel.
⚠️ **一条值得写出来的结构性后果**：stdin 读数只在会话活跃时刷新，会话一停就**冻在最后一次
API 响应上，而且不会有任何东西告诉你它冻住了**。这本身就是一条标准的「已知会怎么坏」，
也是本项目不把地基建在那条通路上的原因。

---

## Verifying the guards / 每条守卫怎么自证

The hard claim of this repository is **not** an assertion count. It is:
**every guard that ships here can be made to go red on demand, that is delivered as a
runnable artifact, and the entries this does not cover are named rather than left to be
inferred** — see [What the red-state claim covers](#what-the-red-state-claim-covers--这句总括声称的分母)
just below.

本仓的硬指标**不是**断言条数，而是：**凡是在本仓交付的守卫都能当场证明它会红、这件事是
作为可运行的产物交付的，且它覆盖不到的条目是被点名的、不留给人猜**——见下面
「这句总括声称的分母」。

```sh
bash test/quota-sentinel.test.sh      # the suite / 回归套件
bash test/posctrl.sh                  # prove each guard goes red / 逐条证明守卫会红
bash tools/credential-argv-control.sh # runtime control for G-10 / G-10 的运行时正控
bash tools/dod4-scan.sh               # leak scan, five ranges / 五范围泄漏扫描
bash tools/dod4-scan.posctrl.sh       # prove all five ranges go red / 证明五个范围都会红
```

`test/posctrl.sh` takes a copy of the repository, **breaks exactly the thing one guard is
watching**, re-runs the suite against the copy, and requires **the named assertion** to go
red — not "the run failed", which could be anything. It ends with a **negative control**:
an unmutated copy must come out fully green, without which "everything went red" would look
like perfect discriminating power while actually meaning the harness breaks every copy.

`test/posctrl.sh` 复制一份仓库，**只弄坏某条守卫盯着的那件事**，对副本重跑回归，
并要求**点名的那条断言**变红——不是「这次跑挂了」，那可能是任何原因。末尾有一条**负控**：
未改动的副本必须全绿，没有它，「全都红了」看起来像分辨力满分，实际可能只说明这套脚手架
把每一份副本都弄坏了。

⚠️ **Four boundaries, stated rather than left to be assumed. The last two were added on
2026-08-31, after boundary 2 was found being read as cover for guards with no assertion at
all:**
1. **Ablations mutate the *triggering condition*, not the guard itself.** Deleting a guard
   and observing that nothing fires measures "what it looks like with no guard", which is a
   different question.
2. **Not every assertion has an ablation.** The ones that do were chosen for the class
   *"remove this and the system fails **silently**"*. An assertion without an ablation is
   not thereby proven worthless — it is unproven, which is not the same thing.
3. ⚠️ **This exemption covers the assertion↔ablation pair, and nothing wider.** It says
   some assertions lack an ablation; it does **not** excuse a guard that has **no
   assertion at all**, which never enters the pair and so cannot be exempted by it. Three
   such guards were found on 2026-08-31 — G-7's `quota_ratio_update()`, G-8's
   `backup_roots()`, and G-4's fallback offset self-check — and all three now have
   controls. **Do not cite boundary 2 against a guard with zero assertions** — that is the
   reading under which "nothing tests this" and "this is a documented exception" become the
   same sentence.
4. ⚠️ **A proven entry is not a proven mechanism.** An entry that cites four functions is
   proven when *one* of them goes red; the other three may still be unexercised. The ones
   measured as unproven are named in
   [What the red-state claim covers](#what-the-red-state-claim-covers--这句总括声称的分母).

⚠️ **四条边界，写明而不是留给人猜（后两条是 2026-08-31 补的，起因是第②条被当成了
「零断言守卫」的挡箭牌）**：①**消融动的是「触发条件」，不是守卫本身**——
把守卫整个拆掉再看它不响，测的是「没有守卫时的样子」，那是另一个问题。
②**不是每条断言都有消融**：配了的那些挑的是「拿掉它系统会**静默地**错」那一类。
一条没有消融的断言不因此就是没用的，它是**未被证明**的——这两件事不一样。
③⚠️ **这条豁免覆盖的是「断言↔消融」这一对，不覆盖更宽的东西。**它说的是有些断言没配消融；
它**不豁免一条断言都没有的守卫**——那种守卫压根进不到这一对里，也就无从被它豁免。
2026-08-31 实测查出**三条**这样的守卫（G-7 的 `quota_ratio_update()`、G-8 的
`backup_roots()`、G-4 的兜底偏移自检），现已各自补控。
**不要拿第②条去搪塞一条零断言的守卫**：那种读法会让「没有任何东西测它」
与「这是写明的例外」变成同一句话。
④⚠️ **条目被证明 ≠ 它点名的每个机制都被证明。**一条点名了四个函数的条目，只要其中
**一个**会红它就算已证明，另外三个仍可能从未被执行。实测未被证明的那几个逐条列在
「这句总括声称的分母」。

### What the red-state claim covers / 这句总括声称的分母

⚠️ **Written because the claim above is this repository's headline, and a headline claim
whose denominator was never computed is the exact defect this repository exists to warn
about.** Established 2026-08-31 by injecting a defect into each guard's own triggering
condition (1–2 lines) and re-running the suite — not by reading code, not by counting how
many times a function name appears in the tests.
⚠️ **写下来是因为上面那句是本仓的招牌，而一句从没算过分母的招牌声称，正是本仓自己反复
警告的那类缺陷。** 2026-08-31 用「往每条守卫自己的触发条件里定点注入 1–2 行反例、重跑套件」
逐条实测得出——不是读代码推断，也不是数函数名在测试里出现过几次。

**Proven: 9 of the 10 entries.** G-1, G-2, G-4, G-5, G-6, G-7, G-8, G-9, G-10 each have at
least one shipped guard that went red on a named assertion when its triggering condition
was broken.
**已证明：十条里的九条。** G-1、G-2、G-4、G-5、G-6、G-7、G-8、G-9、G-10 都有至少一条出厂
守卫，在触发条件被弄坏时让一条**点名的断言**变红。

**Not proven, and why — read this as the claim's exclusion list, not as a to-do list:**

| what / 什么 | status / 状态 |
|---|---|
| **G-3** as a whole | The executing half (the isolated-container liveness prober) **was not extracted** — see that entry's own ⚠️ Scope note. What ships is the evidence, the reasoning, and a read-only usage query that needs a live account and network to run at all. **There is no triggering condition to break here**, so G-3 is excluded from the numerator rather than counted as passing. / 执行的那一半（容器活体探测器）**没有抽取过来**，本仓没有可弄坏的触发条件 ⇒ G-3 不计入分子，也不算通过。 |
| **G-4** · a zone file that exists but is **corrupt** | The fallback self-check now asks whether the C library can resolve the spec, and it answers that by requiring a readable zone definition to exist. It does **not** verify that glibc parsed it successfully, so a corrupt zone file is still accepted and would still degrade to UTC. The rest of that self-check *is* proven (bare abbreviations, non-existent zones, a directory name, and a host with no `tzdata` all go red on named assertions) — **this one sliver is not**, and it is listed rather than folded into the fixed part. / 该自检现在问的是「C 库解析不解析得了」，而它是用「存在且可读的时区定义」来回答的。它**不**验证 glibc 真的解析成功 ⇒ 一份**损坏**的时区文件仍会被接受、仍会降级成 UTC。这条自检的其余部分已被证明（裸缩写、不存在的时区、目录名、无 `tzdata` 的宿主，四种都会让点名断言变红），**唯独这一格没有**，所以单列出来，不并进已修的那部分。 |
| **G-1** · either window-order branch **alone** | Disabling *one* of the two `quota_reset_later_window` branches in `quota_frame_stale()` leaves the suite green — the other branch catches the same fixtures. G-1 is proven at the **mechanism** level (disabling the shared primitive turns 3 assertions red), not per branch. / 单独关掉两条窗口序分支里的任何一条，套件仍全绿（另一条兜住了同一批夹具）。G-1 是在**机制**层证明的，不是逐分支。 |
| **G-2** · the *empty* cache field | The shipped case covers a **stale** `usage_uuid`. The literal incident was a cache field that came back **empty** from a restore; widening the identity-missing predicate to include `-z "$usage_uuid"` stays green. / 出厂用例覆盖的是缓存**滞后**；事故原形是恢复后缓存**为空**，把它加进 identity-missing 判据套件仍全绿。 |
| the range-C **allowance** in `tools/dod4-allow.local.txt` | The allowance is correctly literal-scoped (verified: a different local part at the same domain is still reported). But **no standing control covers it**, and `tools/dod4-scan.posctrl.sh` structurally cannot: it plants its own `*.local.txt` marker files into a throwaway clone and a gitignored allow file cannot travel there. Measured 2026-08-31 — with a deliberately domain-wide allowance in force, `dod4-scan.sh` reported **`CLEAN hits=0`** while `dod4-scan.posctrl.sh` still reported **`RANGE C-message fired OK`** and `POSCTRL_RESULT=PASS`. ⭐ That control proves the C **traversal** runs; it cannot prove the C **verdict** is unblinded. / 该豁免的射程确实是字面串（已复核：同域另一地址仍被报出）。但**没有常设控**，而且 `dod4-scan.posctrl.sh` 结构上也做不到：它往一次性 clone 里自己种 `*.local.txt` 标记，而已 gitignore 的 allow 文件根本进不了那份 clone。实测：把豁免故意放宽成整域之后，`dod4-scan.sh` 报 **`CLEAN hits=0`**，而 posctrl 仍报 **`RANGE C-message fired OK`**。⭐ 它证明的是 C 范围**走到了**，不是 C 范围的**结论没被蒙住**。 |

**Fixed on 2026-08-31 rather than excluded — three guards that were green for the wrong
reason.** Listed here because the audit that found them is what this section documents, and
because two of the three failed in ways worth telling apart:

- **Never executed** (2): `quota_ratio_update()` (G-7) could be replaced wholesale by
  `{ return 0; }`, and `backup_roots()` (G-8) could drop its old root, with **the suite,
  the ablations and `switch-selftest` all staying green on both**.
- **Executed on every parse, but always true** (1): the fallback offset self-check in
  `quota_parse_reset_epoch()` / `quota_panel_reset_epoch()` tested `%z =~ ^[+-][0-9]{4}$`,
  which **accepts `+0000`** — precisely what a bare abbreviation degrades to (`TZ=CST date
  +%z` → `+0000` on this host). It ran constantly and could not fail. ⭐ **This is the
  harder of the two to notice**: a guard that never runs at least leaves a coverage hole
  someone might count, whereas an always-true guard reports success forever. The predicate
  now asks whether the C library **can actually resolve the spec**
  (`quota_tz_spec_usable()` in `lib/config.sh`), never the numeric offset and never the
  spelling.
  🩸 **The first replacement for it was itself wrong, and that is worth recording rather
  than tidying away.** It tested the *shape* of the spec — "a bare abbreviation is
  suspicious" — which let `Etc` (a directory), `Z` (no such zone), `Asia/Nowhere` and
  `Foo/Bar` straight through at a silent `+0000`, and turned away **31 real zones** whose
  names are ordinary words with no slash (`Japan`, `EST`, `Iran`, `CET`, `Poland`…).
  ⭐ **A name being well-formed says nothing about whether anything answers to it** — and
  the control written alongside it did not catch either half, because its five accept-side
  samples were all specs the *old* predicate already accepted: **none of them landed on the
  boundary the new rule had just drawn**. A control whose samples do not straddle the new
  boundary is not testing the change; it is re-testing the behaviour that did not change.

Each of the three now has a control that was **verified red against the real defect, not
against a stand-in**.
**2026-08-31 修掉而不是列进例外的三条——三条「绿得没道理」的守卫。** 列在这里是因为
本节记录的正是那次核查；而三条里有两种不同的坏法，值得分开说：

- **从未被执行**（2 条）：`quota_ratio_update()`（G-7）可以整个换成 `{ return 0; }`，
  `backup_roots()`（G-8）可以把旧根丢掉，而**回归套件、消融表与 switch-selftest 三者全绿**。
- **每次解析都执行，但恒真**（1 条）：兜底偏移自检判的是 `%z =~ ^[+-][0-9]{4}$`，
  它**接受 `+0000`**——而裸缩写恰恰就降级成 `+0000`（本机 `TZ=CST date +%z` → `+0000`）。
  它一直在跑，却不可能失败。⭐ **这一种比前一种更难发现**：不跑的守卫至少留下一个能被
  数出来的覆盖空洞，而恒真的守卫会永远报成功。现在的判据问的是**C 库到底解析不解析得了
  这个规格**（`lib/config.sh :: quota_tz_spec_usable()`），既不看偏移量数值也不看拼写。
  🩸 **它的第一版替代品本身也是错的，这一点记下来而不是抹掉。** 那一版判的是规格的
  **形态**——「裸缩写可疑」——于是放过了 `Etc`（目录）、`Z`（库里没有）、`Asia/Nowhere`、
  `Foo/Bar`（四个全部静默 `+0000`），又误拒了 **31 个真实时区**——它们的名字就是不带斜杠的
  普通词（`Japan`、`EST`、`Iran`、`CET`、`Poland`……）。
  ⭐ **名字长得规整，不说明有东西回应它**；而当时配的那条控两侧都没抓到，因为它接受侧的
  五个样本**在旧判据下本来就全部被接受**——**没有一个落在新规则刚划出的边界上**。
  一条样本不跨越新边界的控，测的不是这次改动，而是没变的那部分行为。

三条现在各自都有控，且都是拿**真实缺陷**验过会红，不是拿替身验的。

🔴 **We have not found a comparable project shipping this as a publicly checkable
artifact.** Note the wording: **"we have not found"**, not "nobody does". Incident-driven
guards are standard practice in mature projects, and several projects we looked at have
substantially larger test suites than this one; what we have not found is the *red-state
reproducibility* packaged so an outsider can re-run it. 🟩 *For one comparable project we
opened the code and confirmed it has no mutation testing, no ablations, and no CI running
its tests — that is a statement about that repository at one commit, and nothing more.*

🔴 **我们没有找到把这件事作为公开可核对产物交付的同类项目。**注意措辞：
**「我们没有找到」**，不是「没有人做」。事故驱动的守卫是成熟项目的标配，
我们看过的好几个项目测试量比本仓大得多；我们没找到的是把**红态可复现**包装成外人可以
自己重跑的产物。🟩 *其中一个同类项目我们打开了代码，确认它没有变异测试、没有消融、
也没有任何跑测试的 CI——这是关于那个仓在某个 commit 上的陈述，仅此而已。*

---

### Leak scan — already in force / 泄漏扫描（已生效，非占位）

```sh
tools/dod4-scan.sh            # scan this repo / 扫描本仓
tools/dod4-scan.posctrl.sh    # prove all five ranges really go red / 逐范围证明它会红
```

The scan covers **five ranges**: **A** working tree (hidden and binary files included),
**B** every blob in every commit, **C** commit messages, **D** author/committer identity,
**E** path names. Range **B** is the one that matters most before going public — a secret
that was committed and then deleted in the next commit is gone from the working tree but
still sits in the pack, and **no amount of grepping the working tree will ever see it**.

扫描覆盖**五个范围**：**A** 工作树（含隐藏与二进制文件）、**B** 每个 commit 的每个 blob、
**C** commit message、**D** author/committer 身份、**E** 路径名。转公开前最要紧的是范围
**B**：提交过、下个 commit 又删掉的凭据已从工作树消失，却仍留在对象库里，**再怎么 grep
工作树也永远看不见它**。

⚠️ Never report "DoD-4 passed" without naming the ranges that were scanned. A working-tree
grep alone covers range A; its zero says nothing about B–E.
⚠️ 报「DoD-4 通过」必须同时写明扫过哪些范围。只 grep 工作树只覆盖 A，它的那个 0 对
B–E 什么都没说。

Site-specific strings (internal hostnames, account rosters, private repo names) go in
`tools/dod4-*.local.txt`, which is gitignored — never in the `*.example.txt` files, which
are published.
站点专有字符串（内部主机名、账号名册、私有仓名）写进已被 gitignore 的
`tools/dod4-*.local.txt`，绝不要写进会被公开的 `*.example.txt`。

---

## Requirements / 运行前提

The full list, with what is **not** required and why, is in
[docs/REQUIREMENTS.md](docs/REQUIREMENTS.md). Short version: `bash` >= 4.1, `jq`, plus
`tmux` and a logged-in `claude` for the panel reader and `curl` for the OAuth reader, plus
**`python3` >= 3.9 for the switching half** (`account-switch`). **`tzdata` only if you set
`QUOTA_FALLBACK_TZ` to a zone name** — left empty, the default, no zone database is
consulted. Linux only; macOS and Windows are **unverified**, and that document names the
specific GNU-only flags that would break there rather than leaving it vague.
完整清单（含**不需要**什么、为什么）见 [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)。
短版：`bash` >= 4.1、`jq`，面板读数那条链另需 `tmux` 与已登录的 `claude`，
OAuth 直查另需 `curl`，切号那一半另需 **`python3` >= 3.9**（`account-switch`）。
**`tzdata` 仅当你把 `QUOTA_FALLBACK_TZ` 设成区域名时才需要**——留空（默认）不查时区库。
只保证 Linux；macOS 与 Windows**未验证**，
该文档写明了具体会在哪些 GNU 专有 flag 上坏，而不是含糊带过。

⚠️ This short version and the one under [Quick start](#quick-start--一分钟跑起来) must
agree. They did not until 2026-08-30: this one omitted `python3` entirely while that one
called `tzdata` a hard dependency. **Two statements of one fact means at least one of them
is false** — if you edit either, edit both.
⚠️ 本短版与 Quick start 下那一份**必须一致**。在 2026-08-30 之前它们不一致：
这一份完全没提 `python3`，那一份把 `tzdata` 写成硬依赖。
**同一个事实写两处，就意味着至少有一处是假的**——改一处就得改两处。

## Provenance / 抽取来源

Extracted from a private in-house fleet-automation codebase at commit `e2f32279`.
Upstream changes after that commit are **not** tracked and **not** synced back.
抽取自内部私有编队自动化代码库的 `e2f32279`；该 commit 之后的上游改动**不追平、不双向同步**。

### Note for maintainers — release tags are moved exactly never / 维护者须知：发布 tag 永不重打

During pre-publication development `v0.1.0` was cut, deleted and re-cut more than once,
each time because further work landed after the tag existed and the tag would otherwise
have named a release that did not contain it. **The exact sequence is deliberately not
restated here** — read it from this repository's history and from the tag object itself.
A count or a target SHA written into prose goes stale the next time anything moves, and
it goes stale **silently**: nothing errors, nobody re-reads it.

🛑 **Therefore the tag is cut LAST.** Cutting a release tag is the final action before
handover, after every rework is done and the SHA will not move again. It is the one step
that must never be taken while anything upstream of it can still change — twice during
this repository's own pre-publication work a tag was cut mid-stream and was left naming
the wrong commit within the hour.

⭐ **That was allowed only because nothing had been published yet.** A tag is a promise
about *what other people downloaded*. This repository had never been public, nobody had
cloned anything, so there was no promise available to break — the tag was simply pointing
at the wrong object.

🛑 **From the moment this repository becomes public, that stops being true.** A published
tag is never moved, re-cut, or deleted: someone may already have fetched it, pinned it, or
built against it, and moving it makes two different trees answer to one name — silently,
because git will not warn either of you. If a released version is wrong, **ship a new
version number**. This is the one action the "we can always fix it" reflex must not reach.

`v0.1.0` 在**尚未公开**的开发期里被打过、删过、又重打过不止一次，每次都是因为打完 tag 之后
又落了新的工作，不动它这个 tag 指的就是一个不含该工作的版本。**确切次序刻意不在正文里复述**
——以本仓历史与 tag 对象为准。写进散文里的次数或目标 SHA，下一次动它就作废，而且是**静默**
作废:不报错，也不会有人回头再读一遍。

🛑 **所以 tag 放到最后打。** 打发布 tag 是交付前的**最后一个动作**，排在所有返工之后、
排在 SHA 不会再变之后。它是唯一一个「只要上游还可能变就绝不能做」的步骤——本仓自己在公开前的
开发期里就有**两次**把 tag 打在了工作流中间，两次都在一小时内变成指着错误的 commit。

⭐ **这件事之所以被允许，只因为当时还没有任何东西被发布出去。** tag 是对「别人下载到的
东西」的承诺；本仓当时从未公开、没有任何人 clone 过，所以还不存在可以被打破的承诺——
它只是指错了对象。

🛑 **一旦本仓转为 public，上面这条就不再成立。** 已发布的 tag 永不移动、永不重打、永不删除：
可能已经有人 fetch 了它、钉了它、照着它构建；移动它会让两棵不同的树对应同一个名字，
而且是**静默的**——git 不会警告你们中的任何一方。发布出去的版本有问题，**就发一个新版本号**。
「反正还能改」这个反射，唯独不许伸到这件事上。

### ✅ Note for maintainers — real names are in the git objects, and that is accepted
### ✅ 维护者须知：git 对象里有真实人名，且此事已被接受

> **Superseded 2026-08-31.** This heading and section said *"this repository is never made
> public"* and *"any public release ships from a NEW repository"*. The owner lifted that
> on 2026-08-31 after seeing what the names are. **Struck in place, not silently rewritten**
> — an expired prohibition produces no error, it just keeps a release from happening while
> everyone assumes it is still pending.
> **2026-08-31 作废。** 本节标题与正文原本写的是「本仓永不转 public」「任何公开发布都从
> 一个全新仓推出」。仓主在看过那些名字是什么之后，于 2026-08-31 解除了它。
> **就地划掉、不是被悄悄改写**——一条过期的禁令不会报错，它只会让发布一直不发生，
> 而所有人都以为它还在排队。

**The finding, unchanged.** This repository's git objects contain real given names carried
over from the baseline; the working tree is clean (0 occurrences) but the object layer is
not (114 lines in historical versions of one test file), and **`force-push` does not delete
remote objects** — measured on this repository, by fetching superseded commits by SHA from
a fresh clone and getting the old contents back.

**The disposition, as of 2026-08-31.** This repository may be made public, and a release
ships from **this** repository — no new repository, no rewrite. What the 114 lines contain,
why that was judged acceptable, and the range-by-range counts are in
[docs/REDACTION.md](docs/REDACTION.md#real-names-in-the-git-objects--git-对象里的真实人名).

**发现本身没有变。** 本仓 git 对象里含从基线照抄过来的真实名字；工作树干净（0 处），
对象层不干净（某个测试文件的历史版本里 114 行），而 **`force-push` 不删除远端对象**
——本仓实测过：从全新 clone 按 SHA 去 fetch 已被取代的 commit，旧内容照样取得出来。
**2026-08-31 起的处置**：本仓可以转 public，发布就从**本仓**推出，不另起新仓、不重写历史。
那 114 行是什么、为何判为可接受、分范围计数，见
[docs/REDACTION.md](docs/REDACTION.md#real-names-in-the-git-objects--git-对象里的真实人名)。

### Note for maintainers — how to copy source files / 维护者须知：源文件怎么复制

**Always extract with `git show e2f32279:<path>`. Never `cp` from a working tree.**
**一律用 `git show e2f32279:<path>` 取文件，绝不从工作树 `cp`。**

The upstream repo stays under active development, so its working tree drifts away from
the baseline continuously — during the survey milestone alone the baseline moved three
separate times within half an hour. A file copied from a working tree therefore does
**not** match the `e2f32279` this section claims, and nothing will report the mismatch:
the copy succeeds, the tests still pass, and the only symptom is that the provenance
sentence above has quietly become false.

上游仓仍在持续开发，工作树与基线时刻在漂移——仅盘点里程碑期间，半小时内基线就真实变了
三次。从工作树 `cp` 出来的文件因而与本节声称的 `e2f32279` 对不上，而且**这种错不会报错**：
复制成功、测试照绿，唯一的表现是上面那句 provenance 在很久以后变成了假话。

This rule has no expiry: it applies to every later extraction, not just the first batch.
本规则长期有效，适用于此后每一次抽取，不限于第一批。

### Note for maintainers — use plain `git` in this repo / 维护者须知：本仓用原生 `git`

This repo wires its own deploy key through the in-repo `core.sshCommand`. Do **not** drive
it with a wrapper that exports `GIT_SSH_COMMAND` — environment beats config in git's
precedence order, so the in-repo wiring is silently replaced by whatever key that wrapper
prefers, and that key has no access here. The failure is a permission error on push with
no hint that a wrapper substituted the key. Plain `git` works.

本仓用仓内 `core.sshCommand` 接自己的 deploy key。**不要**用任何会 `export GIT_SSH_COMMAND`
的 git 包装器操作本仓：git 的优先级是环境变量高于配置，仓内接线会被静默换成那个包装器
偏好的 key，而那把 key 在这里没有权限。表现是 push 时报权限错，且不会有任何线索提示
「是包装器把 key 换掉了」。用原生 `git` 即可。

## License / 许可证

MIT — see [LICENSE](LICENSE).
