# agent-bench

## 概览

本仓库用于对比 **Pywen** 与 **Claude Code** 两个 Agent 在 **交互模式** 与 **非交互模式** 下的表现。
主要目标：

* **公平对比**：Prompt 组装、请求时机、响应内容；
* **自动化测试**：批量投喂测试用例；
* **精准控制**：通过 Hooks 与 FIFO 通知机制，可靠判断一轮测试是否完成。

---

## 功能点

* **测试用例目录**：`tests/` 下的 `.txt` 文件，每个文件是一轮测试输入。
* **两种运行方式**：

  * **交互模式**：tmux 分屏，两个 Agent 真正运行在交互 CLI 里，投喂脚本逐条输入。
  * **非交互模式**：直接命令行调用两个 Agent 的批处理接口，逐条读取文件输入并等待进程退出。

* **Case ID 机制**：

  * 用例文件名作为 `case_id`；
  * 交互模式：通过 `UserPromptSubmit` hook 和 Pywen 回调拦截 `CASE_ID`，Stop 时输出 DONE；
  * 非交互模式：进程退出即视为 DONE。

---

## 运行方式

### 1) Docker 运行（推荐）

#### 1. 准备 `.env`

仓库默认只提供 `.env.example`，请**手动复制**并填写：

```bash
cp .env.example .env
```

`.env` 中常用变量（与 compose 对齐）：

```
ANTHROPIC_BASE_URL=
ANTHROPIC_AUTH_TOKEN=
QWEN_API_KEY=
QWEN_BASE_URL=
QWEN_MODEL=
QWEN_SERPER_API_KEY=
PYWEN_TRAJECTORY_DIR=

# ↓↓↓ 为避免 output 目录写入 root 所有，请务必设置 ↓↓↓
HOST_UID=
HOST_GID=
```

#### 2. 正确获取并写入 UID / GID（避免 root 占有 output）

* **Linux / macOS (Bash/Zsh)：**

  ```bash
  # 查看
  id -u    # UID，常见为 1000 或 501（macOS）
  id -g    # GID

  # 追加写入到 .env（若已存在 HOST_UID/HOST_GID，请手动编辑而不是重复追加）
  echo "HOST_UID=$(id -u)" >> .env
  echo "HOST_GID=$(id -g)" >> .env
  ```

* **Windows：**

  * 如果在 **WSL** 里运行 Docker/Compose，请在 **WSL Shell** 中执行上面同样的命令获取并写入。
  * 如果直接使用 **Docker Desktop（Windows 本机路径挂载）**，文件权限由 Docker Desktop 翻译，通常**可以留空** `HOST_UID/HOST_GID`（或按需设置成 `1000:1000`）。如遇权限问题，建议改为在 WSL 中运行。

> compose 已在公共模板里设置：
>
> ```yaml
> user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
> ```
>
> 若 `.env` 未生效，会兜底使用 `1000:1000`。

#### 3. 启动

* **非交互模式（后台运行）**

  ```bash
  docker compose up -d agent-bench
  ```

* **交互模式（需要用户交互）**

  ```bash
  docker compose --profile interactive up agent-bench-interactive
  ```

  > `agent-bench-interactive` 使用 `profiles: [interactive]`，默认 `up` 不会启动，需显式加 `--profile interactive`。

#### 4. 卷挂载与路径说明

compose 已通过锚点 `x-agent-bench-common` 配置了 `volumes`（相对路径以 **compose 文件所在目录** 为基准）：

* `./tests:/workspace/agent-bench/tests`（bind mount）
* `./output:/workspace/agent-bench/output`（bind mount）
* `agent-bench-data:/workspace/data`（named volume）

若你用 `-f some/dir/docker-compose.yml` 从别处运行，建议把宿主机侧路径改为**绝对路径**，或在 `.env` 中提供：

```
PROJECT_ROOT=/abs/path/to/your/repo
```

并在 compose 中写：

```yaml
- ${PROJECT_ROOT}/tests:/workspace/agent-bench/tests
- ${PROJECT_ROOT}/output:/workspace/agent-bench/output
```

#### 5. 避免 / 修复 `output` 目录 root 占有

* **原则**：容器以你的 UID\:GID 运行 → 写出的文件在宿主机归你所有。
* **历史产物修复（只需一次）**：

  ```bash
  sudo chown -R "$(id -u)":"$(id -g)" ./output
  ```
* **必须 root 执行的任务**（不推荐，全局 root）：可在宿主机将 `output` 设为“组可写并继承”，并在容器启动命令前加 `umask 0002`：

  ```bash
  # 宿主机
  sudo chgrp -R "$(id -g)" ./output
  sudo chmod -R g+rwX ./output
  sudo find ./output -type d -exec chmod g+s {} \;

  # docker-compose.yml 中（示例）
  command: bash -lc 'umask 0002; ./run_headless.sh'
  ```
* **SELinux 系统**（Fedora/CentOS/RHEL）若遇到 `permission denied`：在挂载后加 `:z` 或 `:Z`：

  ```yaml
  - ./output:/workspace/agent-bench/output:z
  ```

#### 6. 重建与自检

```bash
# 强制重建，确保 user/volume 生效
docker compose down
docker compose up -d --build --force-recreate

# 验证容器实际运行身份
CID=$(docker compose ps -q agent-bench)
docker inspect "$CID" --format '{{.Config.User}}'   # 期望输出：<你的UID>:<你的GID>
docker compose exec agent-bench sh -lc 'id -u; id -g'

# 检查挂载
docker inspect "$CID" | jq '.[0].Mounts'
```

---

### 2) 本地运行

#### 安装依赖

* Python ≥ 3.10
* tmux
* 可选：pytest、jq

---

## 本地交互模式使用

### 1) 配置 Claude Code Hooks

`~/.claude/settings.json`：

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/ABS/PATH/TO/scripts/hooks/cc_user_prompt_submit.py"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/ABS/PATH/TO/scripts/hooks/cc_stop_notify.py"
          }
        ]
      }
    ]
  }
}
```

### 2) 配置 Pywen 回调

在 Pywen 的“本轮完成”回调中调用：

```python
from scripts.pywen_done_notify import notify_pywen_done
notify_pywen_done(case_id)
```

### 3) 启动自动投喂脚本

```bash
./run_interactive_tmux.sh
```

脚本行为：

1. 启动 tmux 会话，左侧 Claude Code，右侧 Pywen；
2. 开启 **同步输入**；
3. 遍历 `tests/*.txt`，先注入 `CASE_ID=文件名`，再投喂内容并回车；
4. 阻塞等待 Claude & Pywen 各自写 `<CASE_ID> DONE`；
5. 两侧完成 → 自动进入下一条。

tmux 热键：

* `Ctrl-b S` → 切换同步输入开/关
* `Ctrl-b ←/→` → 切换左右 pane
* `Ctrl-b :kill-session` → 退出会话

---

## 本地非交互模式使用

`./run_headless.sh` 行为：

* 遍历 `tests/*.txt`；
* 分别调用 Claude 与 Pywen 的命令行批处理接口（非交互模式）；
* 一轮进程退出即视为测试完成。

---

## 测试用例

`tests/` 目录中提供若干循序渐进的示例用例，可自行添加、逐步加深复杂度。

---

## 对比总结

* **交互模式**

  * 更贴近真实使用体验；
  * Hooks + FIFO 精准判定一轮结束；
  * 适合研究 **对话流程/上下文拼接**。

* **非交互模式**

  * 更简洁，直接跑批；
  * 进程退出即 DONE；
  * 适合快速 benchmark。

---

### 附：排错速查（卷未生效/权限异常）

* 展开 compose 检查是否包含你的 `user` 与挂载：

  ```bash
  docker compose config | sed -n '/agent-bench:$/,/^[^ ]/p'
  docker compose config | sed -n '/agent-bench-interactive:$/,/^[^ ]/p'
  ```
* 运行中验证实际身份与挂载：

  ```bash
  CID=$(docker compose ps -q agent-bench)
  docker inspect "$CID" --format '{{.Config.User}}'
  docker compose exec agent-bench sh -lc 'id -u; id -g'
  docker inspect "$CID" | jq '.[0].Mounts'
  ```
* 历史 root 产物修复：

  ```bash
  sudo chown -R "$(id -u)":"$(id -g)" ./output
  ```

---

