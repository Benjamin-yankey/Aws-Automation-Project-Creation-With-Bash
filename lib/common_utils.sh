#!/usr/bin/env bash

# ===========================
# COMMON UTILITIES LIBRARY
# Source this file in your scripts: source ./common_utils.sh
# ===========================

# Color codes for terminal output (use conditional assignment to avoid readonly errors)
: "${RED:='\033[0;31m'}"
: "${GREEN:='\033[0;32m'}"
: "${YELLOW:='\033[1;33m'}"
: "${BLUE:='\033[0;34m'}"
: "${MAGENTA:='\033[0;35m'}"
: "${CYAN:='\033[0;36m'}"
: "${WHITE:='\033[1;37m'}"
: "${NC:='\033[0m'}"

# Log levels
: "${LOG_LEVEL_ERROR:=0}"
: "${LOG_LEVEL_WARN:=1}"
: "${LOG_LEVEL_INFO:=2}"
: "${LOG_LEVEL_SUCCESS:=3}"
: "${LOG_LEVEL_DEBUG:=4}"

# Default log level
CURRENT_LOG_LEVEL="${LOG_LEVEL:-$LOG_LEVEL_INFO}"

# ===========================
# COLORED LOGGING FUNCTIONS
# ===========================

# Generic log function with colors
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    local emoji=""
    local log_to_file="${LOG_FILE:-}"
    
    case "$level" in
        ERROR)
            color="$RED"
            emoji="✗"
            ;;
        WARN|WARNING)
            color="$YELLOW"
            emoji="⚠"
            level="WARN"
            ;;
        INFO)
            color="$CYAN"
            emoji="ℹ"
            ;;
        SUCCESS)
            color="$GREEN"
            emoji="✓"
            ;;
        DEBUG)
            color="$MAGENTA"
            emoji="🔍"
            ;;
        *)
            color="$WHITE"
            emoji="•"
            ;;
    esac
    
    # Console output with color
    echo -e "${color}${emoji} [$timestamp] [$level] $message${NC}"
    
    # File output without color codes
    if [ -n "$log_to_file" ]; then
        echo "[$timestamp] [$level] $message" >> "$log_to_file"
    fi
}

log_error() {
    log "ERROR" "$@" >&2
}

log_warn() {
    log "WARN" "$@"
}

log_info() {
    log "INFO" "$@"
}

log_success() {
    log "SUCCESS" "$@"
}

log_debug() {
    log "DEBUG" "$@"
}

# Print section header
print_header() {
    local title="$1"
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${WHITE}$title${NC}"
    echo -e "${BLUE}==========================================${NC}"
    [ -n "${LOG_FILE:-}" ] && echo "=== $title ===" >> "$LOG_FILE"
}

# ===========================
# DRY-RUN GUARD CLAUSE
# ===========================

# Guard clause for dry-run mode
# Returns 0 (success) if in dry-run mode, allowing early return
# Usage: dry_run_guard "Would create bucket" && return
dry_run_guard() {
    local message="$1"
    
    if [ "${DRY_RUN:-false}" = "true" ]; then
        log_info "[DRY-RUN] $message"
        return 0
    fi
    
    return 1
}

# AWS command wrapper with dry-run support
aws_cmd() {
    if dry_run_guard "aws $*"; then
        return 0
    fi
    
    aws "$@" 2>> "${LOG_FILE:-/dev/null}"
}

# ===========================
# VALIDATION FUNCTIONS
# ===========================

# Check if command exists
require_command() {
    local cmd="$1"
    local install_msg="${2:-Please install $cmd}"
    
    if ! command -v "$cmd" &> /dev/null; then
        log_error "$cmd is not installed. $install_msg"
        exit 1
    fi
    
    log_success "$cmd is available"
}

# Validate CIDR format
validate_cidr() {
    local cidr="$1"
    local name="${2:-CIDR}"
    
    if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        log_error "Invalid CIDR format for $name: $cidr"
        exit 1
    fi
    
    log_debug "Valid CIDR format for $name: $cidr"
}

# Validate S3 bucket name
validate_bucket_name() {
    local name="$1"
    
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
        log_error "Invalid bucket name format. Must be 3-63 chars, lowercase, start/end with letter/number"
        exit 1
    fi
    
    if [[ "$name" =~ \.\. ]] || [[ "$name" =~ \.- ]] || [[ "$name" =~ -\. ]]; then
        log_error "Invalid bucket name: cannot have consecutive periods or period-dash combinations"
        exit 1
    fi
    
    log_debug "Bucket name validation passed: $name"
}

# ===========================
# AWS HELPERS
# ===========================

# Verify AWS credentials
verify_aws_credentials() {
    local region="${1:-${REGION:-us-east-1}}"
    
    log_info "Verifying AWS credentials for region: $region"
    
    if dry_run_guard "Would verify AWS credentials"; then
        return 0
    fi
    
    if ! aws sts get-caller-identity --region "$region" >> "${LOG_FILE:-/dev/null}" 2>&1; then
        log_error "AWS credentials are not configured properly"
        exit 1
    fi
    
    local account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
    log_success "AWS credentials verified (Account: $account_id)"
}

# Get default VPC ID
get_default_vpc() {
    local region="${1:-${REGION:-us-east-1}}"
    
    log_info "Getting default VPC in $region" >&2
    
    if dry_run_guard "Would get default VPC" >&2; then
        echo "vpc-dry-run-12345"
        return 0
    fi
    
    local vpc_id=$(aws ec2 describe-vpcs \
        --region "$region" \
        --filters "Name=isDefault,Values=true" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>> "${LOG_FILE:-/dev/null}")
    
    if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
        log_error "No default VPC found in $region" >&2
        exit 1
    fi
    
    log_success "Using VPC: $vpc_id" >&2
    echo "$vpc_id"
}

# Auto-detect public IP
detect_public_ip() {
    log_info "Auto-detecting public IP address..." >&2
    
    local ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
               curl -s --max-time 5 icanhazip.com 2>/dev/null || \
               echo "")
    
    if [ -n "$ip" ]; then
        log_success "Detected IP: $ip" >&2
        echo "$ip"
    else
        log_warn "Could not detect public IP" >&2
        return 1
    fi
}

# ===========================
# FILE & DIRECTORY HELPERS
# ===========================

# Initialize logging directory and file
init_logging() {
    local log_dir="${LOG_DIR:-./logs}"
    local script_name="${SCRIPT_NAME:-script}"
    
    mkdir -p "$log_dir"
    
    if [ -z "${LOG_FILE:-}" ]; then
        export LOG_FILE="${log_dir}/${script_name}_$(date +%Y%m%d_%H%M%S).log"
    fi
    
    touch "$LOG_FILE"
    log_info "Logging initialized: $LOG_FILE"
}

# Create temporary file with cleanup trap
create_temp_file() {
    local prefix="${1:-temp}"
    local suffix="${2:-.txt}"
    
    local temp_file=$(mktemp "${TMPDIR:-/tmp}/${prefix}.XXXXXX${suffix}")
    
    # Register cleanup
    trap "rm -f '$temp_file' 2>/dev/null || true" EXIT
    
    echo "$temp_file"
}

# ===========================
# STATE MANAGEMENT HELPERS
# ===========================

# Source state manager if available
load_state_manager() {
    local state_manager="${STATE_MANAGER_SCRIPT:-./state_manager.sh}"
    
    if [ -f "$state_manager" ]; then
        source "$state_manager"
        log_success "State manager loaded"
        return 0
    else
        log_warn "State manager not found at $state_manager"
        return 1
    fi
}

# ===========================
# ERROR HANDLING
# ===========================

# Generic error handler
handle_error() {
    local line="${1:-unknown}"
    local cmd="${2:-unknown}"
    local script="${3:-${BASH_SOURCE[1]}}"
    
    log_error "Script failed at $script:$line"
    log_error "Failed command: $cmd"
    
    if [ -n "${LOG_FILE:-}" ]; then
        echo "" >&2
        echo "Check log file for details: $LOG_FILE" >&2
    fi
    
    exit 1
}

# Setup error trap
setup_error_trap() {
    trap 'handle_error $LINENO "$BASH_COMMAND" "${BASH_SOURCE[0]}"' ERR
}

# ===========================
# COMMAND LINE ARGUMENT PARSING
# ===========================

# Parse common command-line arguments
parse_common_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-d)
                export DRY_RUN=true
                shift
                ;;
            --region|-r)
                export REGION="$2"
                shift 2
                ;;
            --help|-h)
                return 1  # Signal to show help
                ;;
            --debug)
                export DEBUG=true
                shift
                ;;
            *)
                # Unknown option, skip it
                shift
                ;;
        esac
    done
    return 0
}

# ===========================
# CONFIRMATION HELPERS
# ===========================

# Confirm action with user
confirm_action() {
    local prompt="${1:-Are you sure?}"
    local confirm_text="${2:-yes}"
    
    if [ "${SKIP_CONFIRMATION:-false}" = "true" ]; then
        log_warn "Skipping confirmation (SKIP_CONFIRMATION=true)"
        return 0
    fi
    
    if [ "${FORCE:-false}" = "true" ]; then
        log_warn "Force mode enabled - auto-confirming in 3 seconds..."
        sleep 3
        return 0
    fi
    
    echo ""
    echo -e "${YELLOW}$prompt${NC}"
    echo -n "Type '$confirm_text' to confirm: "
    read -r response
    
    if [ "$response" != "$confirm_text" ]; then
        log_info "Action cancelled by user"
        exit 0
    fi
    
    log_info "User confirmed action"
}

# ===========================
# OUTPUT HELPERS
# ===========================

# Export environment variables to file
export_outputs() {
    local output_file="${1:-${OUTPUT_FILE:-./outputs.env}}"
    shift
    
    if dry_run_guard "Would export outputs to $output_file"; then
        return 0
    fi
    
    {
        echo "# Generated on $(date)"
        for var in "$@"; do
            echo "export $var=\"${!var}\""
        done
    } > "$output_file"
    
    log_success "Outputs exported to $output_file"
}

# Display key-value pairs
display_info() {
    local -n info_array=$1
    
    for key in "${!info_array[@]}"; do
        printf "  %-20s %s\n" "$key:" "${info_array[$key]}"
    done
}

# ===========================
# INITIALIZATION
# ===========================

# Initialize common settings
init_common() {
    # Enable strict error handling
    set -euo pipefail
    
    # Setup error handling
    setup_error_trap
    
    # Initialize logging if LOG_DIR is set
    if [ -n "${LOG_DIR:-}" ]; then
        init_logging
    fi
}

# Auto-initialize if not sourced with SKIP_INIT
if [ "${SKIP_INIT:-false}" != "true" ]; then
    init_common
fi