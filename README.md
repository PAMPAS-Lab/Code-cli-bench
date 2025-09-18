# Code-cli-bench

## 概览

本仓库用于对比 **Pywen** 与 **Claude Code** 两个 Agent 在 **交互模式** 与 **非交互模式** 下的表现。
目标是让 Pywen 与 Claude Code 在相同输入条件下执行相同任务，通过记录双方的执行轨迹来对比，分析两个Agent处理问题的方式。

其中非交互模式运行简单，适合批量测试。交互模式更接近真实用户使用流程，适合研究对话流程，上下文管理与拼接,
可作为非交互模式的补充。

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

#### 准备环境变量 `.env`

仓库默认只提供 `.env.example`，请**手动复制**并填写：

```bash
cp .env.example .env
```

`.env` 中必须要填写的项(如果环境变量中已包含，则可忽略)：

```
ANTHROPIC_BASE_URL=
ANTHROPIC_AUTH_TOKEN=
QWEN_API_KEY=
QWEN_BASE_URL=
QWEN_MODEL=

# ↓↓↓ 为避免输出目录的权限问题，请务必设置 ↓↓↓
HOST_UID=
HOST_GID=
```

以下介绍设置这两个环境变量的方法:

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

> 如果 .env 未设置，则默认使用 1000:1000 构建镜像，可能导致宿主机无法直接修改 output 文件。

#### 构建及运行

* **构建镜像**

```bash
docker compose build 
```

* 运行**非交互模式**

```bash
docker compose up bench-headless
```

* 运行**交互模式**

```bash
docker compose up bench-interactive
```
---

### 2) 本地交互模式运行

#### 准备工作

##### A. 准备 claude code

- 设置环境变量，禁止claude code 自动升级

```bash
export DISABLE_AUTOUPDATER=1
```
- 安装`claude code`, 版本使用`v1.0.81`

```bash 
npm install -g @anthropic-ai/claude-code@1.0.81
```
- 使用`claude/cli.js` 替换`claude code`的真实执行文件
使用`which claude`查看claude真实路径，并使用`claude/cli.js`替换
```bash
which claude
# 假设结果是 /usr/local/bin/claude
cp claude/cli.js /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js
```

- 配置 Claude Code Hooks

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

- 运行claude 

运行claude，确保能正常使用claude code

##### B. 准备 Pywen

使用特殊版本的pywen
```python
git clone https://github.com/leeyeel/Pywen.git 
cd Pywen && git checkout multi-agent
```
按照[README](https://github.com/PAMPAS-Lab/Pywen) 安装pywen,确认可以正常使用。

```bash
# 克隆并切换分支
git clone https://github.com/leeyeel/Pywen.git
cd Pywen && git checkout multi-agent

# 创建虚拟环境并安装依赖
uv venv
uv sync --all-extras
uv pip install -e .
```

#### 脚本运行

```bash
./run_interactive_tmux.sh
```

也可以通过`-h`参数查看帮助信息:
```bash
Usage: ./run_interactive_tmux.sh [-t TEST_DIR] [-d SECONDS] [-s] [-v]
  -t TEST_DIR   测试用例目录（默认：tests）
  -d SECONDS    自动模式下每条用例提交后等待秒数（默认：5）
  -s            step 模式：每条用例提交前等待你按 Enter
  -v            详细模式：显示调试信息
环境变量可覆盖：
  SESSION, CLAUDE_CMD, PYWEN_CMD, DEBUG

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

### 3) 本地非交互模式运行

```bash
./run_headless.sh 
```
也可通过`-h`命令查看帮助信息:
```bash
Usage: ./run_headless.sh [-t TEST_DIR] [-s SHOW]
  SHOW: claude | pywen | both | none
```

* 遍历 `tests/*.txt`；
* 分别调用 Claude 与 Pywen 的命令行批处理接口（非交互模式）；
* 一轮进程退出即视为测试完成。

---

## 测试用例

`tests/` 目录中提供若干循序渐进的示例用例，可自行添加、逐步加深复杂度。

运行时可通过`-t`来指定测试用例文件夹，默认使用当前目录的`tests`目录作为测试用例目录。

生成的输出文件位于`output`目录，`output`目录会根据类别，测试用例序号分别存储输出内容，记录执行轨迹（trajectory）文件。

---
