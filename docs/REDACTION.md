# Redaction / 脱敏说明

The code in this repository was extracted from a private codebase that ran against
real Claude accounts. This file records what was removed, how, and how you can check
that it stayed removed.
本仓的代码抽取自一个跑在真实 Claude 账号上的私有代码库。本文件记录删掉了什么、怎么删的、
以及你怎么核实它一直没回来。

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
