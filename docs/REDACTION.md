# Redaction / 脱敏说明

The code in this repository was extracted from a private codebase that ran against
real Claude accounts. This file records what was removed, how, and how you can check
that it stayed removed.
本仓的代码抽取自一个跑在真实 Claude 账号上的私有代码库。本文件记录删掉了什么、怎么删的、
以及你怎么核实它一直没回来。

> ✅ **SUPERSEDED 2026-08-31 — this repository MAY be made public, and a public release
> ships from THIS repository.** A 🔴🔴 banner stood here saying it must never be. That was
> the owner's 2026-08-26 line; on 2026-08-31 the owner was shown the measured contents and
> relaxed it, in his own words: *「这些信息无所谓，接着用这个仓推进」*. **The old
> instruction is struck out in place rather than quietly replaced**, because an expired
> imperative does not fail loudly — it just keeps something from happening while everyone
> assumes it is still queued.
> ⚠️ **The finding underneath did not change and must not be read as retracted**: real
> given names are still in this repository's **git objects** — 114 lines, range B, in
> historical versions of `test/quota-sentinel.test.sh` — and they are still **not
> removable by editing the working tree**. What was relaxed is the **disposition**, not the
> **measurement**. Both are stated separately in
> [Real names in the git objects](#real-names-in-the-git-objects--git-对象里的真实人名).
> ✅ **2026-08-31 作废——本仓可以转 public，且公开发布就从本仓推出。** 这里原本立着一条
> 🔴🔴「本仓永远不得转为 public」。那是仓主 2026-08-26 定的线；2026-08-31 仓主看过实测内容
> 之后放宽了它，原话：**「这些信息无所谓，接着用这个仓推进」**。
> **旧指令是就地划掉、不是被悄悄换掉**——一条过期的祈使句不会报错，它只会让该发生的事
> 一直不发生，而等的人以为自己还在正常排队。
> ⚠️ **它底下那条发现没有变，也不得被读成撤回**：真实名字仍在本仓的 **git 对象**里
> （范围 B，114 行，位于 `test/quota-sentinel.test.sh` 的历史版本），**且靠改工作树仍然
> 消不掉**。放宽的是**处置决定**，不是**测量结果**。

## The rule / 规则

No real account address, no credential, no internal path, and no internal hostname may
appear anywhere in this repository — **including in comments, in test fixtures, and in
git history**.
任何真实账号地址、凭据、内网路径、内部主机名都不得出现在本仓的任何地方——**包括注释、
测试夹具与 git 历史**。

## Why the comments could not simply be deleted / 为什么不能靠删注释脱敏

Almost every real account name in the source appeared inside an **incident note** — a
comment recording something that actually broke, and why a given guard exists because
of it. Those notes are the most valuable thing in this codebase; a guard whose reason
has been deleted is a guard the next person will remove as pointless.
源码里几乎每一处真实账号名都出现在**事故注释**里——记录真实坏过一次、以及某条守卫因此
存在的注释。那些注释是这份代码里最值钱的东西；一条理由被删掉的守卫，下一个人会当作
无用把它删掉。

So the names were **rewritten, not stripped**. Each real account became a stable
placeholder, and the same account maps to the same placeholder everywhere — otherwise
a sequence like "account X went 97% → 0% → 97%" stops being readable as one story.
所以人名是被**改写**的，不是被剥掉的。每个真实账号对应一个稳定占位符，且同一账号在全仓
映射一致——否则「某账号 97% → 0% → 97%」这种事故序列会读不成一条线。

| placeholder / 占位符 | what it stands for / 代表什么 |
|---|---|
| `accountA` … `accountE` | distinct real accounts in the source environment / 源环境里几个不同的真实账号 |
| `example.com` addresses | RFC 2606 reserved documentation domain; never a real host / RFC 2606 保留的文档域名，永远不是真实主机 |

The real-name → placeholder table is **deliberately not in this repository**. Publishing
the table would publish exactly the strings the redaction removed. It lives in
`tools/alias-map.local.txt`, which is gitignored, and it can be rebuilt from the
baseline by anyone with access to the source repository.
真名 → 占位符的对照表**刻意不在本仓**：把表发出来等于把脱敏删掉的那些串再发一遍。
它在已被 gitignore 的 `tools/alias-map.local.txt` 里，任何能访问源仓的人都能从基线重建。

## What else was parameterised / 还参数化了什么

These were not secrets, but they were **true on exactly one machine** and false
everywhere else — which is its own kind of defect in a tool other people run.
这些不是凭据，但它们**只在一台机器上为真**，在别处一律为假——对一个别人也要跑的工具来说，
那本身就是一类缺陷。

| was / 原来 | now / 现在 |
|---|---|
| a machine-local HTTP proxy baked into the launch command | `QUOTA_MONITOR_PROXY`, empty by default |
| a machine-local proxy in the probe | `PROBE_PROXY`, empty by default |
| `/root/.claude.json` (assumes running as root) | follows `$HOME` |
| a big-disk path as the temp-file fallback | `${TMPDIR:-/tmp}` |
| a hard-coded UTC+8 offset in every rendered timestamp | resolved once from the host; see `lib/config.sh` |
| the account roster as a **default value** | empty by default; supply it in the environment |
| a specific Docker container and its mount path | not extracted in this milestone |
| the private environment's root, marker file, shim names and env prefix, hard-coded in the cleanroom checks | six declared inputs, each fail-closed when unset |

### Dates: what is kept, what is removed / 日期：留什么、删什么

⚠️ **A rule, because residue with a rule is a decision and residue without one is an
omission — and they read identically.** De-site-specification here removed **coordinates**,
not evidence.

**Kept** — a date that serves as an incident's *identity*, and every measured quantity
(counts, percentages, durations, rates). Those are what make a guard's justification
checkable, and deleting them would leave behind an unfalsifiable anecdote.
**Removed** — anything that lets a specific day be tied to a specific machine or person:
precise clock times (`16:11:51`), timestamp ranges naming a single incident window, and
internal role names (who decided, who reported).

**Residue, counted rather than implied**: `YYYY-MM-DD` appears **105** times across the
shipped files and docs, of which **89** are `2026-08-*`. That is deliberate under the
rule above — they are incident identities in comments and in this file's own change log.
⚠️ **This is not a claim that the class was cleared.** An earlier delivery report said
"11 date/time coordinates removed", which is a removal count and was accurate as such; it
is restated here with the remaining total so that neither number can be read as the other.

### 日期：留什么、删什么

⚠️ **要有规则，因为有规则的残留是决定，没规则的残留是漏做——而这两者读起来一模一样。**
这里的去现场化删的是**坐标**，不是证据。

**留**：作为事故**身份**的日期，以及全部测量值（次数、百分比、时长、速率）。
它们是让一条守卫的理由可核对的东西，删掉只会剩下一个无法否证的传闻。
**删**：任何能把某一天与某台机器或某个人对上的东西——精确时刻（如 `16:11:51`）、
点名某次事故窗口的时间区间、以及内部角色名（谁拍的板、谁报的）。

**残留量，是数出来的不是暗示的**：交付文件与文档里 `YYYY-MM-DD` 共 **105** 处，
其中 `2026-08-*` **89** 处。按上面那条规则，这是有意保留的——它们是注释里的事故身份，
以及本文件自己的变更记录。
⚠️ **这不是在声称这一类已经清空。** 早先的交付报告写「删掉 11 处日期与精确时刻」，
那是一个**删除计数**、作为计数它是准确的；这里连同**剩余总量**一起重述，
好让两个数不会被读成对方。

## How to check it stayed removed / 怎么核实它没回来

```sh
tools/dod4-scan.sh            # five ranges: worktree, every blob, messages, identity, paths
tools/dod4-scan.posctrl.sh    # prove each of those five ranges actually goes red
```

⚠️ **A working-tree `grep` is not this check.** It covers one range out of five and is
structurally blind to the other four. The classic pre-publication leak — committed,
noticed, deleted in the next commit — is gone from the working tree and still sitting
in the pack, where no amount of grepping the checkout will ever find it.
⚠️ **grep 工作树不等于这项检查。**它只覆盖五个范围里的一个，对另外四个结构性全盲。
开源前最经典的那种泄漏（提交了、发现了、下个 commit 删掉）已经从工作树消失，却仍躺在
对象库里，再怎么 grep 检出目录都永远看不见它。

### Both scopes are mandatory / 两个口径都必须跑

🔴 **Before publishing, run the scan twice — once here, once from a clone with no
`tools/*.local.txt` — and report the two results separately.** Neither is the stricter run;
they use **different pattern sets** and each is blind to what the other is for.

| scope / 口径 | patterns | the only question it can answer / 它是唯一能回答的那一问 |
|---|---|---|
| **here**, with the site table / **本机**，带站点模式表 | `site` | *Are the site-private tokens — the real names, internal hostnames, the private repo name — still where we think they are?* Measured here: **114** range-B lines. A fresh clone reports **0** of them, because it has no table to match them with. / 站点私有 token（真实人名、内部主机名、私有仓名）还在不在我们以为的位置。本机实测范围 B **114** 行；新 clone 报 **0**，因为它没有那张表。 |
| **a fresh clone**, no `*.local.txt` / **新 clone**，无 `*.local.txt` | `example-only` | *Has a site allowance blinded us to something a third party would see?* This is the only scope in which `tools/dod4-allow.local.txt` is absent, and it is how the trailer-address miss below was caught — **range A went 0 → 2** on the clone while this machine said 0. / 站点豁免有没有把我们自己扫瞎、而第三方看得见。这是唯一没有 allow 文件的口径，下面那次 trailer 地址实撞正是这样查出来的：本机报 0，clone 上范围 A 从 0 变 2。 |

⭐ **Neither scope covers the other, and the two counts must not be merged into one
number.** "The scan was clean" is not a sentence this check can produce; "clean under
`patterns=site`" and "clean under `patterns=example-only`" are two findings, and publishing
requires looking at both.
⚠️ **A fresh clone is not "the stricter scan."** It is tempting to think dropping the local
files can only *add* findings — that is true of the **allow** file and false of the
**pattern** files, and the pattern files are where the real names live. A rule that said
"run it from a fresh clone instead" would have quietly stopped anyone from ever looking at
the 114 lines again.

🔴 **发布前把扫描跑两遍——本机一遍、无 `tools/*.local.txt` 的新 clone 一遍——并把两个结果
分开报。** 两者都不是「更严格的那一次」：它们用的是**不同的模式集**，各自对对方要查的东西
结构性全盲。
⭐ **两个口径互不覆盖，两个数不许合并成一个。** 「扫描是干净的」这句话本检查产不出来；
「`patterns=site` 下干净」与「`patterns=example-only` 下干净」是两条结论，发布要求两条都看。
⚠️ **新 clone 不是「更严格的扫描」。**「少了本地文件只会多报、不会少报」这个直觉对 **allow**
文件成立、对 **pattern** 文件不成立——而真实人名恰恰在 pattern 文件那一侧。一条写成
「改从新 clone 跑」的规则，会悄悄让此后再没有人看过那 114 行。

### Which local file does a pattern go in? / 一个模式该写进哪个本地文件？

🔴 **This is where this project's leak scan has actually failed, so read it before
adding anything.** The two site-local files feed **different ranges**:

| file / 文件 | feeds / 喂给 | sees / 看得见 |
|---|---|---|
| `dod4-patterns.local.txt` | ranges **A / B / C** | the text **inside** files, blobs and commit messages |
| `dod4-paths.local.txt` | range **E** only | **tree entry names** only |

⇒ **A token written only into the paths file is structurally invisible to the content
ranges, and the scan still reports CLEAN.** That is not a hypothetical: an internal
tool's command name lived only in the paths file, walked out through `README.md` and a
commit message, and the five-range scan stayed green with all six positive controls
firing.
⇒ **只写进路径层的 token，内容层结构性看不见它，而扫描照样报 CLEAN。**这不是假设：
一个内部工具的命令名只在路径层，于是它从 `README.md` 与一条 commit message 走了出去，
五范围扫描全绿、六格正控全部 fired。

⭐ **A positive control that fires only proves "what is in the table can be caught". It
does not prove "everything that should be in the table is in it."** Sampling verifies
the correctness of the entries; it cannot verify the coverage of the table itself.
⇒ After adding patterns, check **from the token side** — enumerate every class of
private token you care about and ask which ranges cover it — rather than sampling from
the table.
⭐ **正控 fired 只证明「表里有的能被抓到」，不证明「该在表里的都在表里」。**
⇒ 加完模式要**从 token 侧反查范围覆盖**，不是从模式表抽样。

**Internal command names, internal tool names and marker file names must go into
`dod4-patterns.local.txt` (the content layer)** — writing them only into the paths file
checks tree entry names and nothing else.
**内部命令名／内部工具名／标记文件名必须写进 `dod4-patterns.local.txt`（内容层）**；
只写进路径层等于只查了树条目名。

⚠️ But do **not** put everything internal-looking in there either. The criterion is
**"is this worth anything to a public reader?"** A source path inside the private repo
is load-bearing provenance — `git show <SHA>:<path>` is how anyone checks this
extraction — and adding it to the content layer makes the scan **permanently red on
approved content**. A check that is always red teaches people to click past red, which
is worse than not having it.
⚠️ 但也**不要**把所有看起来内部的东西都塞进去。判据是**「对公开读者有没有价值」**：
私有仓内的源文件路径是承重的 provenance（`git show <SHA>:<path>` 正是核对本次抽取的
方式），把它加进内容层会让扫描在**已获批准的内容**上恒红——而恒红的检查会训练出
「看到红也照过」，比没有更糟。

### A token's classification is not permanent / 分类会随抽取范围变化

🔴 The same string can be an internal path in one milestone and a functional identifier
in the next, and the pattern table has to be revisited when that happens.

Worked example, from m3. `claude-backup-before-` was listed under internal paths when
the redaction table was built. That was correct at the time and the note beside it said
so explicitly: *the repo has zero legitimate uses of this prefix, so there is no
false-positive cost*. Then m3 extracted the account-switch tool, and that prefix became
the name of the directory this published tool creates and reads — it has to stay
readable, or the tool cannot see backups written by earlier versions. Overnight a
pattern with no false-positive cost acquired one, and the scan went `DIRTY` on entirely
correct, entirely publishable code.

⭐ The failure mode if you leave it: the scan is now **permanently red**, and a check
that is always red teaches people to click past red — including the day it goes red for
a real reason. The fix is not an allowlist entry (that hides it), it is re-answering the
classification question the table is built on: *does this string carry value for a
public reader?* A directory the tool creates does. An internal mount root does not.

⚠️ So the rule is: **when a milestone widens what gets extracted, re-run the scan and
treat every new hit as a classification question first, not as a leak first.** The hit
above was a true report of a stale classification, not a false positive — the scanner
was right, the table was out of date. What went stale was a judgement, and judgements do
not announce that they have expired.

🔴 同一个串在这个里程碑是内网路径，在下一个里程碑可能变成功能标识；抽取范围一变，
模式表就要重判一次。m3 的实例：`claude-backup-before-` 建表时按内网路径收，当时的旁注
写得很清楚——「全仓零合法用法，所以广义形式没有误报成本」。m3 把 account-switch 抽进来
之后，它成了**本工具自己创建并读取**的备份目录前缀（且必须保留才能读旧版本写的备份），
于是一个原本零误报成本的模式一夜之间有了成本，扫描在完全正确、完全可发布的代码上转红。
⭐ 不处理的后果：扫描从此**恒红**，而恒红的检查训练出「看到红也照过」——包括它真的
因为真问题转红的那天。解法不是加白名单（那是藏起来），是重新回答建表所依据的那个问题：
**这个串对公开读者有没有价值？** 工具自己创建的目录有；内网挂载根没有。
⚠️ ⇒ 里程碑扩大抽取范围时，重跑扫描，**新命中一律先当分类问题、不要先当泄漏**。上面
那条是「分类过期」的真实报告，不是误报——扫描器是对的，过期的是表。**过期的是一个判断，
而判断不会自己宣布它过期了。**

### What the scanner structurally cannot cover / 扫描器结构性覆盖不到什么

Some internal names are **ordinary English words**. Say the private system has a
dashboard command called `state` and a live-view command called `watch`. Neither can go
into the content layer as a bare pattern: this repository contains dozens of legitimate
uses of both words — there is a `lib/state.sh` in it — so the pattern would fire
constantly, and **a check that cries wolf is a check people stop reading**.

> ⚠️ `state` and `watch` are **invented stand-ins**, not the real names. The real list
> belongs in the gitignored `tools/dod4-patterns.local.txt`, never in a published file —
> a document that argues for keeping internal names out of a public repository has no
> business spelling them out in its own body. What matters for the reader is the
> **shape** of the problem — an internal name that is also a word you use all day — not
> which two words they happen to be.

⇒ **That class is covered by review, not by the scanner**, and saying so is the point:
a limitation you have written down can be checked by a human; one you have not looks
exactly like coverage.

Two such residues were found in this repository by exactly that human pass — an
incident note referring to the private system's bookkeeping, and a comment that
disclosed which name was on its internal command list by using it as an example. Both
are fixed. Neither would ever have been caught by a regex.
⇒ When adding a token class, ask which of the two buckets it is in, and **write the
answer down** rather than leaving the scanner's silence to speak for it.

有些内部名字**本身就是普通英文词**。假设那套私有系统有一个叫 `state` 的看板命令、
一个叫 `watch` 的实时查看命令：两个都不能作为裸模式进内容层——本仓有几十处对这两个词的
正当使用（仓里就有 `lib/state.sh`），模式会持续误报，而
**一条总在喊狼来了的检查，人就不看了**。

> ⚠️ `state` 与 `watch` 是**虚构的替身**，不是真名字。真实名单属于已 gitignore 的
> `tools/dod4-patterns.local.txt`，绝不进任何会被公开的文件——一份主张「别把内部名字带进
> 公开仓」的文档，没有理由在自己正文里把它们逐字写出来。对读者有用的是这个问题的
> **形状**（一个内部名字同时是你天天在用的普通词），不是它碰巧是哪两个词。

⇒ **这一类靠人工复核覆盖，不靠扫描器**——把这句话写出来正是关键：写下来的限制人可以去查，
没写下来的限制看起来和「已覆盖」一模一样。
本仓正是靠这一遍人工查出两处这类残留（一条引用了那套系统看板概念的事故注释，
以及一条把某个名字举例出来、等于披露它在内部命令名单上的注释），两处均已修。
**正则永远抓不到它们。**

### Real names in the git objects / git 对象里的真实人名

> ⚠️ **This section was titled "Never public / 本仓永不转 public" until 2026-08-31.** The
> title is part of what people acted on, so it was changed rather than left standing above
> a decision that had reversed. The measurements in it are unchanged.
> ⚠️ **本节标题在 2026-08-31 之前是「Never public / 本仓永不转 public」。** 标题本身就是
> 别人据以行动的东西，所以它跟着改了，而不是让它继续立在一个已经反转的决定上方。
> 节内的测量值一字未动。

**Real names are in this repository's git objects.** / **本仓的 git 对象里有真实人名。**

⚠️ **Status: present, accepted, not processed — and since 2026-08-31 it no longer
constrains what this repository may be used for.** Until then this paragraph read *"it
changes what this repository may be used for"* and called itself **a standing constraint on
whoever reads this next**. The owner lifted that constraint on 2026-08-31 after being shown
what the 114 lines actually contain (see the banner at the top of this file).
⭐ **The names are still there; they are simply no longer a reason to withhold the
repository.** ⇒ Read everything below as a **finding**, not as a **restriction**.
⚠️ **状态：存在、已接受、不再处置——且自 2026-08-31 起，它不再限制本仓可以被用来做什么。**
在那之前本段写的是「**它改变了本仓可以被用来做什么**」，并自称「对下一个读到它的人的
**长期约束**」。2026-08-31 仓主在看过那 114 行的实际内容后解除了该约束（见本文件顶部横幅）。
⭐ **名字仍然在那里，只是它不再构成扣住本仓不发布的理由。**
⇒ 下面的内容请当作**发现**读，不要当作**限制**读。

**What those 114 lines actually are, since that is what the decision turned on** — four
given names, appearing as short fixture identifiers and in incident notes recording quota
readings. **No deliverable address is among them**: the only complete addresses in this
repository are `*@example.com` (RFC 2606 documentation domain) and the vendor's public
`noreply@` co-author address.
**Counted 2026-08-31 from `tools/dod4-scan.sh`'s own output**: exactly **4** patterns fire,
with **42 / 36 / 24 / 18** occurrences — **120 occurrences across 114 lines**.
⚠️ Those two totals are stated together on purpose: 120 ≠ 114 because some lines carry two
names, and a reader who adds the four numbers and gets 120 should not have to wonder which
of the two figures is wrong. **Neither is; they count different things.**
**2026-08-31 用 `tools/dod4-scan.sh` 自己的输出数出来的**：恰好 **4** 条模式命中，
各 **42 / 36 / 24 / 18** 次——**114 行里共 120 处**。
⚠️ 两个合计有意写在一起：120 ≠ 114 是因为有些行同时含两个名字；把四个数加起来得到 120 的
读者，不该还要去猜这两个数哪个错了。**两个都没错，它们数的是不同的东西。**
⚠️ The four names are **deliberately not written out here**, for the same reason the
trailer address is not — the site pattern table matches them, so spelling them out in this
file would make the scanner report **this file**, and the person documenting the decision
would become the event source. (That is not hypothetical; it is the episode recorded at the
end of the range-C section below.)
**那 114 行到底是什么，因为决定正是基于这个**：四个名字（分别出现 42 / 36 / 24 / 18 次），
以短夹具标识符与记录额度读数的事故注释两种形态出现。**其中没有任何可投递的地址**——
本仓里完整的地址只有 `*@example.com`（RFC 2606 文档域名）与厂商公开的 `noreply@` 协作者地址。
⚠️ 那四个名字**刻意不在此逐字写出**，理由与 trailer 地址那条相同：站点模式表会命中它们，
写出来会让扫描器报**本文件**，记录这个决定的人自己变成事件源（这不是假设，见下面范围 C
小节末尾那次实撞）。

Real people's names — the short forms of account-roster aliases — are in this
repository's git objects. They were carried over verbatim from the baseline when the test
suite was migrated, and they are in **historical versions of
`test/quota-sentinel.test.sh`**.

**The two ranges are stated separately, and they must not be collapsed into one sentence:**

| range / 范围 | count / 数 | status / 状态 |
|---|---|---|
| **A** — working tree / 工作树 | **0** | ✅ replaced with `accountA`/`accountB`/`accountC` placeholders |
| **B** — all git objects, including unreachable blobs / 全部 git 对象（含不可达 blob） | **114 lines** | 🔴 **unchanged, and not removable by editing the working tree** |
| **C** — commit messages / commit message | **not names** — see the baseline below / **不是人名**，基线见下 | ⚠️ a different substance; listed here only because this is where a reader looks after a DIRTY verdict / 另一种物质，列在这里只是因为读者看到 DIRTY 之后会先来这张表 |

### Expected baseline for range C / 范围 C 的预期基线

⚠️ **A scan that is expected to be red, with nobody able to say how red, stops being
evidence.** This repo's own scanner opens by arguing that a check which cannot fail proves
nothing; a check that **always** fails proves just as little. So range C gets a stated,
checkable baseline rather than a shrug.
⚠️ **一个「预期就是红」、又没人说得出该红几条的检查，就不再是证据了。** 本仓的扫描器开篇
论证的是「不可能失败的检查什么也不证明」；一个**永远失败**的检查同样什么也不证明。
⇒ 范围 C 给出可核基线，而不是一句「知道了，是预期的」。

- **What is in there** — every commit created under the Fleet commit convention carries a
  `Co-Authored-By:` trailer whose value is a no-reply address at the assistant vendor's
  domain, and the published generic-email pattern in `tools/dod4-patterns.example.txt`
  matches it. It is not an account-roster address, not a credential, not an internal path.
  ⚠️ The address itself is **deliberately not written out in this tracked file** — see the
  episode note at the end of this section. The exact literal lives in
  `tools/dod4-allow.local.txt`.
  **里面是什么**：按 Fleet 的 commit 惯例，每个 commit 都带一行 `Co-Authored-By:` trailer，
  它的值是助手厂商域名下的一个 no-reply 地址，被已公开的通用邮箱模式命中。
  它不是账号名册里的地址、不是凭据、不是内网路径。
  ⚠️ 那个地址**刻意不写进本 tracked 文件**——理由见本节末的实撞记录；完整字面串在
  `tools/dod4-allow.local.txt` 里。
- **The baseline is a formula, not a number** — it is **one hit per commit carrying that
  trailer**, so it grows by one with every new commit. Verify with:
  ```sh
  git log --format=%B | grep -cE '^Co-Authored-By: .+<[^>]+@[^>]+>$'
  ```
  and compare against the `C-message` lines the scan prints. ⭐ A frozen number would be
  wrong by the next commit; that is exactly how a baseline turns into noise.
  ⚠️ **The anchoring is load-bearing.** A plain `grep -c 'Co-Authored-By'` also counts every
  commit message that *mentions* the trailer in prose — measured here: 5 against 4 real
  trailers, on a repo whose own commit messages discuss this very baseline. A recipe that
  counts mentions instead of trailers produces a number that looks exact and is not.
  **基线是个式子，不是一个数**：**每个带该 trailer 的 commit 一条**，因此每提交一次就 +1。
  用上面那条命令核，与扫描打印的 `C-message` 行数对照。⭐ 钉一个固定数字下一次提交就作废
  ——基线正是这样变成噪音的。
  ⚠️ **锚定是承重的**：裸 `grep -c 'Co-Authored-By'` 会把**散文里提到**该 trailer 的 commit
  message 一起数进去——本仓实测 5 对 4（因为本仓的 commit message 自己在讨论这条基线）。
  一条数「提及」而不是数「trailer」的配方，会给出一个看起来精确的错数。
- **Locally it is excused; on a fresh clone it is not** — `tools/dod4-allow.local.txt`
  (gitignored) excuses **the exact literal address**, so the scan run here comes back to
  `A/C/D/E = 0`. A fresh clone has no such file and will report those C lines. ⚠️ That
  direction is the safe one: a site allowance can only blind **us**, never a third party.
  **本地被豁免，新 clone 上不会**：`tools/dod4-allow.local.txt`（已 gitignore）豁免的是
  **那个完整字面地址**，所以在这里扫回到 `A/C/D/E = 0`；一份新 clone 没有这个文件，会照常
  报出那几条 C。⚠️ 这个方向是安全的那个：站点豁免只可能让**我们自己**少看见，不会让别人少看见。
- **Why it is not in the published allow file** — `tools/dod4-allow.example.txt` states its
  own admission rule: a vendor's domain, or a specific address someone decided is fine,
  **must not** go in it, and site-specific allowances belong in the `.local` file. Making
  an exception to a written long-term rule so that today's scan turns green is how that
  rule stops working for the next person.
  **为什么没进已公开的 allow 文件**：`tools/dod4-allow.example.txt` 自己写着准入规则——
  供应商域名、以及「某个你判断没问题的具体地址」**都不许**进去，站点豁免应写进 `.local`。
  为了让今天这次扫描变绿而给一条长期规则破例，就是那条规则以后拦不住别人的开始。
- 🩸 **Control ① below was withdrawn on 2026-08-31 — it could not have answered the
  question it was cited for.** `tools/dod4-scan.posctrl.sh` clones this repo into a
  throwaway directory and **plants its own** `dod4-{patterns,paths,identity}.local.txt`
  markers there; `dod4-allow.local.txt` is gitignored and therefore **cannot travel into
  that clone at all**. So `RANGE C-message fired OK` is produced in an environment where
  the allowance does not exist, and it would say exactly the same thing if the allowance
  *had* switched the range off. **Measured, not argued**: with the allowance deliberately
  widened to the whole domain, `tools/dod4-scan.sh` reported **`CLEAN hits=0`** — fully
  blinded — while `tools/dod4-scan.posctrl.sh` still reported **`RANGE C-message fired OK`**
  and `POSCTRL_RESULT=PASS`. ⭐ The control proves the C range is **traversed**; it cannot
  prove the C verdict is **unblinded**. ⇒ There is currently **no standing control** on
  this allowance, and the shipped positive control structurally cannot become one.
  🩸 **下面的控 ① 于 2026-08-31 撤回——它回答不了当初引用它去回答的那个问题。**
  `tools/dod4-scan.posctrl.sh` 把本仓 clone 进一次性目录，并在那里**自己种**
  `dod4-{patterns,paths,identity}.local.txt` 标记；而 `dod4-allow.local.txt` 已 gitignore，
  **根本进不了那份 clone**。于是 `RANGE C-message fired OK` 是在「豁免不存在」的环境里
  产出的——就算豁免真的把这个范围关掉了，它也会说同一句话。**这是实测不是论证**：把豁免
  故意放宽成整域之后，`tools/dod4-scan.sh` 报 **`CLEAN hits=0`**（完全致盲），而
  `tools/dod4-scan.posctrl.sh` 仍报 **`RANGE C-message fired OK`**、`POSCTRL_RESULT=PASS`。
  ⭐ 它证明的是 C 范围**被走到了**，证明不了 C 范围的**结论没被蒙住**。
  ⇒ 这条豁免目前**没有常设控**，而出厂的那条正控结构上也当不了它的控。
- **Controls, both run 2026-08-31** — ① ~~after adding the allowance,
  `tools/dod4-scan.posctrl.sh` still reports `RANGE C-message fired OK` ⇒ the allowance did
  not switch a range off~~ **（撤回，见上一条 / withdrawn, see above）**; ② in a throwaway repo, a **different local part at the same
  domain** is still reported while the allowed literal is not ⇒ the allowance is
  literal-scoped, not domain-scoped. The recipe for ② is in the allow file itself.
  ⚠️ The second address is described rather than written out, and that is not squeamishness:
  writing an example address into this file makes the scanner report **this file**, and the
  person investigating becomes the event source. (Measured while writing this paragraph —
  the first draft spelled it out and turned range A red, from 0 to 1.)
  **两条控，2026-08-31 都跑过**：① ~~加完豁免后 `tools/dod4-scan.posctrl.sh` 的
  `RANGE C-message` 仍 `fired OK` ⇒ 没有用 allowlist 把一整个范围关掉~~
  **（已撤回：那条控在「豁免不存在」的 clone 里跑，答不了这一问；实测见上）**；② 在一次性仓里，
  同域另一个地址仍被报出、被豁免的那个字面串不被报出 ⇒ 豁免的射程是**字面串**不是域。
  ② 的复跑配方写在 allow 文件里。
  ⚠️ 第二个地址在这里只**描述**、不写出来，这不是讲究：把一个示例地址写进本文件，扫描器就会
  报**本文件**，排查者自己变成了事件源。（写这段时实测：初稿写全了，范围 A 当场从 0 变 1。）

🩸 **一次实撞，记下来而不是抹掉（2026-08-31，写本节时）**：本节初稿把那个 trailer 地址
**逐字**写进了这份 tracked 文件。**在本机扫不出来**——站点豁免正好把它挡掉了；
只有在一份**没有站点文件的新 clone** 上重扫，才看见范围 **A 从 0 变成 2**。
⚠️ ⇒ 上一条说的「站点豁免只可能让我们自己少看见，不会让别人少看见」，**方向是对的，但
「只让我们自己少看见」正是最糟的那一半**：**我们**才是发布前做审计的人。
⇒ 因此**发布前的 DoD-4 必须包含一次从不含 `tools/*.local.txt` 的新 clone 上跑的扫描**。
⚠️ **2026-08-31 订正——是「必须包含」，不是「必须只从新 clone 跑」。** 本行原文是
「发布前的那次 DoD-4 必须从一份不含站点文件的新 clone 上跑，本机那次只用于日常」，
那句是错的，而且错的方向比它想防的那次漏还贵：**新 clone 不是更严格的扫描，它是另一套模式**
——它没有站点模式表，那 114 行真实人名在它眼里根本不存在。
⇒ **两个口径都必须跑，见「两个口径都必须跑」一节。**
字面串已从本文件删除；⚠️ 删除这个动作本身在**对象层**留下了 2 行
（它们在 `6fb589f` 的 blob 里，非凭据、非名册地址，不追改）——这不是漏查，是删除动作生成的，
与本节开头那条「删的是哪一层」同一形态。

🩸 **A measured miss, recorded rather than tidied away (2026-08-31)**: the first draft of
this section spelled that trailer address out in this tracked file. **It did not show up
locally** — the site allowance covered it — and only a rescan from a **fresh clone with no
site files** showed range **A going from 0 to 2**.
⚠️ So "a site allowance can only blind us, never a third party" is true in direction and
**wrong in comfort**: *we* are the ones who audit before publishing.
⇒ The pre-publication DoD-4 run **must include** a clone without `tools/*.local.txt`.
⚠️ **Corrected 2026-08-31 — it must include, not consist of.** This line first read *"the
pre-publication run must be done from a clone without site files"*, which is wrong in a way
that would have cost more than the miss it was written for: the fresh clone is **not the
stricter scan, it is a different pattern set**. Having no site pattern table, it cannot see
the 114 real-name lines at all. ⇒ **Both scopes are mandatory; see
[Both scopes are mandatory](#both-scopes-are-mandatory--两个口径都必须跑).**
The literal has been removed here; ⚠️ that removal itself leaves 2 lines at the object
layer (in `6fb589f`'s blob — not a credential, not a roster address, not chased), which is
the same shape as this document's opening point about which layer a deletion removes.


⭐ **"What gets written from now on is clean" and "what already happened has been erased"
are two different statements.** Only the first is true here.

**Do not assume a history rewrite would fix this.** It would not, and that is measured, not
argued: **`force-push` does not delete remote objects.** Tested on this repository on
2026-08-27 — from a brand-new empty clone with only the remote added, fetching four
already-superseded commits **by SHA** succeeded for all four, and the old file contents
came back out. So after a rewrite, "the names are gone" is true of the *reachable* history
and false at the *object* layer. ⚠️ Rewriting **again** does not help either: the old
commits are already unreachable, and being unreachable is precisely not the problem —
being *still served* is.

**The disposition, as of 2026-08-31:**

1. **This repository may be made public.**
2. **A public release ships from THIS repository** — no new repository, no rewrite.

> ⚠️ **What this superseded, kept visible on purpose.** Until 2026-08-31 the disposition
> read: *"① This repository is an internal working repository and is never made public.
> ② Any public release ships from a NEW repository, with a history that is clean from its
> very first commit."* The reasoning for it was that publishing needed the owner to act
> once anyway, so spending that action on **creating** a new repository rather than
> **destroying** this one kept the irreversible-operation count at **zero**.
> ⭐ **That reasoning was sound and is not what changed.** It answered *"how do we publish
> without shipping the names?"*. On 2026-08-31 the owner answered a prior question instead
> — *"do the names need withholding at all?"* — with **no**, having seen what they are. A
> premise was removed, so the conclusion built on it no longer applies. **The paragraph is
> struck through rather than deleted**, so that a reader who remembers the old rule can see
> it was reversed deliberately and by whom, instead of wondering whether it was lost.
> ⚠️ **它取代了什么，这里有意留着可见。** 2026-08-31 之前的处置是：「① 本仓是内部工作仓，
> 永不转 public；② 任何公开发布都从一个全新仓推出，历史从第一个提交起就干净。」
> 其理由是：对外发布本来就要仓主动手一次，把那一次用在**建新仓**而不是**销毁旧仓**上，
> 可以让不可逆动作数保持为**零**。
> ⭐ **那套推理本身没问题，变的也不是它。** 它回答的是「怎么在不带出人名的前提下发布」；
> 2026-08-31 仓主回答的是更前面那一问——「这些人名到底需不需要扣住」——答案是**不需要**，
> 因为他已看过那是什么。**前提被拿掉了，建立在它之上的结论自然不再适用。**
> 这一段是**划掉保留**而不是删掉，好让记得旧规则的人看见它是被谁、被有意地反转的，
> 而不是怀疑它是不是丢了。

⚠️ **A boundary on this entry itself**: the names here are account-roster aliases. This
entry is not a statement that nothing else is in the history — the pattern table
structurally cannot answer "is there anything the roster does not list", which is what the
human review passes are for. See [What the scanner structurally cannot cover](#what-the-scanner-structurally-cannot-cover--扫描器结构性覆盖不到什么).

⚠️ **状态：存在、已接受、不再处置——且自 2026-08-31 起，它不再限制本仓可以被用来做什么。**
（本段在那之前写的是「它改变了本仓可以被用来做什么」，并自称长期约束；该约束已由仓主解除，
见本文件顶部横幅。**名字仍在，只是不再构成扣住本仓不发布的理由。**）

真实人名（账号名册别名的短形态）在本仓的 git 对象里。它们是迁移回归套件时从基线**原样照抄**
过来的，位置在 **`test/quota-sentinel.test.sh` 的历史版本**。

**两个范围分开写，不许合成一句**：**范围 A（工作树）已为 0**，已换成
`accountA`/`accountB`/`accountC` 占位符；**范围 B（全部 git 对象，含不可达 blob）仍有 114 行，
一处未减，且靠改工作树消不掉**。
⭐ **「从此刻起新写下的东西是干净的」与「已发生的已经被抹掉」是两句话**，这里只有第一句为真。

**不要以为重写历史能解决**——不能，而且这是实测不是论证：**`force-push` 不删除远端对象**。
2026-08-27 在本仓测过：从一个全新空仓、只加 remote，按 **SHA** 去 fetch 四个已被取代的
commit，**四个全部成功**，旧文件内容照样取得出来。所以重写之后，「人名没了」对**可达历史**
为真、在**对象层**为假。⚠️ **再重写一次也没用**：那些旧 commit 早已不可达，
而问题恰恰不是「不可达」，是「**仍被供应**」。

**2026-08-31 起的处置是**：① **本仓可以转 public**；② **公开发布就从本仓推出**——
不另起新仓，也不重写历史。

> ⚠️ **它取代了什么，有意留着可见**：2026-08-31 之前写的是「① 本仓是内部工作仓，永不转
> public；② 任何公开发布都从一个全新仓推出」，理由是「对外发布本来就要仓主动手一次，
> 把那一次用在**建新仓**而不是**销毁旧仓**上，不可逆动作降到**零**」。
> ⭐ **那套推理没错，变的也不是它**——它答的是「怎么在不带出人名的前提下发布」；
> 仓主 2026-08-31 答的是更前面那一问「这些人名到底需不需要扣住」，答案是**不需要**。
> 前提被拿掉，结论自然不再适用。这里**划掉保留而不删除**，好让记得旧规则的人看出它是
> 被有意反转的，而不是被弄丢了。

⚠️ **本条自身的边界**：这里说的是账号名册别名。本条**不是**在声称历史里没有别的东西——
模式表结构上答不了「名册之外还有没有」，那正是人工复核存在的理由。

### Accepted residue — the internal system's name / 已接受的残留：那套内部系统的名字

⚠️ **Status: present, accepted, not removed.** Recorded here because the alternative —
silence — is what makes residue dangerous. Found 2026-08-27 (m3) by the manual pass, not
by the scanner.

The name of the private orchestration system this code was extracted from appears in
**7 tracked files (~35 occurrences)** and in **7 commit-message lines**. It survives for
the reason this whole subsection exists: the word is an ordinary English noun, so no
regex can separate "the internal system" from the everyday sense, and the content-layer
pattern table structurally cannot hold it.

It is in the provenance prose on purpose — sentences of the form *"everything specific to
that system lived in this file"* are what make the rewrite decisions legible. That is a
real editorial value, and it is also exactly why it was never noticed: it reads as
explanation, not as an identifier.

**Why it is accepted rather than deleted, and the reasoning is not "we could not be
bothered":**

* Removing it from the tip **manufactures a history-layer residue** — that is a measured
  property of this repository, not a guess: an earlier removal in this very file did
  exactly that, and the fix generated the next finding. Deleting from HEAD without
  rewriting history moves the string from one range the scanner covers into another.
* History rewriting is **closed** here. It was cheap once, under conditions that were
  written down at the time and no longer all hold; the standing rule since is that the
  next member of this class is accepted and documented instead. This is the next member.
* Weighed as a leak, it is not one of the things DoD-4 protects: no account address, no
  credential, no internal filesystem path. It names a system a public reader cannot
  reach and gains nothing from knowing.

⇒ **Standing instruction for later milestones:** do not "tidy this up" in passing. If it
is ever removed, it must be removed from the working tree **and** the history in the same
operation, with the owner's authorisation, or it will simply reappear one range over.

⚠️ **状态：存在、已接受、未移除。** 记在这里，因为残留真正危险的形态是「没人写下来」。
2026-08-27（m3）由人工复核发现，不是扫描器发现的。

被抽取代码所属的那套私有编排系统的名字，出现在 **7 个 tracked 文件（约 35 处）**与
**7 行 commit message** 里。它能活下来的原因正是本小节存在的理由：那个词是普通英文名词，
正则分不开「那套系统」与日常词义，内容层模式表结构上装不下它。
它出现在 provenance 散文里是**有意的**——「所有那套系统专有的东西都在这个文件里」这类句子
才让重写决定可读。这是真实的编辑价值，也正是它一直没被注意到的原因：**它读起来像解释，
不像标识符。**
⇒ 不删而是接受的理由：① 从 tip 删掉会**自己生成历史层残留**（本仓实测过，不是猜测）；
② 历史重写在本仓已结清，当时便宜的那些前提不再全部成立，同类按「接受 + 明写」处理；
③ 按泄漏权衡它不属于 DoD-4 要防的东西：不是账号邮箱、不是凭据、不是内网路径。
⇒ **给后续里程碑的长期规则：不要顺手清理它。**真要清，必须工作树与历史在同一次操作里一起清，
并取得仓主授权，否则它只会换一个范围重新出现。

### Settled residue — internal command names in git history / 已结清：git 历史里的内部命令名

✅ **SETTLED 2026-08-27 by a history rewrite** (`git filter-branch` + force-push),
authorised by the repository owner for this repository only.
✅ **2026-08-27 以历史重写结清**（`git filter-branch` + force-push），经仓主逐条授权，
授权范围仅限本仓。

Three internal command names survived in history after the working tree had been
cleaned. **They were not all found the same way, and the difference is the point:**

| name | range / 范围 | where / 位置 | found by / 谁查出来的 |
|---|---|---|---|
| the git wrapper | **B** blobs | two historical `README.md` versions (4 hits) | **scanner** — it is a regex-safe token, so it is in the content layer |
| the git wrapper | **C** message | one commit message body (1 hit) | **scanner** — same reason |
| the dashboard command | **B** blobs | one historical `lib/config.sh` (2 hits) | **human review** — an ordinary English word, see above |
| the lookup command | **B** blobs | one historical `tools/cleanroom-assert.sh` (1 hit) | **human review** — same |

⭐ **The scanner found the first two and was structurally blind to the last two.** It
did not fail; those tokens cannot be in the content layer without firing on dozens of
legitimate English uses. This is the limitation written down two sections above,
observed a second time in practice. **Do not read a CLEAN scan as "history contains no
internal names" — read it as "history contains none of the tokens that are safe to
regex."** The rest is a review obligation, and it does not expire.
⭐ **前两处是扫描器查出来的，后两处它结构性看不见。**这不是扫描器坏了：那两个 token 进
内容层就会在几十处正当英文用法上误报。这正是上面两节写下的那条限制第二次被实测。
**不要把 CLEAN 读成「历史里没有内部名字」，只能读成「历史里没有那些可以安全写成正则的
token」**；其余部分是人工复核的义务，而这条义务不会过期。

**How the 2026-08-27 human pass was made complete, and where it stops / 那一遍人工复核
怎么做到穷尽的，以及它的边界**: every blob ever committed was diffed against its tip
version; only lines that exist in history *but not at the tip* can carry a residue the
tip review already cleared, and there were 63 such lines in total, every one read by
eye. All six commit messages were read in full.
⚠️ **What this does not cover**: a token that appears *identically* at the tip and in
history. That is a range-A question about current content, not a history question, and
it is answered by reviewing the tip — not by this pass.
⚠️ **它覆盖不到什么**：在 tip 与历史里**逐字相同**出现的 token。那是关于当前内容的范围 A
问题，不是历史问题，要靠复核 tip 来回答，不靠这一遍。

**Fidelity of the rewrite / 重写的保真性**: the tip tree object is byte-identical before
and after (same tree SHA), and every author/committer name, email and date was
preserved. Only history changed; no content did.
⚠️ **The four newest commit SHAs changed.** Any document citing the pre-rewrite SHAs
needs the old→new mapping; it is recorded in the rewrite report rather than here, and
the pre-rewrite history is preserved in a git bundle held outside this repository.

**The retreat / 退路**: the complete pre-rewrite history — all six original commits,
residue included — was captured with `git bundle create --all` *before* the rewrite, and
the restore was **drilled, not assumed**: the bundle was cloned back and checked to
contain the original tip SHA *and* the residue itself.
⭐ That second half is the point. A backup check that stops at "the file is there, and
its checksum matches" answers **integrity**, never **availability** — a checksum cannot
tell you whether the thing still restores. The only check that answers the real question
is restoring it and looking at what came out.
⭐ 备份的判据是「还原出来的是不是那个东西」，不是「文件在不在、哈希对不对」——
**校验值保的是完整性，不是可得性**。所以那一遍是真的 clone 回来、真的确认残留原样重现。

⚠️ The bundle's path and checksum are **deliberately not written here.** They are an
internal filesystem location, and this file ships publicly — a document arguing for
keeping internal paths out of a public repository cannot put one in its own body. They
are recorded in the internal rewrite report instead. If you are holding this repository
and need the pre-rewrite history, ask the maintainer rather than looking for it here.
⚠️ bundle 的路径与校验值**刻意不写在这里**：它是内网文件系统位置，而本文件会被公开——
一份主张「别把内网路径带进公开仓」的文档，不能在自己正文里放一条。它们记在内部的重写
报告里。

⚠️ **最新四个 commit 的 SHA 已变**，引用旧 SHA 的文档需按映射表换算；映射表记在重写报告
里，重写前的历史另存为仓外的 git bundle。

⚠️ Site-specific patterns — the real names, your internal hostnames, your private repo
name — go in `tools/dod4-*.local.txt`, which is gitignored. They must never go in the
published `*.example.txt` files, for two reasons: it would put the hunted strings into
the repo, and the scanner would then match its own pattern file and be **permanently
red**. A check that is always red teaches people to click past red.
⚠️ 站点专有模式（真实人名、你的内部主机名、你的私有仓名）写进已 gitignore 的
`tools/dod4-*.local.txt`，绝不要写进会被公开的 `*.example.txt`。两个理由：那等于把被搜的
串放进仓里；而且扫描器会匹配到自己的模式文件从而**恒红**——一条永远红的检查会训练出
「看到红也照过」。

## What this does not cover / 它没覆盖什么

- It scans **this** repository. The source repository's own history is a separate
  question and is not addressed here.
  它扫的是**本仓**。源仓自己的历史是另一个问题，本文件不处理。
- The clean-machine sandbox (`tools/cleanroom-assert.sh`) does **not** answer this
  question. It does not isolate the network, so a hard-coded internal address would
  still connect from inside it and not a single assertion would go red. The two checks
  answer different questions; a green sandbox is never evidence of redaction.
  干净机器沙箱（`tools/cleanroom-assert.sh`）**回答不了**这个问题。它不隔离网络，
  一个写死的内网地址在箱内照样连得通，而且一条判据都不会红。两项检查答的是不同的问题；
  **沙箱全绿永远不构成脱敏已验**。
