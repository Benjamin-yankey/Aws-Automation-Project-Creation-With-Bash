#!/usr/bin/env bash

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="create_s3_bucket.sh"
LOG_DIR="./logs"
export LOG_FILE="${LOG_DIR}/s3_creation_$(date +%Y%m%d_%H%M%S).log"

# Source common utilities and state manager
source "${SCRIPT_DIR}/lib/common_utils.sh"
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
BUCKET_ALREADY_IN_STATE=false

# ===========================
# STATE VALIDATION
# ===========================

check_bucket_in_state() {
    log_info "Checking if bucket exists in state file"
    
    local buckets=$(get_s3_buckets)
    
    if [ -z "$buckets" ]; then
        log_info "  No buckets in state file"
        BUCKET_ALREADY_IN_STATE=false
        return 0  # Changed from return 1 to return 0
    fi
    
    while IFS= read -r bucket_json; do
        [ -z "$bucket_json" ] && continue
        
        local bucket_name=$(echo "$bucket_json" | jq -r '.bucket_name')
        
        if [ "$bucket_name" = "$BUCKET_NAME" ]; then
            log_warn "  Bucket '$BUCKET_NAME' already tracked in state file"
            
            local bucket_region=$(echo "$bucket_json" | jq -r '.region // "unknown"')
            local created_at=$(echo "$bucket_json" | jq -r '.created_at // "unknown"')
            
            log_info "    Region: $bucket_region"
            log_info "    Created: $(date -d @$created_at 2>/dev/null || echo $created_at)"
            
            BUCKET_ALREADY_IN_STATE=true
            return 0
        fi
    done <<< "$buckets"
    
    log_info "  Bucket not found in state file"
    BUCKET_ALREADY_IN_STATE=false
    return 0  # Changed from return 1 to return 0
}

list_buckets_in_state() {
    log_info "Buckets currently in state:"
    
    local buckets=$(get_s3_buckets)
    
    if [ -z "$buckets" ]; then
        echo "  (none)"
        return 0
    fi
    
    local count=0
    while IFS= read -r bucket_json; do
        [ -z "$bucket_json" ] && continue
        
        local bucket_name=$(echo "$bucket_json" | jq -r '.bucket_name')
        local bucket_region=$(echo "$bucket_json" | jq -r '.region')
        
        echo "  - $bucket_name ($bucket_region)"
        ((count++))
    done <<< "$buckets"
    
    echo "  Total: $count bucket(s)"
}

# ===========================
# BUCKET OPERATIONS
# ===========================

bucket_exists_in_aws() {
    if [ "${DRY_RUN:-false}" = "true" ]; then
        log_info "[DRY-RUN] Would check if bucket $BUCKET_NAME exists in AWS" >&2
        return 1
    fi
    
    aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" &>/dev/null
}

create_bucket() {
    log_info "Creating S3 bucket: $BUCKET_NAME"
    
    # Check if bucket already exists in AWS
    if bucket_exists_in_aws; then
        log_warn "Bucket already exists in AWS: $BUCKET_NAME"
        
        # If it exists in AWS but not in state, add it to state
        if [ "$BUCKET_ALREADY_IN_STATE" = false ]; then
            log_info "Adding existing bucket to state file"
            if [ "${DRY_RUN:-false}" != "true" ]; then
                add_s3_bucket "$BUCKET_NAME" "$REGION"
            fi
        fi
        
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

State Management:
- Tracked in: s3://$STATE_BUCKET/$STATE_FILE
- Already in state: $BUCKET_ALREADY_IN_STATE
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
Already in State:   ${BUCKET_ALREADY_IN_STATE}
==========================================

AWS CLI Commands:
  List:     aws s3 ls s3://$BUCKET_NAME --region $REGION
  Upload:   aws s3 cp file.txt s3://$BUCKET_NAME/ --region $REGION
  Download: aws s3 cp s3://$BUCKET_NAME/welcome.txt ./ --region $REGION

State file: s3://$STATE_BUCKET/$STATE_FILE
Log file: $LOG_FILE
EOF
}

# ===========================
# ARGUMENT PARSING
# ===========================

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Create an S3 bucket with automated configuration and state tracking.

OPTIONS:
  -d, --dry-run              Preview mode - no actual changes
  -b, --bucket NAME          Bucket name (default: auto-generated)
  -r, --region REGION        AWS region (default: eu-west-1)
  --no-versioning            Disable bucket versioning
  --no-encryption            Disable default encryption
  --public                   Enable public read access (NOT recommended)
  --no-upload                Skip sample file upload
  -h, --help                 Show this help message

ENVIRONMENT VARIABLES:
  BUCKET_NAME                S3 bucket name
  REGION                     AWS region
  DRY_RUN                    Enable dry-run mode (true/false)
  ENABLE_VERSIONING          Enable versioning (true/false)
  ENABLE_ENCRYPTION          Enable encryption (true/false)
  ENABLE_PUBLIC_READ         Enable public access (true/false)
  UPLOAD_SAMPLE_FILE         Upload sample file (true/false)

EXAMPLES:
  $SCRIPT_NAME --dry-run
  $SCRIPT_NAME --bucket my-unique-bucket-name
  $SCRIPT_NAME --region us-east-1 --no-versioning
  
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-d)
                export DRY_RUN=true
                shift
                ;;
            --bucket|-b)
                export BUCKET_NAME="$2"
                shift 2
                ;;
            --region|-r)
                export REGION="$2"
                shift 2
                ;;
            --no-versioning)
                export ENABLE_VERSIONING=false
                shift
                ;;
            --no-encryption)
                export ENABLE_ENCRYPTION=false
                shift
                ;;
            --public)
                export ENABLE_PUBLIC_READ=true
                shift
                ;;
            --no-upload)
                export UPLOAD_SAMPLE_FILE=false
                shift
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
# MAIN EXECUTION
# ===========================
main() {
    # Parse arguments
    parse_args "$@"
    
    # Initialize
    print_header "S3 Bucket Creation Script (State-Based)"
    
    # Load existing state
    load_state
    
    # Validate prerequisites
    require_command "aws" "Install from: https://aws.amazon.com/cli/"
    require_command "jq" "Install from: https://stedolan.github.io/jq/"
    
    # Validate bucket name
    validate_bucket_name "$BUCKET_NAME"
    
    # Verify credentials
    verify_aws_credentials "$REGION"
    
    # Check if bucket already in state
    echo ""
    log_info "Checking state for existing bucket..."
    check_bucket_in_state
    
    # Show existing buckets in state
    echo ""
    log_info "Listing buckets in state..."
    list_buckets_in_state
    
    # Display configuration
    echo ""
    log_info "Starting bucket creation process..."
    log_info "Configuration:"
    log_info "  Bucket: $BUCKET_NAME"
    log_info "  Region: $REGION"
    log_info "  Versioning: $ENABLE_VERSIONING"
    log_info "  Encryption: $ENABLE_ENCRYPTION"
    log_info "  In State: $BUCKET_ALREADY_IN_STATE"
    echo ""
    
    # Warn if bucket already exists
    if [ "$BUCKET_ALREADY_IN_STATE" = true ]; then
        log_warn "Bucket is already tracked in state file!"
        log_info "This script will update configuration but not create a new bucket"
        echo ""
    fi
    
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
    echo ""
    get_bucket_details
    display_summary
    
    log_success "S3 bucket creation completed successfully"
}

# Run main function
main "$@"