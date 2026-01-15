#!/usr/bin/env bash

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="create_ec2.sh"
LOG_DIR="./logs"

# Determine lib directory location
LIB_DIR="${SCRIPT_DIR}/lib"

# Source common utilities and state manager
if [ -f "${LIB_DIR}/common_utils.sh" ]; then
    source "${LIB_DIR}/common_utils.sh"
else
    echo "Error: common_utils.sh not found in ${LIB_DIR}"
    echo "Current directory: $(pwd)"
    echo "Script directory: ${SCRIPT_DIR}"
    echo "Looking for: ${LIB_DIR}/common_utils.sh"
    exit 1
fi

if [ -f "${SCRIPT_DIR}/state_manager.sh" ]; then
    source "${SCRIPT_DIR}/state_manager.sh"
elif [ -f "${LIB_DIR}/state_manager.sh" ]; then
    source "${LIB_DIR}/state_manager.sh"
else
    echo "Error: state_manager.sh not found in ${SCRIPT_DIR} or ${LIB_DIR}"
    echo "Current directory: $(pwd)"
    echo "Script directory: ${SCRIPT_DIR}"
    echo "Lib directory: ${LIB_DIR}"
    exit 1
fi

export LOG_FILE="${LOG_DIR}/ec2_creation_$(date +%Y%m%d_%H%M%S).log"

# Default configuration
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
KEY_NAME="${KEY_NAME:-devops-keypair-$(date +%s)}"
INSTANCE_NAME="${INSTANCE_NAME:-AutomationLab-EC2}"
REGION="${REGION:-eu-west-1}"
DRY_RUN="${DRY_RUN:-false}"

# Resource variables
AMI_ID=""
VPC_ID=""
SECURITY_GROUP=""
INSTANCE_ID=""

# ===========================
# USAGE
# ===========================

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Create an EC2 instance with automated configuration.

OPTIONS:
  -d, --dry-run              Preview mode - no actual changes
  -r, --region REGION        AWS region (default: eu-west-1)
  -t, --instance-type TYPE   Instance type (default: t3.micro)
  -n, --name NAME            Instance name (default: AutomationLab-EC2)
  -h, --help                 Show this help message

EXAMPLES:
  $SCRIPT_NAME --dry-run
  $SCRIPT_NAME --region us-east-1 --instance-type t3.small
  
ENVIRONMENT VARIABLES:
  DRY_RUN                    Enable dry-run mode (true/false)
  REGION                     AWS region
  INSTANCE_TYPE              EC2 instance type
  INSTANCE_NAME              Instance name tag
  KEY_NAME                   Key pair name

EOF
    exit 0
}

# ===========================
# ARGUMENT PARSING
# ===========================

parse_args() {
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
            --instance-type|-t)
                export INSTANCE_TYPE="$2"
                shift 2
                ;;
            --name|-n)
                export INSTANCE_NAME="$2"
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# ===========================
# RESOURCE CREATION FUNCTIONS
# ===========================

get_ami_id() {
    local region="$1"
    
    log_info "Fetching latest Amazon Linux 2023 AMI for $region"
    
    if dry_run_guard "Would fetch AMI for $region"; then
        AMI_ID="ami-dry-run-12345"
        log_info "Using dry-run AMI: $AMI_ID"
        return 0
    fi
    
    AMI_ID=$(aws ec2 describe-images \
        --region "$region" \
        --owners amazon \
        --filters "Name=name,Values=al2023-ami-2023.*-x86_64" \
                  "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text 2>> "$LOG_FILE")
    
    if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
        log_error "Could not find suitable AMI in region $region"
        exit 1
    fi
    
    log_success "Found AMI: $AMI_ID"
}

create_key_pair() {
    log_info "Creating EC2 key pair: $KEY_NAME"
    
    if dry_run_guard "Would create key pair $KEY_NAME"; then
        log_info "Key pair would be saved to: ${KEY_NAME}.pem"
        return 0
    fi
    
    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --region "$REGION" \
        --query 'KeyMaterial' \
        --output text > "${KEY_NAME}.pem" 2>> "$LOG_FILE"
    
    chmod 400 "${KEY_NAME}.pem"
    
    # Register in state
    add_key_pair "$KEY_NAME" "$REGION"
    
    log_success "Key pair created: ${KEY_NAME}.pem"
}

get_default_security_group() {
    log_info "Getting default security group"
    
    if dry_run_guard "Would get default security group"; then
        SECURITY_GROUP="sg-dry-run-12345"
        log_info "Using dry-run security group: $SECURITY_GROUP"
        return 0
    fi
    
    SECURITY_GROUP=$(aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>> "$LOG_FILE")
    
    if [ -z "$SECURITY_GROUP" ] || [ "$SECURITY_GROUP" = "None" ]; then
        log_error "Could not find default security group"
        exit 1
    fi
    
    log_success "Using security group: $SECURITY_GROUP"
}

launch_instance() {
    log_info "Launching EC2 instance ($INSTANCE_TYPE)"
    
    if dry_run_guard "Would launch EC2 instance"; then
        INSTANCE_ID="i-dry-run-67890"
        log_info "Instance would be created with ID: $INSTANCE_ID"
        return 0
    fi
    
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
        log_error "Failed to launch instance"
        exit 1
    fi
    
    # Register in state
    local sg_json="[\"$SECURITY_GROUP\"]"
    add_ec2_instance "$INSTANCE_ID" "$INSTANCE_NAME" "$INSTANCE_TYPE" "$KEY_NAME" "$sg_json" "pending"
    
    log_success "Instance launched: $INSTANCE_ID"
}

wait_for_instance() {
    log_info "Waiting for instance to enter running state"
    
    if dry_run_guard "Would wait for instance $INSTANCE_ID"; then
        return 0
    fi
    
    log_info "⏳ This may take 30-60 seconds..."
    
    if ! aws ec2 wait instance-running \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" 2>> "$LOG_FILE"; then
        log_error "Instance failed to reach running state"
        exit 1
    fi
    
    log_success "Instance is now running"
}

get_instance_details() {
    log_info "Retrieving instance details"
    
    if dry_run_guard "Would retrieve instance details"; then
        PUBLIC_IP="203.0.113.1"
        PRIVATE_IP="10.0.1.10"
        log_info "Public IP: $PUBLIC_IP"
        log_info "Private IP: $PRIVATE_IP"
        return 0
    fi
    
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
    
    log_success "Retrieved instance details"
}

# ===========================
# OUTPUT & CLEANUP
# ===========================

display_results() {
    print_header "EC2 Instance Created Successfully!"
    
    cat <<EOF
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

Log file: $LOG_FILE
EOF
}

cleanup_on_error() {
    log_error "Script failed, attempting cleanup..."
    
    if [ "${DRY_RUN:-false}" = "true" ]; then
        log_info "Dry-run mode - no actual cleanup needed"
        return
    fi
    
    if [ -n "${KEY_NAME:-}" ]; then
        aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$REGION" 2>> "$LOG_FILE" || true
        rm -f "${KEY_NAME}.pem" 2>> "$LOG_FILE" || true
        remove_key_pair "$KEY_NAME" 2>/dev/null || true
    fi
    
    if [ -n "${INSTANCE_ID:-}" ]; then
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" 2>> "$LOG_FILE" || true
        remove_ec2_instance "$INSTANCE_ID" 2>/dev/null || true
    fi
}

# ===========================
# MAIN EXECUTION
# ===========================
main() {
    # Parse command-line arguments first
    parse_args "$@"
    
    # Setup error handling with cleanup
    trap cleanup_on_error ERR
    
    # Initialize
    print_header "EC2 Instance Creation Script"
    
    # Load existing state
    load_state
    
    # Validate prerequisites
    require_command "aws" "Install from: https://aws.amazon.com/cli/"
    require_command "jq" "Install from: https://stedolan.github.io/jq/"
    
    # Verify credentials
    verify_aws_credentials "$REGION"
    
    # Get AMI
    log_info "[1/7] Fetching AMI..."
    get_ami_id "$REGION"
    
    # Get VPC
    log_info "[2/7] Getting default VPC..."
    VPC_ID=$(get_default_vpc "$REGION")
    
    # Get security group
    log_info "[3/7] Getting security group..."
    get_default_security_group
    
    # Create key pair
    log_info "[4/7] Creating EC2 key pair..."
    create_key_pair
    
    # Launch instance
    log_info "[5/7] Launching EC2 instance..."
    launch_instance
    
    # Wait for running state
    log_info "[6/7] Waiting for instance..."
    wait_for_instance
    
    # Get details
    log_info "[7/7] Retrieving details..."
    get_instance_details
    
    # Display results
    display_results
    
    log_success "EC2 instance creation completed successfully"
}

# Run main function
main "$@"