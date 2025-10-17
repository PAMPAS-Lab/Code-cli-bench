# Code-cli-bench

## 概览

一个简化的、适用于测试的，基于YAML配置的统一agent运行框架。

本仓库用于对比不同Agent，或者相同Agent使用不同LLM时， 在 **交互模式** 与 **非交互模式** 下的表现。
目标是在相同输入条件下执行相同任务，通过记录双方的执行轨迹来对比，分析不同的Agent处理问题的方式。

其中非交互模式运行简单，适合批量测试。交互模式更接近真实用户使用流程，适合研究对话流程，上下文管理与拼接,
可作为非交互模式的补充。

---

## 功能点

- **完全动态** - 零硬编码，所有agent行为都由YAML配置控制
- **动态agent发现** - 从 `agents.yaml` 自动读取可用agents
- **单agent执行** - 避免复杂的并发同步问题
- **配置驱动** - 100%通过YAML配置控制agent行为
- **多种运行模式** - 支持headless和interactive模式
- **智能错误处理** - 详细的错误信息和自动建议
- **即插即用** - 添加新agent只需修改YAML配置，无需改代码

* **测试用例目录**：`tests/` 下的 `.txt` 文件，每个文件是一轮测试输入。
* **两种运行方式**：

  * **交互模式**：使用tmux，Agent 真正运行在交互 CLI 里，投喂脚本逐条输入。
  * **非交互模式**：直接命令行调用Agent 的批处理接口，逐条读取文件输入并等待进程退出。

* **Case ID 机制**：

  * 用例文件名作为 `case_id`；
  * 交互模式：通过 `UserPromptSubmit` hook 拦截 `CASE_ID`，Stop 时输出 DONE；
  * 非交互模式：进程退出即视为 DONE。

---

## 快速开始

### 1. 查看可用agents
```bash
./run_agents.sh -l
```

### 2. 准备工作(如果已配置好，可跳过) 

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

```bash
git clone https://github.com/PAMPAS-Lab/Pywen.git
cd Pywen && git checkout dev
```
按照[README](https://github.com/PAMPAS-Lab/Pywen) 安装pywen,确认可以正常使用。

安装完成后需要配置hook脚本:

- 拷贝文件

```bash
cp pywen/pywen_hooks.json ~/.pywen/
cp -r pywen/script ~/.pywen/
chmod -R u+x ~/.pywen/script
```

- 编辑pywen_hooks.json,确保脚本路径正确.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.pywen/script/pywen_userprompt.py"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.pywen/script/pywen_stop.py"
          }
        ]
      }
    ]
  }
}
```

##### C. 准备codex

- 安装codex

```
npm install -g @openai/codex@0.46.0
```

- 拷贝补丁版本替换默认版本

```
#获取codex目录
codex_bin="$(which codex)" || { echo "codex 未安装"; exit 1; }
node_root="$(dirname "$(dirname "$codex_bin")")"

#判断处理器架构
arch=$(uname -m)
case $arch in x86_64|amd64) arch=x86_64;; arm64|aarch64) arch=aarch64;; esac && sys=$(uname -s) 
case $sys in Darwin) os=apple-darwin;; Linux) os=unknown-linux-musl;; MINGW*|MSYS*|CYGWIN*) os=pc-windows-msvc;; *) os=unknown-linux-musl;; esac  
triple="${arch}-${os}"

#获取真正二进制路径，并覆盖
real_path="$node_root/lib/node_modules/@openai/codex/vendor/$triple/codex/codex"
cp codex/codex $real_path
```


### 3. 运行agent
```bash
# 运行Claude (默认headless模式)
./run_agents.sh -a claude

# 运行Pywen (交互模式)
./run_agents.sh -a pywen -m interactive

# 步进模式
./run_agents.sh -a codex -s
```

## 配置文件结构

### agents.yaml 完整配置说明

```yaml
# 默认配置
defaults:
  env:
    LOG_LEVEL: INFO
  run:
    output_dir: output         # 输出根目录
    test_dir: tests            # 测试目录
    mode: headless             # 默认运行模式
    delay: 1                   # 测试间延迟(秒)

# Agent定义
agents:
  pywen:
    # 基本配置
    command: "pywen"                                # 执行命令
    init: ""                                        # 初始化命令(可选)
    args: "--permission-mode=yolo --agent=qwen"     # 命令参数
    model: "env:QWEN_MODEL"                         # 模型名称,可直接填写，也可读用户取环境变量
    description: "pywen agent"                      # 描述信息
    
    # 环境变量
    env:
      QWEN_API_KEY: "env:QWEN_API_KEY"              #支持直接填写，也可以读取用户环境变量
      QWEN_BASE_URL: "env:QWEN_BASE_URL"
      PYWEN_TRAJECTORY_DIR: ""
      PYWEN_EXTRA: ""
```


## Docker 运行 （暂不支持）

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

* 运行

```bash
docker compose up 
```
---

## 测试用例

`tests/` 目录中提供若干循序渐进的示例用例，可自行添加、逐步加深复杂度。

运行时可通过`-t`来指定测试用例文件夹，默认使用当前目录的`tests`目录作为测试用例目录。

生成的输出文件位于`output`目录，`output`目录会根据类别，测试用例序号分别存储输出内容，记录执行轨迹（trajectory）文件。

---
