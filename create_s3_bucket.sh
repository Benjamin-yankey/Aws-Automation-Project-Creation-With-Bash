#!/usr/bin/env bash

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="create_s3_bucket.sh"
LOG_DIR="./logs"
export LOG_FILE="${LOG_DIR}/s3_creation_$(date +%Y%m%d_%H%M%S).log"

# Source common utilities and state manager
source "${SCRIPT_DIR}/common_utils.sh"
source "${SCRIPT_DIR}/state_manager.sh"

# Default configuration
BUCKET_NAME="${BUCKET_NAME:-devops-automation-lab-$(date +%s)-$RANDOM}"
REGION="${REGION:-eu-west-1}"
DRY_RUN="${DRY_RUN:-false}"
ENABLE_VERSIONING="${ENABLE_VERSIONING:-true}"
ENABLE_ENCRYPTION="${ENABLE_ENCRYPTION:-true}"
ENABLE_PUBLIC_READ="${ENABLE_PUBLIC_READ:-false}"
UPLOAD_SAMPLE_FILE="${UPLOAD_SAMPLE_FILE:-true}"

# State tracking
SAMPLE_FILE=""
VERSIONING_STATUS=""
ENCRYPTION_STATUS=""

# ===========================
# BUCKET OPERATIONS
# ===========================

bucket_exists() {
    if dry_run_guard "Would check if bucket $BUCKET_NAME exists"; then
        return 1
    fi
    
    aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" &>/dev/null
}

create_bucket() {
    log_info "Creating S3 bucket: $BUCKET_NAME"
    
    # Check if bucket already exists
    if bucket_exists; then
        log_warn "Bucket already exists: $BUCKET_NAME"
        log_info "Will configure existing bucket"
        return 0
    fi
    
    if dry_run_guard "Would create bucket $BUCKET_NAME in $REGION"; then
        return 0
    fi
    
    # us-east-1 doesn't need LocationConstraint
    if [ "$REGION" = "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$REGION" \
            2>> "$LOG_FILE"
    else
        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION" \
            2>> "$LOG_FILE"
    fi
    
    # Register in state
    add_s3_bucket "$BUCKET_NAME" "$REGION"
    
    log_success "Bucket created: $BUCKET_NAME"
}

tag_bucket() {
    log_info "Adding tags to bucket"
    
    if dry_run_guard "Would tag bucket $BUCKET_NAME"; then
        return 0
    fi
    
    local username="${USER:-automation}"
    
    aws s3api put-bucket-tagging \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        --tagging "TagSet=[
            {Key=Project,Value=AutomationLab},
            {Key=Environment,Value=Development},
            {Key=ManagedBy,Value=BashScript},
            {Key=CreatedBy,Value=${username}},
            {Key=CreatedAt,Value=$(date -u +%Y-%m-%dT%H:%M:%SZ)}
        ]" \
        2>> "$LOG_FILE"
    
    log_success "Tags applied to bucket"
}

configure_versioning() {
    if [ "$ENABLE_VERSIONING" != "true" ]; then
        log_info "Skipping versioning (disabled)"
        return 0
    fi
    
    log_info "Enabling versioning on bucket"
    
    if dry_run_guard "Would enable versioning on $BUCKET_NAME"; then
        return 0
    fi
    
    aws s3api put-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        --versioning-configuration Status=Enabled \
        2>> "$LOG_FILE"
    
    log_success "Versioning enabled"
}

configure_encryption() {
    if [ "$ENABLE_ENCRYPTION" != "true" ]; then
        log_info "Skipping encryption (disabled)"
        return 0
    fi
    
    log_info "Enabling default encryption (AES256)"
    
    if dry_run_guard "Would enable encryption on $BUCKET_NAME"; then
        return 0
    fi
    
    aws s3api put-bucket-encryption \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                },
                "BucketKeyEnabled": true
            }]
        }' \
        2>> "$LOG_FILE"
    
    log_success "Default encryption enabled (AES256)"
}

configure_public_access() {
    if [ "$ENABLE_PUBLIC_READ" = "true" ]; then
        log_warn "Public read access enabled - security risk!"
        return 0
    fi
    
    log_info "Blocking public access"
    
    if dry_run_guard "Would block public access on $BUCKET_NAME"; then
        return 0
    fi
    
    aws s3api put-public-access-block \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
        2>> "$LOG_FILE"
    
    log_success "Public access blocked"
}

create_sample_file() {
    if [ "$UPLOAD_SAMPLE_FILE" != "true" ]; then
        log_info "Skipping sample file creation"
        return 0
    fi
    
    log_info "Creating sample file"
    
    SAMPLE_FILE=$(create_temp_file "welcome" ".txt")
    
    cat > "$SAMPLE_FILE" <<EOF
Welcome to DevOps Automation Lab!
==================================

Bucket: $BUCKET_NAME
Region: $REGION
Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Project: AWS Resource Automation
Purpose: Learning AWS CLI and Bash scripting

Security Features:
- Encryption: ${ENABLE_ENCRYPTION}
- Versioning: ${ENABLE_VERSIONING}
- Public access: ${ENABLE_PUBLIC_READ}
EOF

    log_success "Sample file created"
}

upload_file() {
    if [ "$UPLOAD_SAMPLE_FILE" != "true" ] || [ -z "$SAMPLE_FILE" ]; then
        log_info "Skipping file upload"
        return 0
    fi
    
    log_info "Uploading sample file to bucket"
    
    if dry_run_guard "Would upload file to s3://$BUCKET_NAME/welcome.txt"; then
        return 0
    fi
    
    aws s3 cp "$SAMPLE_FILE" "s3://$BUCKET_NAME/welcome.txt" --region "$REGION" 2>> "$LOG_FILE"
    
    log_success "File uploaded: welcome.txt"
}

get_bucket_details() {
    log_info "Retrieving bucket details"
    
    if dry_run_guard "Would retrieve bucket details"; then
        VERSIONING_STATUS="Enabled"
        ENCRYPTION_STATUS="AES256"
        return 0
    fi
    
    VERSIONING_STATUS=$(aws s3api get-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        --query 'Status' \
        --output text 2>/dev/null || echo "Not configured")
    
    ENCRYPTION_STATUS=$(aws s3api get-bucket-encryption \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
        --output text 2>/dev/null || echo "Not configured")
    
    log_success "Retrieved bucket details"
}

# ===========================
# OUTPUT
# ===========================

display_summary() {
    print_header "S3 Bucket Created Successfully!"
    
    cat <<EOF
Bucket Name:        $BUCKET_NAME
Region:             $REGION
Versioning:         ${VERSIONING_STATUS}
Encryption:         ${ENCRYPTION_STATUS}
Public Access:      ${ENABLE_PUBLIC_READ}
Bucket ARN:         arn:aws:s3:::${BUCKET_NAME}
==========================================

AWS CLI Commands:
  List:     aws s3 ls s3://$BUCKET_NAME --region $REGION
  Upload:   aws s3 cp file.txt s3://$BUCKET_NAME/ --region $REGION
  Download: aws s3 cp s3://$BUCKET_NAME/welcome.txt ./ --region $REGION

Log file: $LOG_FILE
EOF
}

# ===========================
# MAIN EXECUTION
# ===========================
main() {
    # Initialize
    print_header "S3 Bucket Creation Script"
    
    # Load existing state
    load_state
    
    # Validate prerequisites
    require_command "aws" "Install from: https://aws.amazon.com/cli/"
    require_command "jq" "Install from: https://stedolan.github.io/jq/"
    
    # Validate bucket name
    validate_bucket_name "$BUCKET_NAME"
    
    # Verify credentials
    verify_aws_credentials "$REGION"
    
    # Display configuration
    log_info "Configuration:"
    log_info "  Bucket: $BUCKET_NAME"
    log_info "  Region: $REGION"
    log_info "  Versioning: $ENABLE_VERSIONING"
    log_info "  Encryption: $ENABLE_ENCRYPTION"
    echo ""
    
    # Create and configure bucket
    log_info "[1/7] Creating sample file..."
    create_sample_file
    
    log_info "[2/7] Creating S3 bucket..."
    create_bucket
    
    log_info "[3/7] Adding tags..."
    tag_bucket
    
    log_info "[4/7] Configuring versioning..."
    configure_versioning
    
    log_info "[5/7] Configuring encryption..."
    configure_encryption
    
    log_info "[6/7] Configuring access..."
    configure_public_access
    
    log_info "[7/7] Uploading sample file..."
    upload_file
    
    # Finalize
    get_bucket_details
    display_summary
    
    log_success "S3 bucket creation completed successfully"
}

# Run main function
main "$@"