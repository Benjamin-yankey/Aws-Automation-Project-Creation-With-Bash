#!/bin/bash

# Script: create_ec2.sh
# Purpose: Automate EC2 instance creation with logging and user input
# Author: DevOps Automation Lab
# Date: December 2025

set -euo pipefail

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_NAME="create_ec2.sh"
LOG_DIR="./logs"
LOG_FILE="${LOG_DIR}/ec2_creation_$(date +%Y%m%d_%H%M%S).log"
INSTANCE_TYPE="t3.micro"
KEY_NAME="devops-keypair-$(date +%s)"
INSTANCE_NAME="AutomationLab-EC2"

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

# Get AMI ID for the selected region
get_ami_id() {
    local region="$1"
    
    log "INFO" "Fetching latest Amazon Linux 2023 AMI for $region"
    
    # Get the latest Amazon Linux 2023 AMI
    AMI_ID=$(aws ec2 describe-images \
        --region "$region" \
        --owners amazon \
        --filters "Name=name,Values=al2023-ami-2023.*-x86_64" \
                  "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text 2>> "$LOG_FILE")
    
    if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
        print_error "Could not find suitable AMI in region $region"
    fi
    
    print_success "Found AMI: $AMI_ID"
}

# Verify AWS credentials
verify_credentials() {
    log "INFO" "Verifying AWS credentials"
    
    if ! aws sts get-caller-identity --region "$REGION" &> "$LOG_FILE"; then
        print_error "AWS credentials are not configured properly"
    fi
    
    print_success "AWS credentials verified"
}

# Create EC2 key pair
create_key_pair() {
    log "INFO" "Creating EC2 key pair: $KEY_NAME"
    
    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --region "$REGION" \
        --query 'KeyMaterial' \
        --output text > "${KEY_NAME}.pem" 2>> "$LOG_FILE"
    
    chmod 400 "${KEY_NAME}.pem"
    print_success "Key pair created: ${KEY_NAME}.pem"
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

# Get default security group
get_security_group() {
    log "INFO" "Getting default security group"
    
    SECURITY_GROUP=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>> "$LOG_FILE")
    
    print_success "Using security group: $SECURITY_GROUP"
}

# Launch EC2 instance
launch_instance() {
    log "INFO" "Launching EC2 instance ($INSTANCE_TYPE)"
    
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SECURITY_GROUP" \
        --region "$REGION" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=AutomationLab},{Key=Environment,Value=Development},{Key=ManagedBy,Value=BashScript}]" \
        --query 'Instances[0].InstanceId' \
        --output text 2>> "$LOG_FILE")
    
    if [ -z "$INSTANCE_ID" ]; then
        print_error "Failed to launch instance"
    fi
    
    print_success "Instance launched: $INSTANCE_ID"
}

# Wait for instance to be running
wait_for_instance() {
    log "INFO" "Waiting for instance to enter running state"
    print_info "⏳ This may take 30-60 seconds..."
    
    if ! aws ec2 wait instance-running \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" 2>> "$LOG_FILE"; then
        print_error "Instance failed to reach running state"
    fi
    
    print_success "Instance is now running"
}

# Get instance details
get_instance_details() {
    log "INFO" "Retrieving instance details"
    
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text 2>> "$LOG_FILE")
    
    PRIVATE_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text 2>> "$LOG_FILE")
    
    print_success "Retrieved instance details"
}

# Display results
display_results() {
    print_header "EC2 Instance Created Successfully!"
    
    cat <<EOF | tee -a "$LOG_FILE"
Instance ID:     $INSTANCE_ID
Instance Type:   $INSTANCE_TYPE
Region:          $REGION
AMI ID:          $AMI_ID
Public IP:       $PUBLIC_IP
Private IP:      $PRIVATE_IP
Key Pair:        ${KEY_NAME}.pem
VPC ID:          $VPC_ID
==========================================

To connect via SSH, use:
  ssh -i ${KEY_NAME}.pem ec2-user@$PUBLIC_IP

Log file saved to: $LOG_FILE
EOF
}

# Cleanup on error
cleanup_on_error() {
    log "ERROR" "Script failed. Cleaning up..."
    
    if [ -n "${KEY_NAME:-}" ]; then
        aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$REGION" 2>> "$LOG_FILE" || true
        rm -f "${KEY_NAME}.pem" 2>> "$LOG_FILE" || true
    fi
    
    if [ -n "${INSTANCE_ID:-}" ]; then
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" 2>> "$LOG_FILE" || true
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
    print_header "EC2 Instance Creation Script"
    
    # Validate and setup
    validate_aws_cli
    get_region
    get_ami_id "$REGION"
    verify_credentials
    
    # Create resources
    print_info "[1/7] Creating EC2 key pair..."
    create_key_pair
    
    print_info "[2/7] Getting default VPC..."
    get_vpc_id
    
    print_info "[3/7] Getting security group..."
    get_security_group
    
    print_info "[4/7] Launching EC2 instance..."
    launch_instance
    
    print_info "[5/7] Waiting for instance to be running..."
    wait_for_instance
    
    print_info "[6/7] Retrieving instance details..."
    get_instance_details
    
    print_info "[7/7] Finalizing..."
    display_results
    
    log "SUCCESS" "EC2 instance creation completed successfully"
}

# Run main function
main "$@"