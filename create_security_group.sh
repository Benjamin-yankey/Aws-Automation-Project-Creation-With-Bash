#!/bin/bash

set -euo pipefail

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_NAME="$(basename "$0")"
LOG_DIR="./logs"
LOG_FILE="${LOG_DIR}/sg_creation_$(date +%Y%m%d_%H%M%S).log"
OUTPUT_FILE="${LOG_DIR}/outputs.env"
SG_NAME="${SG_NAME:-devops-sg-$(date +%s)}"
SG_DESCRIPTION="${SG_DESCRIPTION:-Security group for DevOps automation lab}"

# Environment variables with defaults
REGION="${REGION:-eu-west-1}"
DRY_RUN="${DRY_RUN:-false}"
ALLOWED_SSH_CIDR="${ALLOWED_SSH_CIDR:-}"
ALLOWED_HTTP_CIDR="${ALLOWED_HTTP_CIDR:-0.0.0.0/0}"

# Ingress rules configuration
INGRESS_RULES=(
  "22 tcp SSH ${ALLOWED_SSH_CIDR}"
  "80 tcp HTTP ${ALLOWED_HTTP_CIDR}"
)

# ===========================
# UTILITY FUNCTIONS
# ===========================

# Show usage information
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

OPTIONS:
  -r REGION          AWS region (default: eu-west-1)
  -n NAME            Security group name (default: devops-sg-TIMESTAMP)
  -s CIDR            Allowed CIDR for SSH (default: auto-detect your IP)
  -w CIDR            Allowed CIDR for HTTP (default: 0.0.0.0/0)
  -d                 Dry-run mode (don't make actual changes)
  -h                 Show this help message

EXAMPLES:
  $SCRIPT_NAME -r us-east-1
  $SCRIPT_NAME -s 10.0.0.0/8 -w 0.0.0.0/0
  DRY_RUN=true $SCRIPT_NAME
  REGION=ap-southeast-1 $SCRIPT_NAME

ENVIRONMENT VARIABLES:
  REGION             AWS region
  SG_NAME            Security group name
  ALLOWED_SSH_CIDR   CIDR for SSH access
  ALLOWED_HTTP_CIDR  CIDR for HTTP access
  DRY_RUN            Enable dry-run mode (true/false)

EOF
    exit 0
}

# Parse command-line arguments
parse_args() {
    while getopts "r:n:s:w:dh" opt; do
        case "$opt" in
            r) REGION="$OPTARG" ;;
            n) SG_NAME="$OPTARG" ;;
            s) ALLOWED_SSH_CIDR="$OPTARG" ;;
            w) ALLOWED_HTTP_CIDR="$OPTARG" ;;
            d) DRY_RUN=true ;;
            h) usage ;;
            *) 
                echo "Error: Invalid option. Use -h for help."
                exit 1
                ;;
        esac
    done
    
    # Update ingress rules with parsed values
    INGRESS_RULES=(
        "22 tcp SSH ${ALLOWED_SSH_CIDR}"
        "80 tcp HTTP ${ALLOWED_HTTP_CIDR}"
    )
}

# Initialize logging
init_logging() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    log "INFO" "Logging initialized: $LOG_FILE"
    log "INFO" "Dry-run mode: $DRY_RUN"
}

# Unified logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Print section header
print_header() {
    local title="$1"
    echo ""
    echo "=========================================="
    echo "$title"
    echo "=========================================="
    log "INFO" "=== $title ==="
}

# Print success message
print_success() {
    local message="$1"
    echo "✓ $message"
    log "SUCCESS" "$message"
}

# Print error message and exit
print_error() {
    local message="$1"
    echo "✗ ERROR: $message" >&2
    log "ERROR" "$message"
    exit 1
}

# Print info message
print_info() {
    local message="$1"
    echo "$message"
    log "INFO" "$message"
}

# Print warning message
print_warning() {
    local message="$1"
    echo "⚠ WARNING: $message"
    log "WARN" "$message"
}

# Centralized AWS CLI wrapper
aws_cmd() {
    if [ "$DRY_RUN" = true ]; then
        log "INFO" "[DRY RUN] aws --region $REGION $*"
        echo "[DRY RUN] Would execute: aws $*"
        return 0
    fi
    
    aws --region "$REGION" "$@" 2>> "$LOG_FILE"
}

# Validate CIDR format
validate_cidr() {
    local cidr="$1"
    local name="$2"
    
    if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        print_error "Invalid CIDR format for $name: $cidr"
    fi
    
    log "INFO" "Valid CIDR format for $name: $cidr"
}

# Auto-detect user's public IP for SSH access
detect_my_ip() {
    if [ -z "$ALLOWED_SSH_CIDR" ]; then
        print_info "Auto-detecting your public IP for SSH access..."
        
        local my_ip
        my_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null || echo "")
        
        if [ -n "$my_ip" ]; then
            ALLOWED_SSH_CIDR="${my_ip}/32"
            print_success "Detected IP: $ALLOWED_SSH_CIDR"
        else
            print_warning "Could not detect IP. SSH will be restricted to 10.0.0.0/8 (change with -s flag)"
            ALLOWED_SSH_CIDR="10.0.0.0/8"
        fi
        
        # Update ingress rules
        INGRESS_RULES=(
            "22 tcp SSH ${ALLOWED_SSH_CIDR}"
            "80 tcp HTTP ${ALLOWED_HTTP_CIDR}"
        )
    fi
}

# Validate AWS CLI is installed
validate_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
    fi
    print_success "AWS CLI is installed"
}

# Verify AWS credentials
verify_credentials() {
    log "INFO" "Verifying AWS credentials"
    
    if ! aws_cmd sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials are not configured properly"
    fi
    
    print_success "AWS credentials verified for region: $REGION"
}

# Get default VPC ID
get_vpc_id() {
    log "INFO" "Getting default VPC in $REGION"
    
    if [ "$DRY_RUN" = true ]; then
        VPC_ID="vpc-dry-run-12345"
        print_info "[DRY RUN] Would use VPC: $VPC_ID"
        return 0
    fi
    
    VPC_ID=$(aws_cmd ec2 describe-vpcs \
        --filters "Name=isDefault,Values=true" \
        --query 'Vpcs[0].VpcId' \
        --output text)
    
    if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
        print_error "No default VPC found in $REGION"
    fi
    
    print_success "Using VPC: $VPC_ID"
}

# Create security group
create_security_group() {
    log "INFO" "Creating security group: $SG_NAME"
    
    if [ "$DRY_RUN" = true ]; then
        SG_ID="sg-dry-run-67890"
        print_info "[DRY RUN] Would create security group: $SG_ID"
        return 0
    fi
    
    SG_ID=$(aws_cmd ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "$SG_DESCRIPTION" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' \
        --output text)
    
    if [ -z "$SG_ID" ]; then
        print_error "Failed to create security group"
    fi
    
    print_success "Security group created: $SG_ID"
}

# Tag security group
tag_security_group() {
    log "INFO" "Tagging security group"
    
    aws_cmd ec2 create-tags \
        --resources "$SG_ID" \
        --tags Key=Name,Value="$SG_NAME" \
               Key=Project,Value=AutomationLab \
               Key=Environment,Value=Development \
               Key=ManagedBy,Value=BashScript \
               Key=CreatedAt,Value="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    
    print_success "Tags applied to security group"
}

# Check if ingress rule exists
rule_exists() {
    local port="$1"
    
    if [ "$DRY_RUN" = true ]; then
        return 1  # Assume rule doesn't exist in dry-run
    fi
    
    aws_cmd ec2 describe-security-groups \
        --group-ids "$SG_ID" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`${port}\`]" \
        --output text 2>/dev/null | grep -q .
}

# Add ingress rule (idempotent)
add_ingress_rule() {
    local port="$1"
    local protocol="$2"
    local description="$3"
    local cidr="$4"
    
    # Skip if CIDR is empty
    if [ -z "$cidr" ]; then
        print_warning "Skipping $description rule (no CIDR specified)"
        return 0
    fi
    
    # Validate CIDR format
    validate_cidr "$cidr" "$description"
    
    log "INFO" "Adding ingress rule: $protocol/$port from $cidr"
    
    # Check if rule already exists
    if rule_exists "$port"; then
        print_info "$description rule already exists for port $port"
        return 0
    fi
    
    if aws_cmd ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol "$protocol" \
        --port "$port" \
        --cidr "$cidr"; then
        print_success "$description rule added ($cidr:$port)"
    else
        print_error "Failed to add $description rule"
    fi
}

# Process all ingress rules
process_ingress_rules() {
    print_info "Adding security group ingress rules..."
    
    for rule in "${INGRESS_RULES[@]}"; do
        read -r port protocol desc cidr <<< "$rule"
        add_ingress_rule "$port" "$protocol" "$desc" "$cidr"
    done
}

# Display security group information
display_summary() {
    log "INFO" "Generating summary"
    
    print_header "Security Group Created Successfully!"
    
    cat <<EOF
Security Group ID:   $SG_ID
Security Group Name: $SG_NAME
VPC ID:              $VPC_ID
Region:              $REGION
Dry-Run Mode:        $DRY_RUN

Ingress Rules:
EOF

    for rule in "${INGRESS_RULES[@]}"; do
        read -r port protocol desc cidr <<< "$rule"
        if [ -n "$cidr" ]; then
            echo "  - $desc ($protocol/$port) from $cidr"
        fi
    done
    
    echo "=========================================="
    
    if [ "$DRY_RUN" = false ]; then
        echo ""
        echo "Detailed Security Group Rules:"
        aws_cmd ec2 describe-security-groups \
            --group-ids "$SG_ID" \
            --query 'SecurityGroups[0].IpPermissions' \
            --output table
    fi
    
    echo ""
    echo "Log file: $LOG_FILE"
    
    if [ "$DRY_RUN" = false ]; then
        echo "Outputs:  $OUTPUT_FILE"
    fi
}

# Export outputs for CI/CD
export_outputs() {
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] Would export outputs to $OUTPUT_FILE"
        return 0
    fi
    
    cat > "$OUTPUT_FILE" <<EOF
# Generated by $SCRIPT_NAME on $(date)
export SG_ID="$SG_ID"
export SG_NAME="$SG_NAME"
export VPC_ID="$VPC_ID"
export REGION="$REGION"
EOF
    
    print_success "Outputs exported to $OUTPUT_FILE"
    log "INFO" "Outputs: SG_ID=$SG_ID, VPC_ID=$VPC_ID, REGION=$REGION"
}

# Cleanup on error
cleanup_on_error() {
    local line="${1:-unknown}"
    local cmd="${2:-unknown}"
    
    log "ERROR" "Script failed at line $line: $cmd"
    echo "" >&2
    echo "✗ Script failed at line $line" >&2
    echo "  Command: $cmd" >&2
    
    if [ -n "${SG_ID:-}" ] && [ "$SG_ID" != "sg-dry-run-67890" ]; then
        echo "  Attempting cleanup..." >&2
        aws_cmd ec2 delete-security-group \
            --group-id "$SG_ID" 2>/dev/null || true
        log "INFO" "Cleanup: Deleted security group $SG_ID"
    fi
    
    echo "" >&2
    echo "Check log file for details: $LOG_FILE" >&2
    exit 1
}

# ===========================
# MAIN EXECUTION
# ===========================
main() {
    # Parse command-line arguments
    parse_args "$@"
    
    # Set up error trap with line number and command
    trap 'cleanup_on_error $LINENO "$BASH_COMMAND"' ERR
    
    # Initialize
    init_logging
    print_header "Security Group Creation Script"
    
    # Validate prerequisites
    validate_aws_cli
    verify_credentials
    
    # Auto-detect IP for SSH if not specified
    detect_my_ip
    
    # Display configuration
    print_info "Configuration:"
    print_info "  Region: $REGION"
    print_info "  SG Name: $SG_NAME"
    print_info "  SSH CIDR: ${ALLOWED_SSH_CIDR:-none}"
    print_info "  HTTP CIDR: ${ALLOWED_HTTP_CIDR:-none}"
    echo ""
    
    # Create security group
    print_info "Step 1: Getting default VPC..."
    get_vpc_id
    
    print_info "Step 2: Creating security group..."
    create_security_group
    
    print_info "Step 3: Adding tags..."
    tag_security_group
    
    print_info "Step 4: Configuring ingress rules..."
    process_ingress_rules
    
    print_info "Step 5: Finalizing..."
    display_summary
    export_outputs
    
    log "SUCCESS" "Security group creation completed successfully"
    print_success "All operations completed!"
}

# Run main function
main "$@"