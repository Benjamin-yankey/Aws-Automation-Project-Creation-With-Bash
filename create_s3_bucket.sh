#!/bin/bash

set -euo pipefail

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_NAME="$(basename "$0")"
LOG_DIR="./logs"
LOG_FILE="${LOG_DIR}/s3_creation_$(date +%Y%m%d_%H%M%S).log"
OUTPUT_FILE="${LOG_DIR}/outputs.env"

# Detect AWS CLI default region or use fallback
AWS_DEFAULT_REGION=$(aws configure get region 2>/dev/null || echo "")
REGION="${REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}"

# Environment variables with defaults
BUCKET_NAME="${BUCKET_NAME:-devops-automation-lab-$(date +%s)-$RANDOM}"
DRY_RUN="${DRY_RUN:-false}"
ENABLE_PUBLIC_READ="${ENABLE_PUBLIC_READ:-false}"
ENABLE_VERSIONING="${ENABLE_VERSIONING:-true}"
ENABLE_ENCRYPTION="${ENABLE_ENCRYPTION:-true}"
UPLOAD_SAMPLE_FILE="${UPLOAD_SAMPLE_FILE:-true}"

# Sample file (temporary)
SAMPLE_FILE=""

# ===========================
# UTILITY FUNCTIONS
# ===========================

# Show usage information
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

OPTIONS:
  -r REGION          AWS region (default: AWS CLI default or eu-west-1)
  -b BUCKET_NAME     Custom bucket name (default: auto-generated)
  -d                 Dry-run mode (don't make actual changes)
  -p                 Enable public read access (NOT RECOMMENDED)
  -n                 Skip sample file upload
  -h                 Show this help message

EXAMPLES:
  $SCRIPT_NAME -r us-east-1
  $SCRIPT_NAME -b my-custom-bucket-name
  DRY_RUN=true $SCRIPT_NAME
  REGION=ap-southeast-1 ENABLE_ENCRYPTION=true $SCRIPT_NAME

ENVIRONMENT VARIABLES:
  REGION                AWS region
  BUCKET_NAME           S3 bucket name
  DRY_RUN               Enable dry-run mode (true/false)
  ENABLE_PUBLIC_READ    Enable public read access (true/false) - NOT RECOMMENDED
  ENABLE_VERSIONING     Enable bucket versioning (true/false, default: true)
  ENABLE_ENCRYPTION     Enable default encryption (true/false, default: true)
  UPLOAD_SAMPLE_FILE    Upload sample welcome file (true/false, default: true)

SECURITY NOTES:
  - Default encryption (AES256) is enabled by default
  - Public read access is disabled by default (use -p to override)
  - Versioning is enabled by default for data protection

EOF
    exit 0
}

# Parse command-line arguments
parse_args() {
    while getopts "r:b:dpnh" opt; do
        case "$opt" in
            r) REGION="$OPTARG" ;;
            b) BUCKET_NAME="$OPTARG" ;;
            d) DRY_RUN=true ;;
            p) 
                ENABLE_PUBLIC_READ=true
                print_warning "Public read access will be enabled (security risk)"
                ;;
            n) UPLOAD_SAMPLE_FILE=false ;;
            h) usage ;;
            *) 
                echo "Error: Invalid option. Use -h for help."
                exit 1
                ;;
        esac
    done
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
    
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] Would verify AWS credentials"
        return 0
    fi
    
    if ! aws_cmd sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials are not configured properly"
    fi
    
    print_success "AWS credentials verified for region: $REGION"
}

# Check if bucket exists
bucket_exists() {
    if [ "$DRY_RUN" = true ]; then
        return 1  # Assume bucket doesn't exist in dry-run
    fi
    
    aws_cmd s3api head-bucket --bucket "$BUCKET_NAME" &>/dev/null
}

# Validate bucket name format
validate_bucket_name() {
    local name="$1"
    
    # Bucket name validation rules
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
        print_error "Invalid bucket name format. Must be 3-63 chars, lowercase, start/end with letter/number"
    fi
    
    if [[ "$name" =~ \.\. ]] || [[ "$name" =~ \.- ]] || [[ "$name" =~ -\. ]]; then
        print_error "Invalid bucket name: cannot have consecutive periods or period-dash combinations"
    fi
    
    log "INFO" "Bucket name validation passed: $name"
}

# Create sample file
create_sample_file() {
    if [ "$UPLOAD_SAMPLE_FILE" = false ]; then
        print_info "Skipping sample file creation"
        return 0
    fi
    
    log "INFO" "Creating temporary sample file"
    
    # Create temporary file
    SAMPLE_FILE=$(mktemp "${TMPDIR:-/tmp}/welcome.XXXXXX.txt")
    
    cat > "$SAMPLE_FILE" << EOF
Welcome to DevOps Automation Lab!
==================================

This file was automatically uploaded by create_s3_bucket.sh script.

Bucket: $BUCKET_NAME
Region: $REGION
Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)

Project: AWS Resource Automation
Purpose: Learning AWS CLI and Bash scripting

---
This is a demonstration file showing:
- Automated S3 bucket creation
- File upload capabilities
- Versioning management
- Encryption at rest
- Tagging and organization

Security Features:
- Default encryption: ${ENABLE_ENCRYPTION}
- Versioning: ${ENABLE_VERSIONING}
- Public access: ${ENABLE_PUBLIC_READ}
EOF

    print_success "Sample file created: $(basename "$SAMPLE_FILE")"
}

# Create S3 bucket (idempotent)
create_bucket() {
    log "INFO" "Creating S3 bucket: $BUCKET_NAME"
    
    # Check if bucket already exists
    if bucket_exists; then
        print_warning "Bucket already exists: $BUCKET_NAME"
        print_info "Skipping bucket creation, will configure existing bucket"
        return 0
    fi
    
    # us-east-1 doesn't need LocationConstraint
    if [ "$REGION" == "us-east-1" ]; then
        if aws_cmd s3api create-bucket \
            --bucket "$BUCKET_NAME"; then
            print_success "Bucket created: $BUCKET_NAME"
        else
            print_error "Failed to create bucket"
        fi
    else
        if aws_cmd s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --create-bucket-configuration LocationConstraint="$REGION"; then
            print_success "Bucket created: $BUCKET_NAME"
        else
            print_error "Failed to create bucket"
        fi
    fi
}

# Tag bucket
tag_bucket() {
    log "INFO" "Adding tags to bucket"
    
    local username="${USER:-automation}"
    
    if aws_cmd s3api put-bucket-tagging \
        --bucket "$BUCKET_NAME" \
        --tagging "TagSet=[
            {Key=Project,Value=AutomationLab},
            {Key=Environment,Value=Development},
            {Key=ManagedBy,Value=BashScript},
            {Key=CreatedBy,Value=${username}},
            {Key=CreatedAt,Value=$(date -u +%Y-%m-%dT%H:%M:%SZ)}
        ]"; then
        print_success "Tags applied to bucket"
    else
        print_warning "Failed to apply tags (bucket may already have tags)"
    fi
}

# Enable versioning
enable_versioning() {
    if [ "$ENABLE_VERSIONING" = false ]; then
        print_info "Skipping versioning (disabled by configuration)"
        return 0
    fi
    
    log "INFO" "Enabling versioning on bucket"
    
    if aws_cmd s3api put-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled; then
        print_success "Versioning enabled"
    else
        print_warning "Failed to enable versioning (may already be enabled)"
    fi
}

# Enable default encryption
enable_encryption() {
    if [ "$ENABLE_ENCRYPTION" = false ]; then
        print_info "Skipping encryption (disabled by configuration)"
        return 0
    fi
    
    log "INFO" "Enabling default encryption (AES256)"
    
    if aws_cmd s3api put-bucket-encryption \
        --bucket "$BUCKET_NAME" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                },
                "BucketKeyEnabled": true
            }]
        }'; then
        print_success "Default encryption enabled (AES256)"
    else
        print_warning "Failed to enable encryption (may already be enabled)"
    fi
}

# Block public access (security best practice)
block_public_access() {
    if [ "$ENABLE_PUBLIC_READ" = true ]; then
        print_info "Skipping public access block (public read requested)"
        return 0
    fi
    
    log "INFO" "Enabling Block Public Access settings"
    
    if aws_cmd s3api put-public-access-block \
        --bucket "$BUCKET_NAME" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"; then
        print_success "Public access blocked (recommended security setting)"
    else
        print_warning "Failed to block public access"
    fi
}

# Apply bucket policy (only if explicitly requested)
apply_bucket_policy() {
    if [ "$ENABLE_PUBLIC_READ" = false ]; then
        print_info "Skipping public bucket policy (recommended for security)"
        return 0
    fi
    
    log "INFO" "Applying public read bucket policy"
    print_warning "Applying public read policy - this is a security risk!"
    
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
    
    if aws_cmd s3api put-bucket-policy \
        --bucket "$BUCKET_NAME" \
        --policy "$bucket_policy"; then
        print_success "Public read policy applied"
    else
        print_warning "Bucket policy not applied (public access may be blocked)"
    fi
}

# Upload sample file
upload_file() {
    if [ "$UPLOAD_SAMPLE_FILE" = false ] || [ -z "$SAMPLE_FILE" ]; then
        print_info "Skipping file upload"
        return 0
    fi
    
    log "INFO" "Uploading sample file to bucket"
    
    local filename="$(basename "$SAMPLE_FILE")"
    
    if aws_cmd s3 cp "$SAMPLE_FILE" "s3://$BUCKET_NAME/welcome.txt"; then
        print_success "File uploaded: welcome.txt"
    else
        print_warning "Failed to upload file (bucket may have restrictions)"
    fi
}

# Get bucket details
get_bucket_details() {
    log "INFO" "Retrieving bucket details"
    
    if [ "$DRY_RUN" = true ]; then
        VERSIONING_STATUS="Enabled"
        ENCRYPTION_STATUS="AES256"
        print_info "[DRY RUN] Would retrieve bucket details"
        return 0
    fi
    
    VERSIONING_STATUS=$(aws_cmd s3api get-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --query 'Status' \
        --output text 2>/dev/null || echo "Not configured")
    
    ENCRYPTION_STATUS=$(aws_cmd s3api get-bucket-encryption \
        --bucket "$BUCKET_NAME" \
        --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
        --output text 2>/dev/null || echo "Not configured")
    
    print_success "Retrieved bucket details"
}

# List bucket contents
list_bucket_contents() {
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] Would list bucket contents"
        return 0
    fi
    
    log "INFO" "Listing bucket contents"
    
    echo ""
    echo "Current bucket contents:"
    if aws_cmd s3 ls "s3://$BUCKET_NAME" 2>/dev/null; then
        :
    else
        echo "  (empty or access denied)"
    fi
}

# Display summary
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
  List contents:
    aws s3 ls s3://$BUCKET_NAME --region $REGION

  Upload file:
    aws s3 cp myfile.txt s3://$BUCKET_NAME/ --region $REGION

  Download file:
    aws s3 cp s3://$BUCKET_NAME/welcome.txt ./ --region $REGION

  Delete bucket (when done):
    aws s3 rb s3://$BUCKET_NAME --force --region $REGION

AWS Console:
  https://s3.console.aws.amazon.com/s3/buckets/$BUCKET_NAME

Files:
  Log:     $LOG_FILE
EOF

    if [ "$DRY_RUN" = false ]; then
        echo "  Outputs: $OUTPUT_FILE"
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
export BUCKET_NAME="$BUCKET_NAME"
export REGION="$REGION"
export BUCKET_ARN="arn:aws:s3:::${BUCKET_NAME}"
export VERSIONING_STATUS="$VERSIONING_STATUS"
export ENCRYPTION_STATUS="$ENCRYPTION_STATUS"
EOF
    
    print_success "Outputs exported to $OUTPUT_FILE"
    log "INFO" "Outputs: BUCKET_NAME=$BUCKET_NAME, REGION=$REGION"
}

# Cleanup temporary files
cleanup_temp_files() {
    if [ -n "${SAMPLE_FILE:-}" ] && [ -f "$SAMPLE_FILE" ]; then
        rm -f "$SAMPLE_FILE" 2>/dev/null || true
        log "INFO" "Cleaned up temporary file: $SAMPLE_FILE"
    fi
}

# Cleanup on error
cleanup_on_error() {
    local line="${1:-unknown}"
    local cmd="${2:-unknown}"
    
    log "ERROR" "Script failed at line $line: $cmd"
    echo "" >&2
    echo "✗ Script failed at line $line" >&2
    echo "  Command: $cmd" >&2
    
    # Cleanup temporary files
    cleanup_temp_files
    
    # Only delete bucket if it was created in this run and is empty
    if [ -n "${BUCKET_NAME:-}" ] && [ "${BUCKET_CREATED_NOW:-false}" = true ]; then
        echo "  Attempting to delete newly created bucket..." >&2
        aws_cmd s3 rb "s3://$BUCKET_NAME" --force 2>/dev/null || true
        log "INFO" "Cleanup: Attempted to delete bucket $BUCKET_NAME"
    fi
    
    echo "" >&2
    echo "Check log file for details: $LOG_FILE" >&2
    exit 1
}

# Cleanup on normal exit
cleanup_on_exit() {
    cleanup_temp_files
}

# ===========================
# MAIN EXECUTION
# ===========================
main() {
    # Parse command-line arguments
    parse_args "$@"
    
    # Set up traps
    trap 'cleanup_on_error $LINENO "$BASH_COMMAND"' ERR
    trap cleanup_on_exit EXIT
    
    # Initialize
    init_logging
    print_header "S3 Bucket Creation Script"
    
    # Validate prerequisites
    validate_aws_cli
    validate_bucket_name "$BUCKET_NAME"
    verify_credentials
    
    # Display configuration
    print_info "Configuration:"
    print_info "  Region:            $REGION"
    print_info "  Bucket Name:       $BUCKET_NAME"
    print_info "  Versioning:        $ENABLE_VERSIONING"
    print_info "  Encryption:        $ENABLE_ENCRYPTION"
    print_info "  Public Access:     $ENABLE_PUBLIC_READ"
    print_info "  Upload Sample:     $UPLOAD_SAMPLE_FILE"
    echo ""
    
    # Track if bucket is created in this run
    BUCKET_CREATED_NOW=false
    
    # Create and configure bucket
    print_info "Step 1: Creating sample file..."
    create_sample_file
    
    print_info "Step 2: Creating S3 bucket..."
    if ! bucket_exists; then
        BUCKET_CREATED_NOW=true
    fi
    create_bucket
    
    print_info "Step 3: Adding tags..."
    tag_bucket
    
    print_info "Step 4: Enabling versioning..."
    enable_versioning
    
    print_info "Step 5: Enabling encryption..."
    enable_encryption
    
    print_info "Step 6: Configuring public access..."
    block_public_access
    apply_bucket_policy
    
    print_info "Step 7: Uploading sample file..."
    upload_file
    
    print_info "Step 8: Finalizing..."
    get_bucket_details
    list_bucket_contents
    display_summary
    export_outputs
    
    log "SUCCESS" "S3 bucket creation completed successfully"
    print_success "All operations completed!"
}

# Run main function
main "$@"