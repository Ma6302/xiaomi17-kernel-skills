# 范本仓与 RED 基线：这个 skill 为什么这样写

本文件是 skill `kernel-project-repo-bootstrap` 的背景与证据，不是操作步骤。正文只留结论。

## 1. 范本仓真的建出来了

**这件事真的发生了。** 手机侧 agent 按本 skill 的指导建出了 `xiaomi17-kernel`，它随后成为这类仓库的**可用范本**：

- patch stack 形态（只 pin SHA + 存补丁 / 配置 / 脚本，不含上游源码树）；
- GPL-2.0-only 根许可证 + 按目录划分（`scripts/`、`config/`、`versions.lock` = MIT，`docs/` = CC-BY-4.0）；
- 分段式 `versions.lock`（`[upstream]` / `[verification]` / `[tree]` / `[toolchain]` / `[artifacts]` / `[device]` / `[abi_baseline]`）；
- 带断言清单的 `fetch-sources.sh`；
- `CONTRIBUTING.md` 的证据规则；
- 实测开机三连（`boot_index` 365 / 367 / 372）。

上一版 skill 里「推测的最佳实践」，现在换成了这个仓里逐字可查的做法。

## 2. RED 基线（一个没有这个 skill 的 agent，被要求「建内核工程仓」）

它表现**相当好**：选对了 GPL-2.0、patch stack、pin SHA、排除清单。所以本 skill 的价值集中在它说错、以及它**不知道自己不知道**的地方：

1. 它推荐 `--filter=blob:none --no-checkout` + `git checkout <sha>`，并断言「普通 `--depth 1` 检不出任意 SHA」——**后半句被实测推翻**（`git fetch --depth 1 origin <sha>` 对 tip、同分支非 tip、跨分支 SHA 全部成功）；前半句是性能陷阱，blobless 仓上叠 `--3way` 会报 `error: repository lacks the necessary blob to perform 3-way merge.`。
2. 它在 ruleset 里**主动放弃**了 required PR，理由是「会锁住单人开发」——而这个仓恰恰有**两个写入者**（桌面 + 手机），护栏要防的就是第二个。
3. 它（和基线一样）把「内核补丁都是 GPL-2.0」当前提：KernelSU 只有 `kernel/` 是 GPL-2.0-only，`susfs4ksu` 的 LICENSE 是 GPLv3 全文，而 GPL-3.0 **不在** kernel.org 的 GPL-2.0 兼容集里。这一条不做，仓库的许可证从第一天起就是错的。
4. 它只把 `versions.lock` 当成「写个 SHA 的地方」：没有段结构、没有 `[verification]`、没有三条自带规则，也没把「关键文件存在性 + 血统标志 grep」当成取源码后的廉价探针——于是「这棵树能不能用」这个最贵的问题被推到了编译和刷机之后。

## 3. 一条忠实的基线结论

**当基线已经做对了大部分事，skill 就应该只写它做错的部分，而不是把它的正确做法抄一遍充数。**
