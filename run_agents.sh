#!/usr/bin/env bash
# Usage: ./run_agents.sh -a AGENT_NAME [-t TEST_DIR] [-m MODE] [-s] [-v] [-c CONFIG_FILE] [-l]

set -euo pipefail

AGENT_NAME=""
CONFIG_FILE="agents.yaml"
TEST_DIR=""
MODE=""
STEP_MODE=0
VERBOSE=0
OUTPUT_DIR=""
DELAY=""
LIST_AGENTS=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$*" >&2; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$*" >&2; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
log_debug() { [[ "$VERBOSE" == "1" ]] && printf "${CYAN}[DEBUG]${NC} %s\n" "$*" >&2 || true; }

get_available_agents() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE" >&2
    return 1
  fi
  
  yq eval '.agents | keys | .[]' "$CONFIG_FILE" 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || echo ""
}

list_agents() {
  local agents
  agents=$(get_available_agents)
  
  if [[ -z "$agents" ]]; then
    log_error "No agents found in $CONFIG_FILE"
    return 1
  fi
  
  printf "${BLUE}Available agents in %s:${NC}\n" "$CONFIG_FILE"
  
  for agent in $agents; do
    local command desc model
    command=$(yq eval ".agents.${agent}.command // \"unknown\"" "$CONFIG_FILE" 2>/dev/null)
    model=$(yq eval ".agents.${agent}.model // \"unknown\"" "$CONFIG_FILE" 2>/dev/null)
    desc=$(yq eval ".agents.${agent}.description // \"\"" "$CONFIG_FILE" 2>/dev/null)
    
    if [[ -n "$desc" ]]; then
      printf "  ${GREEN}%-12s${NC} - %s\n" "$agent" "$desc"
      printf "  ${CYAN}%-12s${NC}   Command: %s, Model: %s\n" "" "$command" "$model"
    else
      printf "  ${GREEN}%-12s${NC} - %s (model: %s)\n" "$agent" "$command" "$model"
    fi
  done
  
  return 0
}

usage() {
  local agents
  agents=$(get_available_agents)
  
  cat <<EOF
Unified Agents Runner

Usage: $0 -a AGENT_NAME [OPTIONS]
       $0 -l

REQUIRED:
  -a AGENT_NAME     Agent to run (available: ${agents:-"none found"})

OPTIONS:
  -l                List all available agents
  -t TEST_DIR       Test directory (default: from config)
  -m MODE           Mode: headless|interactive (default: from config)
  -s                Step mode: pause before each test
  -v                Verbose output
  -c CONFIG_FILE    Configuration file (default: agents.yaml)
  -h                Show this help

EXAMPLES:
  $0 -l                           # List available agents
  $0 -a claude                    # Run Claude with default settings
  $0 -a pywen -m interactive      # Run Pywen in interactive mode
  $0 -a codex -t my_tests -s      # Run Codex with custom test dir in step mode

EOF
  exit 1
}

while getopts ":a:t:m:c:svhl" opt; do
  case "$opt" in
    a) AGENT_NAME="$OPTARG" ;;
    t) TEST_DIR="$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    c) CONFIG_FILE="$OPTARG" ;;
    s) STEP_MODE=1 ;;
    v) VERBOSE=1 ;;
    l) LIST_AGENTS=1 ;;
    h) usage ;;
    *) log_error "Invalid option: -$OPTARG"; usage ;;
  esac
done

if [[ "$LIST_AGENTS" == "1" ]]; then
  [[ ! -f "$CONFIG_FILE" ]] && { log_error "Config file not found: $CONFIG_FILE"; exit 1; }
  list_agents
  exit 0
fi

[[ -z "$AGENT_NAME" ]] && { log_error "Agent name is required (-a AGENT_NAME)"; usage; }
[[ ! -f "$CONFIG_FILE" ]] && { log_error "Config file not found: $CONFIG_FILE"; exit 1; }

if ! command -v yq >/dev/null 2>&1; then
  log_error "yq is required for YAML parsing. Install with: sudo apt install yq"
  exit 1
fi

parse_config() {
  local key="$1"
  local fallback="$2"
  local value

  value="$(yq eval -r ".agents[\"${AGENT_NAME}\"].${key} // .defaults.${key}" "$CONFIG_FILE" 2>/dev/null || true)"

  if [[ -z "$value" || "$value" == "null" ]]; then
    value="$fallback"
  fi

  case "$value" in
    true|True)  echo "true" ;;
    false|False) echo "false" ;;
    *) echo "$value" ;;
  esac
}

parse_env_config() {
  local env_key="$1"
  local value

  value="$(yq -r ".agents[\"${AGENT_NAME}\"].env.${env_key} // .defaults.env.${env_key} // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")"

  if [[ "$value" =~ ^env:(.+)$ ]]; then
    local env_var="${BASH_REMATCH[1]}"
    value="${!env_var:-}"
  fi

  [[ "$value" == "null" ]] && value=""

  echo "$value"
}


log_info "Loading configuration for agent: $AGENT_NAME"

if ! yq eval ".agents | has(\"$AGENT_NAME\")" "$CONFIG_FILE" >/dev/null 2>&1 || [[ "$(yq eval ".agents | has(\"$AGENT_NAME\")" "$CONFIG_FILE")" != "true" ]]; then
  log_error "Agent '$AGENT_NAME' not found in $CONFIG_FILE"
  log_info "Available agents:"
  list_agents
  exit 1
fi

COMMAND=$(parse_config "command" "")
ARGS=$(parse_config "args" "")
INIT_CMD=$(parse_config "init" "")
OUTPUT_SUBDIR=$(parse_config "output_subdir" "$AGENT_NAME")

TEST_DIR="${TEST_DIR:-$(parse_config "run.test_dir" "tests")}"
MODE="${MODE:-$(parse_config "run.mode" "headless")}"
OUTPUT_DIR="${OUTPUT_DIR:-$(parse_config "run.output_dir" "output")}"
DELAY="${DELAY:-$(parse_config "run.delay" "5")}"

case "$MODE" in
  headless|interactive) ;;
  *) log_error "Invalid mode: $MODE (must be headless or interactive)"; exit 1 ;;
esac

log_debug "Setting up environment variables"
while IFS= read -r env_line; do
  [[ -z "$env_line" ]] && continue
  env_key="${env_line%%=*}"
  env_value="${env_line#*=}"
  
  config_value=$(parse_env_config "$env_key")
  
  if [[ -n "$config_value" ]]; then
    export "$env_key"="$config_value"
    log_debug "Set $env_key=$config_value"
  fi
done < <(yq eval ".agents.${AGENT_NAME}.env // {} | to_entries | .[] | .key + \"=\" + .value" "$CONFIG_FILE" 2>/dev/null || true)

[[ -z "$COMMAND" ]] && { log_error "Command not specified for agent $AGENT_NAME"; exit 1; }
[[ ! -d "$TEST_DIR" ]] && { log_error "Test directory not found: $TEST_DIR"; exit 1; }

AGENT_OUTPUT_DIR="$OUTPUT_DIR/$MODE/$OUTPUT_SUBDIR"
mkdir -p "$AGENT_OUTPUT_DIR"

trajectory_var_config=$(yq eval ".agents.${AGENT_NAME}.trajectory_env_var // \"\"" "$CONFIG_FILE" 2>/dev/null)

if [[ -n "$trajectory_var_config" ]]; then
  export "$trajectory_var_config"="$AGENT_OUTPUT_DIR"
  log_debug "Set $trajectory_var_config=$AGENT_OUTPUT_DIR"
else
  var_name="${AGENT_NAME^^}_TRAJECTORY_DIR"
  export "$var_name"="$AGENT_OUTPUT_DIR"
  log_debug "Set $var_name=$AGENT_OUTPUT_DIR (generic pattern)"
fi

log_info "Configuration loaded:"
log_info "  Agent: $AGENT_NAME"
log_info "  Mode: $MODE"
log_info "  Test Directory: $TEST_DIR"
log_info "  Output Directory: $AGENT_OUTPUT_DIR"
log_info "  Command: $COMMAND $ARGS"
[[ -n "$INIT_CMD" ]] && log_info "  Init Command: $INIT_CMD"

shopt -s nullglob
tests=("$TEST_DIR"/*.txt "$TEST_DIR"/*.md)
if (( ${#tests[@]} == 0 )); then
  log_error "No *.txt or *.md files found in $TEST_DIR"
  exit 1
fi

log_info "Found ${#tests[@]} test files"

if [[ -n "$INIT_CMD" ]]; then
  log_info "Running initialization command"
  log_debug "Init: $INIT_CMD"
  if ! eval "$INIT_CMD"; then
    log_warn "Initialization command failed, continuing anyway"
  fi
fi

run_headless() {
  local test_file="$1"
  local case_id="$2"
  
  log_info "Running test case: $case_id"
  log_debug "Test file: $test_file"
  
  cd "$AGENT_OUTPUT_DIR" || exit 1

  local effective_args="$ARGS"
  if [[ "$COMMAND" == "codex" ]]; then
    if [[ ! "$ARGS" =~ (^|[[:space:]])exec($|[[:space:]]) ]]; then
      effective_args="exec $ARGS"
      log_debug "Detected codex headless mode, using: $COMMAND $effective_args"
    fi
  fi

  prompt="$(cat "$test_file")"
 
  $COMMAND $effective_args "$prompt" 

  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    log_success "Test case $case_id completed successfully"
  else
    log_warn "Test case $case_id completed with exit code $exit_code"
  fi
  
  return $exit_code
}

wait_for_fifo_content() {
  local fifo_path="/tmp/agent-done/${AGENT_NAME}.fifo"

  if [[ ! -p "$fifo_path" ]]; then
    mkdir -p "$(dirname "$fifo_path")"
    rm -f "$fifo_path" 2>/dev/null || true
    mkfifo "$fifo_path"
    echo "[INFO] Created fifo: $fifo_path"
  fi

  echo "[INFO] Waiting for message from FIFO: $fifo_path"
  exec {fd}<>"$fifo_path"

  local line
  IFS= read -r line <&"$fd"

  exec {fd}>&-

  echo "[INFO] Received from FIFO: $line"
  echo "$line"
}


run_interactive() {
  local test_file="$1"
  local case_id="$2"

  if [[ ! -f "$test_file" ]]; then
    log_warn "Test file not found: $test_file"
    return 2
  fi

  log_info  "Running test case (interactive via tmux): $case_id"
  log_debug "Test file: $test_file"

  local fifo_dir="/tmp/agent-done"
  local fifo_path="$fifo_dir/${AGENT_NAME}.fifo"
  mkdir -p "$fifo_dir/session_cases"
  if [[ ! -p "$fifo_path" ]]; then
    rm -f "$fifo_path" 2>/dev/null || true
    mkfifo "$fifo_path" 2>/dev/null || true
  fi

  local sess="agent_run"
  tmux has-session -t "$sess" 2>/dev/null && tmux kill-session -t "$sess" 2>/dev/null || true
  pane_id="$(tmux new-session -d -s "$sess" -c "$PWD" -P -F '#{pane_id}' "$COMMAND $ARGS")"
  sleep 1
  tmux send-keys -t "$pane_id" -l "CASE_ID=${case_id}"
  tmux send-keys -t "$pane_id" Enter C-m
  sleep 1
  { cat "$test_file"; printf '\n'; } | tmux load-buffer -b tmpbuf -
  tmux paste-buffer -t "$pane_id" -b tmpbuf
  tmux delete-buffer -b tmpbuf 2>/dev/null || true
  tmux send-keys -t "$pane_id" C-m
  local status="$(wait_for_fifo_content)"
  sleep 0.5
  tmux send-keys -t "$pane_id" Enter C-m
  sleep 0.5
  tmux send-keys -t "$pane_id" -l "/quit"
  tmux send-keys -t "$pane_id" Enter C-m

  if [[ "$status" == "${case_id} DONE" ]]; then
    log_success "Interactive case $case_id completed successfully (agent=${AGENT_NAME})"
    return 0
  else
    log_warn "Interactive case $case_id wait failed: $status (agent=${AGENT_NAME})"
    return 124
  fi
}


log_info "Starting test execution in $MODE mode"

for test_file in "${tests[@]}"; do
  case_id="$(basename "$test_file" | sed 's/\.[^.]*$//')"
  
  printf "\n${CYAN}────────────────────────────────────────────────────────${NC}\n"
  printf "${YELLOW}[CASE] %s - %s${NC}\n" "$case_id" "$(date -Iseconds)"
  printf "${CYAN}────────────────────────────────────────────────────────${NC}\n"
  
  if [[ "$STEP_MODE" == "1" && "$MODE" != "interactive" ]]; then
    read -rp "Press Enter to continue with test case $case_id..."
  fi
  
  case "$MODE" in
    headless)
      run_headless "$test_file" "$case_id" 
      ;;
    interactive)
      set +e
      run_interactive "$test_file" "$case_id"
      set -e
      ;;
  esac
  
  if [[ "$STEP_MODE" != "1" && "$DELAY" != "0" ]]; then
    log_debug "Waiting ${DELAY}s before next test"
    sleep "$DELAY"
  fi
done

printf "\n${GREEN}────────────────────────────────────────────────────────${NC}\n"
log_success "All test cases completed!"
printf "${GREEN}────────────────────────────────────────────────────────${NC}\n"
