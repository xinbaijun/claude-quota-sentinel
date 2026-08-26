# claude-quota-sentinel

> 🚧 **Skeleton / 骨架阶段** — sections marked *(placeholder / 占位)* are not written
> yet and will be filled in a later milestone. **Sections without that marker are
> already in force and are not drafts to be overwritten** — this applies in particular
> to **Provenance**, whose extraction rule is normative and has no expiry.
> 标了 *(placeholder / 占位)* 的小节尚未成文，留待后续里程碑补齐。**未标占位的小节
> 已经生效，不是待覆盖的草稿**——尤其是 **Provenance**，其中的抽取规则是规范性的、
> 长期有效。

Watch Claude account quota, switch accounts when a threshold is hit, and keep an audit
trail of every switch.
监控 Claude 账号额度，到阈值自动切号，并为每次切换留下可追溯的账目。

## What it solves / 解决什么

*(placeholder / 占位)*

## What it does NOT solve / 不解决什么

*(placeholder / 占位)*

## Known failure modes / 已知会怎么坏

*(placeholder / 占位)* — every guard in this project exists because something actually
broke once; the incident notes travel with the code.
本项目的每一条守卫背后都有一次真实事故，事故记录随代码一起保留。

## Requirements / 运行前提

*(placeholder / 占位)* — Linux only for now; macOS and Windows are **unverified**.
暂时只保证 Linux；macOS 与 Windows 标为**未验证**。

## Install / 安装

*(placeholder / 占位)*

## Usage / 使用

*(placeholder / 占位)*

## Testing / 测试

*(placeholder / 占位)* — the regression suite lands in a later milestone. It ships with
**positive controls**: every guard must be able to prove that it goes red.
回归套件在后续里程碑落地，随附**正控**：每条守卫都要能证明它会红。

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

## Prior art / 相关项目

*(placeholder / 占位)*

## Provenance / 抽取来源

Extracted from a private in-house fleet-automation codebase at commit `e2f32279`.
Upstream changes after that commit are **not** tracked and **not** synced back.
抽取自内部私有编队自动化代码库的 `e2f32279`；该 commit 之后的上游改动**不追平、不双向同步**。

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
it with a git wrapper that unconditionally exports
`GIT_SSH_COMMAND`, environment beats config in git's precedence order, and the in-repo
wiring is silently replaced by a default key that has no access here. Plain `git` works.

本仓用仓内 `core.sshCommand` 接自己的 deploy key。**不要**用会改 SSH 命令的 git 包装器
操作本仓：它会无条件 `export GIT_SSH_COMMAND`，而 git 的优先级是环境变量高于配置，
仓内接线会被静默换成一把在这里没有权限的缺省 key。用原生 `git` 即可。

## License / 许可证

MIT — see [LICENSE](LICENSE).
