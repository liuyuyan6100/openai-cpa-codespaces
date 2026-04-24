# AGENT.md — openai-cpa Codespace 注册机运维手册

> 本文档记录 Codespace 侧注册机的部署、配置和运维知识。
> 修改配置前务必阅读，避免重复踩坑。

---

## 1. 架构概览

```
GitHub Codespace ( ephemeral, x86_64 )
  ├── post-start.sh          # Codespace 启动后自动执行
  ├── .devcontainer/
  │   ├── config.template.yaml   # 配置模板（环境变量注入）
  │   ├── inject-config.py       # 将 Secrets 注入模板
  │   ├── auto-start-reg.sh      # 自动启动注册引擎
  │   ├── monitor.sh             # 守护进程：监控+自动重启
  │   └── sync-back.sh           # 关机前同步数据回仓库
  └── /workspaces/openai-cpa-runtime/   # 拉取的官方代码
      ├── wfxl_openai_regst.py   # 主程序
      └── data/
          ├── config.yaml        # 注入后的实际配置
          └── data.db            # SQLite 账号数据库
```

**数据流**：
1. `post-start.sh` 拉取官方 tag → 应用本地 patch → 注入配置 → 启动引擎
2. `auto-start-reg.sh` 获取 Web UI token → 调用 `/api/start` 启动注册
3. `monitor.sh` 每 30 分钟检查一次，如果注册停了且未达日上限则自动重启
4. 注册成功 → 通过 `cpa_mode` / `sub2api_mode` 同步到 VPS 的 CLIProxyAPI / Sub2API

---

## 2. 核心哲学：单线程拟人慢注册

**为什么？** 多线程暴力注册极易触发 OpenAI 风控（手机验证、403、封号）。
实际成功率约 **10%**（甚至更低）。

**目标**：每天自然产出 **20-30 个成功账号**，不追求速度，追求存活率。

### 2.1 关键参数（已调优）

| 参数 | 值 | 说明 |
|------|-----|------|
| `worker_threads` | 1 | 全局工作线程 |
| `max_concurrent` | 1 | 最大并发 |
| `reg_threads` | 1 | 注册线程 |
| `cpa_mode.threads` | 1 | CPA 同步线程 |
| `sub2api_mode.threads` | 1 | Sub2API 同步线程 |
| `sub2api_mode.account_concurrency` | 1 | 账号并发 |
| `login_delay_min` | 120 | 注册后等 2-5 分钟再拿 token |
| `login_delay_max` | 300 | |
| `normal_mode.sleep_min` | 180 | 每轮间隔 3-7 分钟 |
| `normal_mode.sleep_max` | 420 | |
| `normal_mode.target_count` | 1 | 每轮只注册 1 个 |
| `check_interval_minutes` | 180 | 库存检查间隔 3 小时 |
| `monitor REG_CHECK_INTERVAL` | 1800 | 监控每 30 分钟检查一次 |
| `monitor MAX_CONSECUTIVE_FAILS` | 5 | 连续 5 次无成功才判定失败 |
| `MAX_DAILY_SUCCESS` | 30 | 日成功上限 |
| `RANDOM_DELAY` | 0-900s | 启动时随机延迟 0-15 分钟 |

### 2.2 产量估算

- 每轮周期：注册 1-2min + 等待 3-7min ≈ **平均 6 min/轮**
- 每小时：约 **10 次尝试**
- 一天运行 20h：约 **200 次尝试**
- 按 10% 成功率：约 **20 个成功/天**

> 如果成功率低于 10%，考虑换 IP（重建 Codespace）或换域名。

---

## 3. GitHub Secrets 配置

在仓库 Settings → Secrets and variables → Codespaces 中设置：

| Secret | 说明 | 示例 |
|--------|------|------|
| `CPA_FREEMAIL_KEY` | freemail JWT Token | `fjiwaiv2...` |
| `CPA_SUB2API_KEY` | Sub2API API Key | `sk-...` |
| `CPA_SUB2API_URL` | Sub2API 地址 | `https://sub2.aiclawonline.website` |
| `CPA_SUB2API_ADMIN_EMAIL` | Sub2API 管理员邮箱 | `admin@aiclawonline.website` |
| `CPA_SUB2API_ADMIN_PASSWORD` | Sub2API 管理员密码 | `...` |
| `CPA_WEB_PASSWORD` | openai-cpa Web UI 密码 | `admin` |
| `CPA_API_SECRET` | 远程同步密钥 | `...` |

**注意**：Secrets 只在 Codespace 创建/重启时注入，修改 Secrets 后需要重建 Codespace 才能生效。

---

## 4. 常用操作

### 4.1 查看实时日志

```bash
# 注册引擎日志
tail -f /workspaces/openai-cpa-codespaces/.codespaces/logs/openai-cpa.log

# 监控守护进程日志
tail -f /workspaces/openai-cpa-codespaces/.codespaces/logs/monitor.log

# 自动启动日志
tail -f /workspaces/openai-cpa-codespaces/.codespaces/logs/auto-start.log
```

### 4.2 手动启停注册

```bash
# 获取 token
TOKEN=$(curl -s -X POST http://127.0.0.1:8000/api/login \
  -H "Content-Type: application/json" \
  -d '{"password": "admin"}' | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))')

# 启动
curl -s -X POST http://127.0.0.1:8000/api/start \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json"

# 停止
curl -s -X POST http://127.0.0.1:8000/api/stop \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json"

# 查看状态
curl -s http://127.0.0.1:8000/api/status \
  -H "Authorization: Bearer $TOKEN"
```

### 4.3 重建 Codespace（换 IP）

Codespace IP 是固定的，但重建后会分配新 IP。

```bash
# 方法 1：在 Web UI 中点击 "Rebuild"
# 方法 2：CLI
gh codespace rebuild -c <codespace-name>
```

**注意**：重建会丢失 `/workspaces/openai-cpa-runtime/` 目录，但 `.codespaces/` 和 `.devcontainer/` 会保留（因为它们是仓库代码）。数据会通过 `sync-back.sh` 在关机前保存到仓库的 `.codespaces/backups/`。

### 4.4 查看今日成功数

```bash
grep -cE '注册成功|凭据提取成功' /workspaces/openai-cpa-codespaces/.codespaces/logs/openai-cpa.log
```

---

## 5. 踩坑记录（必读）

### 坑 1：端口必须默认 public

Codespace 创建后端口默认 private，Web UI 外部无法访问，agent 也无法通过 curl 检查状态。

**解决**：`.devcontainer/devcontainer.json` 中必须设置：
```json
"portsAttributes": {
  "8000": {
    "visibility": "public"
  }
}
```
> 以后所有 Codespace 部署默认 public，不再询问。

### 坑 2：重建后配置被模板覆盖

`post-start.sh` 每次重建都会用 `config.template.yaml` + `inject-config.py` 重新生成 `data/config.yaml`。
如果只在 `data/config.yaml` 里修改（比如切到 freemail 模式），重建后会被覆盖回 `cloudflare_temp_email`。

**血的教训**：曾因此导致 19 次注册全部失败（freemail 配置丢失，邮箱模式不对）。

**解决**：所有配置修改必须走 `.devcontainer/config.template.yaml`，然后 git commit + push。

### 坑 3：monitor.sh 多行 log 导致整数比较失败

`get_today_success()` 函数在特定情况下会输出多行（包含空行），导致 `[ "$today_success" -ge "$MAX_DAILY_SUCCESS" ]` 报 `integer expression expected`。

**解决**：确保 `get_today_success` 始终只输出一个整数。当前版本已修复（通过 `echo "${count:-0}"` 和管道控制）。

### 坑 4：后台启动被拦截

在 Codespace 中直接用 `&` 或 `nohup` 后台启动进程会被 shell/terminal 工具拦截或误判。

**解决**：使用 Python `subprocess.Popen` 启动，或者将启动命令写入独立 shell 脚本再调用。示例如 `post-start.sh` 中的引擎启动方式。

### 坑 5：auto-start-reg.sh 的 `RANDOM_DELAY` 与 monitor 冲突

`auto-start-reg.sh` 启动时有 0-15 分钟随机延迟，但 `monitor.sh` 会在启动后立即开始计时。如果随机延迟较长，monitor 可能在引擎实际启动前就判定超时。

**解决**：当前版本 monitor 已改为"进程存活 + 状态轮询"双保险，不再单纯依赖时间。`REG_CHECK_INTERVAL` 设为 30 分钟，给足启动时间。

### 坑 6：freemail JWT Token 必须通过 Secret 注入

`config.template.yaml` 中的 `api_token` 使用 `${CPA_FREEMAIL_KEY:-fallback}` 语法。如果 Secret 未设置，fallback 是硬编码的旧 token，可能过期。

**解决**：始终通过 `gh secret set CPA_FREEMAIL_KEY -a codespaces` 在仓库级别设置，确保重建后自动注入最新 token。

---

## 6. 故障排查

### 6.1 注册一直失败（手机风控 / 403）

**原因**：Codespace IP 被 OpenAI 标记。

**解决**：重建 Codespace 获取新 IP。

```bash
gh codespace rebuild -c $(gh codespace list --json name -q '.[0].name')
```

### 6.2 freemail 401 Unauthorized

**原因**：`CPA_FREEMAIL_KEY`（JWT Token）不匹配或过期。

**解决**：
1. 到 Cloudflare Workers 查看 `JWT_TOKEN` 环境变量
2. 更新仓库 Secret `CPA_FREEMAIL_KEY`
3. 重建 Codespace

### 6.3 同步到 Sub2API 失败

**原因**：`CPA_SUB2API_KEY` 错误或 Sub2API 服务不可用。

**验证**：
```bash
curl -s https://sub2.aiclawonline.website/v1/models \
  -H "Authorization: Bearer $CPA_SUB2API_KEY"
```

### 6.4 日上限到了但还想继续

修改 `MAX_DAILY_SUCCESS` 环境变量或临时手动启动：
```bash
MAX_DAILY_SUCCESS=999 bash /workspaces/openai-cpa-codespaces/.devcontainer/auto-start-reg.sh
```

---

## 7. 配置修改流程

**严禁直接修改注入后的 `data/config.yaml`**，因为每次重建都会被覆盖。

正确流程：
1. 修改 `.devcontainer/config.template.yaml`
2. git commit + push
3. 重建 Codespace

或者临时测试（不持久化）：
1. 修改 `.devcontainer/config.template.yaml`
2. 手动运行 `inject-config.py`
3. 重启引擎

---

## 8. 已知限制

- Codespace 有免费额度限制（每月 120 核·小时，2 核实例约 60 小时/月）
- Codespace 会在 30 分钟无活动后休眠，但 `post-start.sh` 会在恢复时重新启动
- 长时间运行建议保持 VS Code Web 连接活跃，或设置 cron 保活
- 不要同时运行多个 Codespace 注册机（浪费额度且 IP 可能重叠）

---

## 9. 相关文件速查

| 文件 | 作用 |
|------|------|
| `.devcontainer/config.template.yaml` | 配置模板（唯一持久化配置源） |
| `.devcontainer/post-start.sh` | Codespace 启动总入口 |
| `.devcontainer/inject-config.py` | Secrets → config.yaml 注入器 |
| `.devcontainer/auto-start-reg.sh` | 自动启动注册 |
| `.devcontainer/monitor.sh` | 守护监控 |
| `.devcontainer/sync-back.sh` | 关机数据同步 |
| `AGENT.md` | 本文档 |

---

## 10. 升级与回滚机制

openai-cpa 和 Sub2API 都会频繁升级。每次升级都可能引入 breaking change 或 patch 冲突。
因此必须有一套**升级前快照 + 失败自动回滚**机制。

### 10.1 快照系统

每次重建或升级前，自动备份 `data.db` + `config.yaml` + 当前 tag：

```
.codespaces/snapshots/
  ├── latest/              -> 软链接到最新快照
  ├── 20260424-020000/     -> 具体快照目录
  │   ├── data/
  │   │   ├── data.db
  │   │   └── config.yaml
  │   └── tag.txt          -> 当时的 openai-cpa tag
```

- 保留最近 **10 个**快照，自动清理旧的
- `latest` 软链接始终指向最近一次快照

手动创建快照：
```bash
bash /workspaces/openai-cpa-codespaces/.devcontainer/scripts/snapshot.sh [tag]
```

### 10.2 运行时升级（不重建 Codespace）

用于快速测试新版，失败可秒级回滚：

```bash
# 升级到 v13.0.0
bash /workspaces/openai-cpa-codespaces/.devcontainer/scripts/upgrade.sh v13.0.0
```

升级流程：
1. 自动快照当前 data + tag
2. 停止当前引擎
3. 拉取新 tag → apply patches
4. 如果 patch 失败 → 自动回滚
5. 启动引擎 → health check（60s 超时）
6. 如果 health check 失败 → **自动回滚到上一个快照**
7. 成功后更新 `latest` 链接

### 10.3 运行时回滚

```bash
# 回滚到最近一次快照
bash /workspaces/openai-cpa-codespaces/.devcontainer/scripts/rollback.sh

# 回滚到指定快照
bash /workspaces/openai-cpa-codespaces/.devcontainer/scripts/rollback.sh 20260424-020000
```

### 10.4 重建时自动回滚

`post-start.sh` 在重建时也会：
1. 启动前自动快照现有 data
2. 拉取 `CPA_TAG` 并 apply patches
3. 启动后 8 秒做 health check
4. 如果 health check 失败且 `latest/tag.txt` 中的旧 tag 不同 → **自动 rollback**

这意味着：即使你把 `CPA_TAG` 改成了一个坏的版本，重建 Codespace 后如果引擎起不来，它会自动尝试回滚到上一个已知的可用 tag。

### 10.5 配置仓库的 Git 分支策略（推荐）

虽然运行时回滚能救命，但最安全的升级方式是**分支隔离**：

```
main 分支   -> 当前生产环境用的稳定版本
  ↑
  |  merge（测试通过后）
  |
dev 分支    -> 测试新 tag / 新 patches 的地方
```

**升级流程**：
1. 在本地 clone 仓库，切到 `dev` 分支
2. 修改 `.devcontainer/post-start.sh` 中的 `CPA_TAG` 为新版本
3. 如果新 tag 需要更新 patches，同步修改 `patches/` 目录
4. `git commit && git push origin dev`
5. 在 GitHub 上基于 `dev` 分支**新建一个 Codespace**（测试环境）
6. 观察测试 Codespace 是否能正常启动、注册、同步
7. 测试通过后：`git checkout main && git merge dev && git push`
8. 重建生产 Codespace：`gh codespace rebuild -c <name>`

这样生产 Codespace 永远不会直接踩到新版本的坑。

### 10.6 Sub2API 升级注意事项

Sub2API 是独立部署在 VPS 上的服务（不在 Codespace 中）。如果 Sub2API 升级导致 API 接口变化：

- Codespace 中调用 Sub2API 的 client 代码在 patch `0004` 中
- 需要更新 patch 以适配新接口
- Sub2API 本身的数据库/配置回滚需要在 VPS 侧操作（Docker 镜像快照或数据备份）

**建议**：Sub2API 升级前在 VPS 上执行：
```bash
docker commit sub2api sub2api:backup-$(date +%s)
```
出问题后一键恢复旧镜像。

---

*Last updated: 2026-04-24*
*Mode: single-thread slow registration (v2)*
*Secrets: CPA_FREEMAIL_KEY 已设置*
*Upgrade/rollback: v3*
