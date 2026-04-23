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
  -d '{"password":"admin"}' | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))')

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

## 5. 故障排查

### 5.1 注册一直失败（手机风控 / 403）

**原因**：Codespace IP 被 OpenAI 标记。

**解决**：重建 Codespace 获取新 IP。

```bash
gh codespace rebuild -c $(gh codespace list --json name -q '.[0].name')
```

### 5.2 freemail 401 Unauthorized

**原因**：`CPA_FREEMAIL_KEY`（JWT Token）不匹配或过期。

**解决**：
1. 到 Cloudflare Workers 查看 `JWT_TOKEN` 环境变量
2. 更新仓库 Secret `CPA_FREEMAIL_KEY`
3. 重建 Codespace

### 5.3 同步到 Sub2API 失败

**原因**：`CPA_SUB2API_KEY` 错误或 Sub2API 服务不可用。

**验证**：
```bash
curl -s https://sub2.aiclawonline.website/v1/models \
  -H "Authorization: Bearer $CPA_SUB2API_KEY"
```

### 5.4 日上限到了但还想继续

修改 `MAX_DAILY_SUCCESS` 环境变量或临时手动启动：
```bash
MAX_DAILY_SUCCESS=999 bash /workspaces/openai-cpa-codespaces/.devcontainer/auto-start-reg.sh
```

---

## 6. 配置修改流程

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

## 7. 已知限制

- Codespace 有免费额度限制（每月 120 核·小时，2 核实例约 60 小时/月）
- Codespace 会在 30 分钟无活动后休眠，但 `post-start.sh` 会在恢复时重新启动
- 长时间运行建议保持 VS Code Web 连接活跃，或设置 cron 保活
- 不要同时运行多个 Codespace 注册机（浪费额度且 IP 可能重叠）

---

## 8. 相关文件速查

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

*Last updated: 2026-04-23*
*Mode: single-thread slow registration (v2)*
