# ruleset 的极限：锁的强度 = token 的权限

本文件是 skill `kernel-project-repo-bootstrap` 第八步的细节参考。

## 1. 基本事实

ruleset **拦得住 `git push`，拦不住 API**。同一个 admin token 直接

```bash
gh api -X DELETE repos/<owner>/<repo>/rulesets/<id>
```

**会成功**，锁当场消失。

- **创建 / 更新 ruleset 需要 `Administration: write`。** 手里有这个权限的人，就能把规则删掉，或改成 `"enforcement": "disabled"`。
- 组织层规则（`POST /orgs/<org>/rulesets`）需要**该组织**的 Administration write。
- 所以护栏的真正强度不由 ruleset 的字段决定，而由**持有 token 的权限集合**决定。写下 ruleset 只是把「无意中的误操作」挡住，挡不住有 Administration 的人（或 agent）。

## 2. 对策表

| 做法 | 为什么 |
| --- | --- |
| 规则放**组织**层（`POST /orgs/<org>/rulesets`，需 org 的 Administration write） | 组织规则覆盖仓库规则并取最严；只给单仓权限的 token 管不到 |
| 手机端换 **fine-grained PAT**：`Contents` + `Pull requests` + `Actions` 写权限，只在必须改 workflow 时加 `Workflows` | **绝不给 `Administration`**；更好的选择是 **GitHub App installation**——它的 token 不自带 Administration，Actions 里的 `GITHUB_TOKEN` 默认也没有 |
| **绝不**把 agent 的 deploy key 或 App 加进 bypass 列表 | `bypass_actors` 接受 `DeployKey`、`Integration` 等类型 |

## 3. 三个容易搞错的点

1. **`workflow_dispatch` 需要 `Actions: write`**；而**推 `.github/workflows/` 下的文件是另一项授权**——fine-grained token 下只有 `Contents: write` **不够**，还要 **`Workflows: write`**（经典 PAT 对应 `workflow` scope）。
2. **旧的分支保护 API**：`enforce_admins` **默认 false**，意味着管理员被豁免；必须显式设 `true`。
3. **配额与价格**：公开仓库上 ruleset **免费**；私有仓库需要 Pro / Team / Enterprise Cloud；**每个仓库最多 75 条 ruleset**。

## 4. 只读与读改写

`gh ruleset` 只能**读**（`check` / `list` / `view`）；**创建与修改必须走 `gh api`**。查当前生效规则的现成命令：

```bash
gh api repos/<owner>/<repo>/rules/branches/main   # 查生效的规则
gh ruleset check main --repo <owner>/<repo>       # gh 自带的规则评估器（只读）
```
