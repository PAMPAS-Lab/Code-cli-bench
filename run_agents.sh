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
  local prompt="$3"
  
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
 
  $COMMAND $effective_args "$prompt" 

  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    log_success "Test case $case_id completed successfully"
  else
    log_warn "Test case $case_id completed with exit code $exit_code"
  fi
  
  return $exit_code
}

run_interactive() {
  local test_file="$1"
  local case_id="$2"
  local prompt="$3"

  log_info "Interactive mode: $case_id"

  if [[ "$STEP_MODE" == "1" ]]; then
    read -rp "Press Enter to start interactive session for $case_id..."
  fi

  cd "$AGENT_OUTPUT_DIR" || exit 1

  printf "\n${CYAN}── Interactive chat started ──${NC}\n"
  printf "${YELLOW}Agent:${NC} %s\n" "$AGENT_NAME"
  printf "${YELLOW}Command:${NC} %s %s\n" "$COMMAND" "$ARGS"
  printf "${YELLOW}Output dir:${NC} %s\n" "$AGENT_OUTPUT_DIR"
  printf "${YELLOW}Tips:${NC} Type /quit to exit (or press Ctrl-C).\n\n"

  if [[ -n "$INIT_CMD" ]]; then
    log_debug "Running init: $INIT_CMD"
    eval "$INIT_CMD" || log_warn "Init command exited non‑zero"
  fi

  if [[ -t 0 && -t 1 ]]; then
    if [[ -n "$prompt" ]]; then
      printf "${BLUE}[HINT]${NC} First message from test file (%s):\n\n%s\n\n" "$(basename "$test_file")" "$prompt" >&2
    fi

    set +e
    $COMMAND $ARGS
    local exit_code=$?
    set -e
    if [[ $exit_code -ne 0 ]]; then
      log_warn "Interactive session exited with code $exit_code"
    else
      log_success "Interactive session finished"
    fi
    return $exit_code
  else
    log_warn "No TTY detected; falling back to pseudo‑interactive single‑turn loop."
    log_info "Enter lines; empty line to end. Each line will be sent as an independent prompt."
    local line
    while IFS= read -r line; do
      [[ -z "$line" ]] && break
      echo "$line" | $COMMAND $ARGS
      printf "\n"
    done
    return 0
  fi
}

log_info "Starting test execution in $MODE mode"

for test_file in "${tests[@]}"; do
  case_id="$(basename "$test_file" | sed 's/\.[^.]*$//')"
  prompt="$(cat "$test_file")"
  
  printf "\n${CYAN}────────────────────────────────────────────────────────${NC}\n"
  printf "${YELLOW}[CASE] %s - %s${NC}\n" "$case_id" "$(date -Iseconds)"
  printf "${CYAN}────────────────────────────────────────────────────────${NC}\n"
  
  if [[ "$STEP_MODE" == "1" && "$MODE" != "interactive" ]]; then
    read -rp "Press Enter to continue with test case $case_id..."
  fi
  
  case "$MODE" in
    headless)
      run_headless "$test_file" "$case_id" "$prompt"
      ;;
    interactive)
      run_interactive "$test_file" "$case_id" "$prompt"
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
