# 应用补丁：`git apply` / `git am` / `git quiltimport` 三路对照

本文件是 skill `kernel-project-repo-bootstrap` 第六步的细节参考。

## 1. 三路对照表

| 命令 | 保留作者与 commit message | 需要邮件头 | 上下文不匹配时 |
| --- | --- | --- | --- |
| `git apply` | ❌ 不建 commit | ❌ 不需要 | **直接失败。git 没有 fuzz 因子**（只有 `-C1`/`-C0` 可放松，默认一行上下文都不忽略） |
| `git am` | ✅ 保留 author / date / message | ✅ 需要 | 失败；可用 `-3` 三方合并 |
| `git quiltimport` | ✅ | quilt `series` | 它就是为「把 quilt 补丁集打成一个分支」设计的 |

## 2. `git apply`

- 只改工作区、**不建 commit**，也不读邮件头——它接受裸 diff。
- **没有 fuzz 因子**。这与 quilt / patch(1) 的默认行为相反，是移植补丁时最常见的意外失败来源。
- `-C<n>` 的语义：要求每处改动前后**至少 n 行上下文匹配**（上下文不足时全部必须匹配）；`-C1` / `-C0` 是放松档，**默认一行上下文都不忽略**。要打零上下文的补丁，正常做法是 `-C0` 配合 `--unidiff-zero`。
- `--whitespace` 默认是 **`warn`**：有空白警告**仍然会应用**。要「有问题就停」必须显式写 `--whitespace=error`。
- `--reject` 会写 `.rej` 文件并继续（不原子）；`--check` 只试跑、不落地。写脚本时先 `--check` 再真打。
- `--reject` 与三方合并（`-3`）**互斥**，不能同时给。

## 3. `git am`

- 从 mailbox 补丁里**保留 author / date / commit message**——要保留原作者署名时这是正确工具。
- **需要邮件头**（`From:` / `Subject:` / `Date:`），裸 diff 喂给它会被拒。
- 上下文不匹配时失败；可用 `-3` 走三方合并。
- 常用旗标：`--3way`、`--empty=drop`（丢弃空补丁）、`--keep-cr`（保留 CR）。
- 中断后的恢复：
  - `git am --continue`：冲突解决并 `git add` 之后继续。
  - `git am --skip`：跳过当前这个补丁。
  - `git am --abort`：整体回退到 `am` 之前的状态。
  - `git am --quit`：保留已应用的部分，只退出 `am` 状态（不再继续打剩下的补丁）。
  - `git am --retry`：重试上一次失败的补丁（用于「先跳过、后来把前置条件补上了」的场景）。
- `--reject` 与三方合并**互斥**：`--reject` 是「留下 `.rej` 继续」，`-3` 是「找共同祖先做三方合并」，两者对同一冲突的处理方式不同，不能同时开。

## 4. `git quiltimport`（首选）

`git` **自带**的命令，专门为「把一组 quilt 补丁打成一个分支」而写，保留补丁边界、顺序与描述（即 commit message 与作者）。单条命令胜过手写循环。

```bash
# 先试跑：不落地、只报告能不能打
git -C src quiltimport --dry-run --patches "$PWD/patches" --series "$PWD/patches/series"
# 去掉 --dry-run 即正式应用
git -C src quiltimport --patches "$PWD/patches" --series "$PWD/patches/series"
```

常用选项：

| 选项 | 作用 |
| --- | --- |
| `--dry-run` | 只演练，不改工作区 |
| `--series <file>` | 指定 quilt `series`（应用顺序） |
| `--patches <dir>` | 补丁所在目录 |
| `--author <author>` | 给没有作者信息的补丁指定作者 |
| `--keep-non-patch` | 保留 subject 不以 `[PATCH]` 开头的提交（默认只认补丁邮件） |

## 5. 手写循环的等价写法（必须 fail-loud）

不用 `quiltimport` 时才手写；每个补丁都要「先验证、再应用」，任何一个不干净立即退出：

```bash
set -euo pipefail
while read -r p; do
  [ -n "$p" ] || continue
  git -C src apply --check --whitespace=error "$PWD/patches/$p"
  git -C src am --3way --empty=drop --keep-cr "$PWD/patches/$p"
done < "$PWD/patches/series"
```

静默跳过失败的补丁 = 构建出一个你不知道缺了什么的内核。

## 6. `--3way` 的硬约束：需要本地有 blob

`git apply -3` / `git am -3` 需要**本地存在补丁所记录的 blob**（补丁里那三个索引 SHA），否则报：

> `error: repository lacks the necessary blob to perform 3-way merge.`

推论，二选一，不能混：

- **要么** `--3way` 配**完整 clone**（有全部 blob）；
- **要么** blobless / shallow clone 配**纯 `git apply`（不带 `-3`）**。

另外 `--filter=blob:none` 的部分克隆和 `--depth 1` 的浅克隆都属于「没有那些 blob」，在这类仓上开 `-3` 一定走到上面那条错误。
