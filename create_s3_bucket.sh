#!/bin/bash

# Script: create_s3_bucket.sh
# Purpose: Create S3 bucket with versioning and logging
# Author: DevOps Automation Lab
# Date: December 2025

set -euo pipefail

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_NAME="create_s3_bucket.sh"
LOG_DIR="./logs"
LOG_FILE="${LOG_DIR}/s3_creation_$(date +%Y%m%d_%H%M%S).log"
BUCKET_NAME="devops-automation-lab-$(date +%s)-$RANDOM"
SAMPLE_FILE="welcome.txt"

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

# Print warning message
print_warning() {
    local message="$1"
    echo "⚠ WARNING: $message" | tee -a "$LOG_FILE"
    log "WARNING" "$message"
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

# Create sample file
create_sample_file() {
    log "INFO" "Creating sample file: $SAMPLE_FILE"
    
    cat > "$SAMPLE_FILE" << EOF
Welcome to DevOps Automation Lab!
==================================

This file was automatically uploaded by create_s3_bucket.sh script.

Bucket: $BUCKET_NAME
Region: $REGION
Created: $(date)

Project: AWS Resource Automation
Purpose: Learning AWS CLI and Bash scripting

---
This is a demonstration file showing:
- Automated S3 bucket creation
- File upload capabilities
- Versioning management
- Tagging and organization
EOF

    print_success "Sample file created: $SAMPLE_FILE"
}

# Create S3 bucket
create_bucket() {
    log "INFO" "Creating S3 bucket: $BUCKET_NAME"
    
    # us-east-1 doesn't need LocationConstraint
    if [ "$REGION" == "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$REGION" &>> "$LOG_FILE"
    else
        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION" &>> "$LOG_FILE"
    fi
    
    if [ $? -eq 0 ]; then
        print_success "Bucket created: $BUCKET_NAME"
    else
        print_error "Failed to create bucket"
    fi
}

# Tag bucket
tag_bucket() {
    log "INFO" "Adding tags to bucket"
    
    aws s3api put-bucket-tagging \
        --bucket "$BUCKET_NAME" \
        --tagging "TagSet=[
            {Key=Project,Value=AutomationLab},
            {Key=Environment,Value=Development},
            {Key=ManagedBy,Value=BashScript},
            {Key=CreatedBy,Value=$USER}
        ]" \
        --region "$REGION" 2>> "$LOG_FILE"
    
    print_success "Tags applied to bucket"
}

# Enable versioning
enable_versioning() {
    log "INFO" "Enabling versioning on bucket"
    
    aws s3api put-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled \
        --region "$REGION" 2>> "$LOG_FILE"
    
    if [ $? -eq 0 ]; then
        print_success "Versioning enabled"
    else
        print_error "Failed to enable versioning"
    fi
}

# Apply bucket policy
apply_bucket_policy() {
    log "INFO" "Applying bucket policy"
    
    local bucket_policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPublicRead",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
    }
  ]
}
EOF
)
    
    if aws s3api put-bucket-policy \
        --bucket "$BUCKET_NAME" \
        --policy "$bucket_policy" \
        --region "$REGION" 2>> "$LOG_FILE"; then
        print_success "Bucket policy applied"
    else
        print_warning "Bucket policy not applied (public access might be blocked by default)"
    fi
}

# Upload sample file
upload_file() {
    log "INFO" "Uploading sample file to bucket"
    
    if aws s3 cp "$SAMPLE_FILE" "s3://$BUCKET_NAME/$SAMPLE_FILE" \
        --region "$REGION" &>> "$LOG_FILE"; then
        print_success "File uploaded: $SAMPLE_FILE"
    else
        print_error "Failed to upload file"
    fi
}

# Get bucket details
get_bucket_details() {
    log "INFO" "Retrieving bucket details"
    
    VERSIONING_STATUS=$(aws s3api get-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        --query 'Status' \
        --output text 2>> "$LOG_FILE")
    
    print_success "Retrieved bucket details"
}

# List bucket contents
list_bucket_contents() {
    log "INFO" "Listing bucket contents"
    
    echo ""
    echo "Current bucket contents:" | tee -a "$LOG_FILE"
    aws s3 ls "s3://$BUCKET_NAME" --region "$REGION" 2>> "$LOG_FILE" | tee -a "$LOG_FILE"
}

# Display results
display_results() {
    print_header "S3 Bucket Created Successfully!"
    
    cat <<EOF | tee -a "$LOG_FILE"
Bucket Name:        $BUCKET_NAME
Region:             $REGION
Versioning Status:  $VERSIONING_STATUS
Sample File:        $SAMPLE_FILE
Bucket ARN:         arn:aws:s3:::$BUCKET_NAME
==========================================

To list bucket contents:
  aws s3 ls s3://$BUCKET_NAME --region $REGION

To download the file:
  aws s3 cp s3://$BUCKET_NAME/$SAMPLE_FILE ./ --region $REGION

To access via console:
  https://s3.console.aws.amazon.com/s3/buckets/$BUCKET_NAME

Log file saved to: $LOG_FILE
EOF
}

# Cleanup on error
cleanup_on_error() {
    log "ERROR" "Script failed. Cleaning up..."
    
    if [ -n "${BUCKET_NAME:-}" ]; then
        # Try to delete the bucket if it was created
        aws s3 rb "s3://$BUCKET_NAME" --force --region "$REGION" 2>> "$LOG_FILE" || true
    fi
    
    if [ -f "$SAMPLE_FILE" ]; then
        rm -f "$SAMPLE_FILE" 2>> "$LOG_FILE" || true
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
    print_header "S3 Bucket Creation Script"
    
    # Validate and setup
    validate_aws_cli
    get_region
    verify_credentials
    
    # Create resources
    print_info "[1/8] Creating sample file..."
    create_sample_file
    
    print_info "[2/8] Creating S3 bucket..."
    create_bucket
    
    print_info "[3/8] Adding tags to bucket..."
    tag_bucket
    
    print_info "[4/8] Enabling versioning..."
    enable_versioning
    
    print_info "[5/8] Applying bucket policy..."
    apply_bucket_policy
    
    print_info "[6/8] Uploading sample file..."
    upload_file
    
    print_info "[7/8] Retrieving bucket details..."
    get_bucket_details
    
    print_info "[8/8] Finalizing..."
    list_bucket_contents
    display_results
    
    log "SUCCESS" "S3 bucket creation completed successfully"
}

# Run main function
main "$@"