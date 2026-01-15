#!/usr/bin/env bash

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="create_security_group.sh"
LOG_DIR="./logs"
export LOG_FILE="${LOG_DIR}/sg_creation_$(date +%Y%m%d_%H%M%S).log"

# Source common utilities and state manager
source "${SCRIPT_DIR}/common_utils.sh"
source "${SCRIPT_DIR}/state_manager.sh"

# Default configuration
SG_NAME="${SG_NAME:-devops-sg-$(date +%s)}"
SG_DESCRIPTION="${SG_DESCRIPTION:-Security group for DevOps automation lab}"
REGION="${REGION:-eu-west-1}"
DRY_RUN="${DRY_RUN:-false}"
ALLOWED_SSH_CIDR="${ALLOWED_SSH_CIDR:-}"
ALLOWED_HTTP_CIDR="${ALLOWED_HTTP_CIDR:-0.0.0.0/0}"

# Resource variables
VPC_ID=""
SG_ID=""

# Ingress rules array
declare -a INGRESS_RULES

# ===========================
# RULE MANAGEMENT
# ===========================

initialize_ingress_rules() {
    INGRESS_RULES=(
        "22|tcp|SSH|${ALLOWED_SSH_CIDR}"
        "80|tcp|HTTP|${ALLOWED_HTTP_CIDR}"
    )
}

parse_rule() {
    local rule="$1"
    IFS='|' read -r port protocol desc cidr <<< "$rule"
    
    echo "$port" "$protocol" "$desc" "$cidr"
}

rule_exists() {
    local port="$1"
    
    if dry_run_guard "Would check if rule exists for port $port"; then
        return 1
    fi
    
    aws ec2 describe-security-groups \
        --region "$REGION" \
        --group-ids "$SG_ID" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`${port}\`]" \
        --output text 2>> "$LOG_FILE" | grep -q .
}

add_ingress_rule() {
    local port="$1"
    local protocol="$2"
    local description="$3"
    local cidr="$4"
    
    # Skip if CIDR is empty
    if [ -z "$cidr" ]; then
        log_warn "Skipping $description rule (no CIDR specified)"
        return 0
    fi
    
    # Validate CIDR
    validate_cidr "$cidr" "$description"
    
    log_info "Adding $description rule: $protocol/$port from $cidr"
    
    # Check if rule already exists
    if rule_exists "$port"; then
        log_info "$description rule already exists for port $port"
        return 0
    fi
    
    if dry_run_guard "Would add ingress rule: $protocol/$port from $cidr"; then
        return 0
    fi
    
    aws ec2 authorize-security-group-ingress \
        --region "$REGION" \
        --group-id "$SG_ID" \
        --protocol "$protocol" \
        --port "$port" \
        --cidr "$cidr" \
        2>> "$LOG_FILE"
    
    log_success "$description rule added ($cidr:$port)"
}

process_all_ingress_rules() {
    log_info "Configuring security group ingress rules..."
    
    for rule in "${INGRESS_RULES[@]}"; do
        read -r port protocol desc cidr <<< "$(parse_rule "$rule")"
        add_ingress_rule "$port" "$protocol" "$desc" "$cidr"
    done
}

# ===========================
# SECURITY GROUP OPERATIONS
# ===========================

create_security_group() {
    log_info "Creating security group: $SG_NAME"
    
    if dry_run_guard "Would create security group $SG_NAME in VPC $VPC_ID"; then
        SG_ID="sg-dry-run-67890"
        log_info "Security group ID: $SG_ID"
        return 0
    fi
    
    SG_ID=$(aws ec2 create-security-group \
        --region "$REGION" \
        --group-name "$SG_NAME" \
        --description "$SG_DESCRIPTION" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' \
        --output text 2>> "$LOG_FILE")
    
    if [ -z "$SG_ID" ]; then
        log_error "Failed to create security group"
        exit 1
    fi
    
    # Register in state
    add_security_group "$SG_ID" "$SG_NAME" "$VPC_ID"
    
    log_success "Security group created: $SG_ID"
}

tag_security_group() {
    log_info "Tagging security group"
    
    if dry_run_guard "Would tag security group $SG_ID"; then
        return 0
    fi
    
    aws ec2 create-tags \
        --region "$REGION" \
        --resources "$SG_ID" \
        --tags Key=Name,Value="$SG_NAME" \
               Key=Project,Value=AutomationLab \
               Key=Environment,Value=Development \
               Key=ManagedBy,Value=BashScript \
               Key=CreatedAt,Value="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        2>> "$LOG_FILE"
    
    log_success "Tags applied to security group"
}

# ===========================
# IP DETECTION
# ===========================

auto_detect_ssh_cidr() {
    if [ -n "$ALLOWED_SSH_CIDR" ]; then
        log_info "Using provided SSH CIDR: $ALLOWED_SSH_CIDR"
        return 0
    fi
    
    log_info "Auto-detecting public IP for SSH access..."
    
    local my_ip=$(detect_public_ip)
    
    if [ -n "$my_ip" ]; then
        ALLOWED_SSH_CIDR="${my_ip}/32"
        log_success "Detected IP: $ALLOWED_SSH_CIDR"
    else
        ALLOWED_SSH_CIDR="10.0.0.0/8"
        log_warn "Could not detect IP. Using fallback: $ALLOWED_SSH_CIDR"
    fi
}

# ===========================
# OUTPUT
# ===========================

display_summary() {
    print_header "Security Group Created Successfully!"
    
    cat <<EOF
Security Group ID:   $SG_ID
Security Group Name: $SG_NAME
VPC ID:              $VPC_ID
Region:              $REGION

Ingress Rules:
EOF

    for rule in "${INGRESS_RULES[@]}"; do
        read -r port protocol desc cidr <<< "$(parse_rule "$rule")"
        if [ -n "$cidr" ]; then
            echo "  - $desc ($protocol/$port) from $cidr"
        fi
    done
    
    echo "=========================================="
    
    if [ "$DRY_RUN" != "true" ]; then
        echo ""
        echo "Detailed Security Group Rules:"
        aws ec2 describe-security-groups \
            --region "$REGION" \
            --group-ids "$SG_ID" \
            --query 'SecurityGroups[0].IpPermissions' \
            --output table 2>> "$LOG_FILE" || echo "(Could not retrieve details)"
    fi
    
    echo ""
    echo "Log file: $LOG_FILE"
}

cleanup_on_error() {
    log_error "Script failed, attempting cleanup..."
    
    if [ "${DRY_RUN:-false}" = "true" ]; then
        log_info "Dry-run mode - no actual cleanup needed"
        return
    fi
    
    if [ -n "${SG_ID:-}" ] && [ "$SG_ID" != "sg-dry-run-67890" ]; then
        log_info "Deleting security group: $SG_ID"
        aws ec2 delete-security-group \
            --region "$REGION" \
            --group-id "$SG_ID" \
            2>> "$LOG_FILE" || true
        remove_security_group "$SG_ID" 2>/dev/null || true
    fi
}

# ===========================
# MAIN EXECUTION
# ===========================
main() {
    # Setup error handling with cleanup
    trap cleanup_on_error ERR
    
    # Initialize
    print_header "Security Group Creation Script"
    
    # Load existing state
    load_state
    
    # Validate prerequisites
    require_command "aws" "Install from: https://aws.amazon.com/cli/"
    require_command "jq" "Install from: https://stedolan.github.io/jq/"
    
    # Verify credentials
    verify_aws_credentials "$REGION"
    
    # Auto-detect IP for SSH
    auto_detect_ssh_cidr
    
    # Initialize ingress rules with detected/configured CIDRs
    initialize_ingress_rules
    
    # Display configuration
    log_info "Configuration:"
    log_info "  Region: $REGION"
    log_info "  SG Name: $SG_NAME"
    log_info "  SSH CIDR: ${ALLOWED_SSH_CIDR:-none}"
    log_info "  HTTP CIDR: ${ALLOWED_HTTP_CIDR:-none}"
    echo ""
    
    # Get VPC
    log_info "[1/4] Getting default VPC..."
    VPC_ID=$(get_default_vpc "$REGION")
    
    # Create security group
    log_info "[2/4] Creating security group..."
    create_security_group
    
    # Tag security group
    log_info "[3/4] Adding tags..."
    tag_security_group
    
    # Configure ingress rules
    log_info "[4/4] Configuring ingress rules..."
    process_all_ingress_rules
    
    # Display results
    echo ""
    display_summary
    
    log_success "Security group creation completed successfully"
}

# Run main function
main "$@"