#!/bin/bash

# Script: create_security_group.sh
# Purpose: Create and configure security group with logging
# Author: DevOps Automation Lab
# Date: December 2025

set -euo pipefail

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_NAME="create_security_group.sh"
LOG_DIR="./logs"
LOG_FILE="${LOG_DIR}/sg_creation_$(date +%Y%m%d_%H%M%S).log"
SG_NAME="devops-sg-$(date +%s)"
SG_DESCRIPTION="Security group for DevOps automation lab"

# ===========================
# UTILITY FUNCTIONS
# ===========================

# Initialize logging
init_logging() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    log "INFO" "Logging initialized: $LOG_FILE"
}

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Print section header
print_header() {
    local title="$1"
    echo ""
    echo "==========================================" | tee -a "$LOG_FILE"
    echo "$title" | tee -a "$LOG_FILE"
    echo "==========================================" | tee -a "$LOG_FILE"
}

# Print success message
print_success() {
    local message="$1"
    echo "✓ $message" | tee -a "$LOG_FILE"
    log "SUCCESS" "$message"
}

# Print error message and exit
print_error() {
    local message="$1"
    echo "✗ ERROR: $message" | tee -a "$LOG_FILE"
    log "ERROR" "$message"
    exit 1
}

# Print info message
print_info() {
    local message="$1"
    echo "$message" | tee -a "$LOG_FILE"
    log "INFO" "$message"
}

# Validate AWS CLI is installed
validate_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
    fi
    print_success "AWS CLI is installed"
}

# Get AWS region from user
get_region() {
    local default_region="eu-west-1"
    
    echo ""
    echo "Available AWS Regions:"
    echo "  1. eu-west-1 (Ireland)"
    echo "  2. us-east-1 (N. Virginia)"
    echo "  3. us-west-2 (Oregon)"
    echo "  4. ap-southeast-1 (Singapore)"
    echo "  5. Custom region"
    echo ""
    
    read -p "Enter region number or press Enter for eu-west-1 [$default_region]: " region_choice
    
    case "$region_choice" in
        1|"") REGION="eu-west-1" ;;
        2) REGION="us-east-1" ;;
        3) REGION="us-west-2" ;;
        4) REGION="ap-southeast-1" ;;
        5)
            read -p "Enter custom region: " REGION
            ;;
        *)
            REGION="$default_region"
            ;;
    esac
    
    log "INFO" "Selected region: $REGION"
    print_info "Selected region: $REGION"
}

# Verify AWS credentials
verify_credentials() {
    log "INFO" "Verifying AWS credentials"
    
    if ! aws sts get-caller-identity --region "$REGION" &>> "$LOG_FILE"; then
        print_error "AWS credentials are not configured properly"
    fi
    
    print_success "AWS credentials verified"
}

# Get default VPC ID
get_vpc_id() {
    log "INFO" "Getting default VPC"
    
    VPC_ID=$(aws ec2 describe-vpcs \
        --region "$REGION" \
        --filters "Name=isDefault,Values=true" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>> "$LOG_FILE")
    
    if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
        print_error "No default VPC found in $REGION"
    fi
    
    print_success "Using VPC: $VPC_ID"
}

# Create security group
create_security_group() {
    log "INFO" "Creating security group: $SG_NAME"
    
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "$SG_DESCRIPTION" \
        --vpc-id "$VPC_ID" \
        --region "$REGION" \
        --query 'GroupId' \
        --output text 2>> "$LOG_FILE")
    
    if [ -z "$SG_ID" ]; then
        print_error "Failed to create security group"
    fi
    
    print_success "Security group created: $SG_ID"
}

# Tag security group
tag_security_group() {
    log "INFO" "Tagging security group"
    
    aws ec2 create-tags \
        --resources "$SG_ID" \
        --tags Key=Name,Value="$SG_NAME" \
               Key=Project,Value=AutomationLab \
               Key=Environment,Value=Development \
               Key=ManagedBy,Value=BashScript \
        --region "$REGION" 2>> "$LOG_FILE"
    
    print_success "Tags applied to security group"
}

# Add ingress rule
add_ingress_rule() {
    local port="$1"
    local protocol="$2"
    local description="$3"
    
    log "INFO" "Adding ingress rule: $protocol/$port"
    
    if aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol "$protocol" \
        --port "$port" \
        --cidr 0.0.0.0/0 \
        --region "$REGION" 2>> "$LOG_FILE"; then
        print_success "$description rule added (0.0.0.0/0:$port)"
    else
        print_error "Failed to add $description rule"
    fi
}

# Display security group rules
display_rules() {
    log "INFO" "Retrieving security group rules"
    
    print_header "Security Group Created Successfully!"
    
    cat <<EOF | tee -a "$LOG_FILE"
Security Group ID:   $SG_ID
Security Group Name: $SG_NAME
VPC ID:              $VPC_ID
Region:              $REGION

Ingress Rules:
  - SSH  (TCP/22)  from 0.0.0.0/0
  - HTTP (TCP/80)  from 0.0.0.0/0
==========================================
EOF

    echo ""
    echo "Detailed Security Group Rules:" | tee -a "$LOG_FILE"
    aws ec2 describe-security-groups \
        --group-ids "$SG_ID" \
        --region "$REGION" \
        --query 'SecurityGroups[0].IpPermissions' \
        --output table 2>> "$LOG_FILE" | tee -a "$LOG_FILE"
    
    echo ""
    echo "Log file saved to: $LOG_FILE" | tee -a "$LOG_FILE"
}

# Cleanup on error
cleanup_on_error() {
    log "ERROR" "Script failed. Cleaning up..."
    
    if [ -n "${SG_ID:-}" ]; then
        aws ec2 delete-security-group \
            --group-id "$SG_ID" \
            --region "$REGION" 2>> "$LOG_FILE" || true
    fi
    
    print_error "Script execution failed. Check log file: $LOG_FILE"
}

# ===========================
# MAIN EXECUTION
# ===========================
main() {
    # Set up error trap
    trap cleanup_on_error ERR
    
    # Initialize
    init_logging
    print_header "Security Group Creation Script"
    
    # Validate and setup
    validate_aws_cli
    get_region
    verify_credentials
    
    # Create security group
    print_info "[1/5] Getting default VPC..."
    get_vpc_id
    
    print_info "[2/5] Creating security group..."
    create_security_group
    
    print_info "[3/5] Adding tags..."
    tag_security_group
    
    print_info "[4/5] Adding SSH rule (port 22)..."
    add_ingress_rule "22" "tcp" "SSH"
    
    print_info "[4/5] Adding HTTP rule (port 80)..."
    add_ingress_rule "80" "tcp" "HTTP"
    
    print_info "[5/5] Finalizing..."
    display_rules
    
    log "SUCCESS" "Security group creation completed successfully"
}

# Run main function
main "$@"