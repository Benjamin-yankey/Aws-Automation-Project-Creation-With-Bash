#!/usr/bin/env bash

# Script: cleanup_resources.sh
# Purpose: Clean up all AWS resources with logging and safety checks (Optimized)
# Author: DevOps Automation Lab
# Date: January 2026

set -euo pipefail

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_NAME="$(basename "$0")"
LOG_DIR="./logs"
LOG_FILE="${LOG_DIR}/cleanup_$(date +%Y%m%d_%H%M%S).log"
OUTPUT_FILE="${LOG_DIR}/cleanup_summary.txt"

# Detect AWS CLI default region or use fallback
AWS_DEFAULT_REGION=$(aws configure get region 2>/dev/null || echo "")
REGION="${REGION:-${AWS_DEFAULT_REGION:-eu-west-1}}"

# Environment variables with defaults
PROJECT_TAG="${PROJECT_TAG:-AutomationLab}"
DRY_RUN="${DRY_RUN:-false}"
FORCE_DELETE="${FORCE_DELETE:-false}"
DELETE_ALL_REGIONS="${DELETE_ALL_REGIONS:-false}"
SKIP_CONFIRMATION="${SKIP_CONFIRMATION:-false}"

# Tracking variables
DELETED_INSTANCES=0
DELETED_KEY_PAIRS=0
DELETED_SECURITY_GROUPS=0
DELETED_BUCKETS=0
DELETED_LOCAL_FILES=0

# ===========================
# UTILITY FUNCTIONS
# ===========================

# Show usage information
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

PURPOSE:
  Safely delete AWS resources created by automation scripts.

OPTIONS:
  -r REGION          AWS region to clean (default: AWS CLI default or eu-west-1)
  -a                 Clean ALL regions (use with caution!)
  -t TAG             Project tag to filter resources (default: AutomationLab)
  -d                 Dry-run mode (show what would be deleted)
  -f                 Force delete without confirmation
  -y                 Skip confirmation prompt (use with caution!)
  -h                 Show this help message

EXAMPLES:
  $SCRIPT_NAME -r us-east-1
  $SCRIPT_NAME -a -t AutomationLab
  DRY_RUN=true $SCRIPT_NAME
  FORCE_DELETE=true PROJECT_TAG=MyProject $SCRIPT_NAME

ENVIRONMENT VARIABLES:
  REGION                AWS region to clean
  DELETE_ALL_REGIONS    Clean all regions (true/false)
  PROJECT_TAG           Project tag filter
  DRY_RUN               Enable dry-run mode (true/false)
  FORCE_DELETE          Force delete without prompts (true/false)
  SKIP_CONFIRMATION     Skip confirmation (true/false)

SAFETY FEATURES:
  - Confirmation prompt before deletion
  - Dry-run mode to preview actions
  - Detailed logging of all operations
  - Graceful handling of dependencies
  - Summary report of deleted resources

RESOURCES DELETED:
  - EC2 instances (with Project tag)
  - EC2 key pairs (matching pattern)
  - Security groups (with Project tag)
  - S3 buckets (matching pattern or tag)
  - Local .pem files and sample files

EOF
    exit 0
}

# Parse command-line arguments
parse_args() {
    while getopts "r:t:adfyh" opt; do
        case "$opt" in
            r) REGION="$OPTARG" ;;
            t) PROJECT_TAG="$OPTARG" ;;
            a) DELETE_ALL_REGIONS=true ;;
            d) DRY_RUN=true ;;
            f) FORCE_DELETE=true ;;
            y) SKIP_CONFIRMATION=true ;;
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
    log "INFO" "Force delete: $FORCE_DELETE"
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

# Print error message
print_error() {
    local message="$1"
    echo "✗ ERROR: $message" >&2
    log "ERROR" "$message"
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
        log "INFO" "[DRY RUN] aws $*"
        echo "[DRY RUN] Would execute: aws $*"
        return 0
    fi
    
    aws "$@" 2>> "$LOG_FILE"
}

# Validate AWS CLI is installed
validate_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    print_success "AWS CLI is installed"
}

# Validate jq is installed (for S3 cleanup)
validate_jq() {
    if ! command -v jq &> /dev/null; then
        print_warning "jq is not installed. S3 versioned object cleanup may be limited."
        print_info "Install jq for complete S3 cleanup: https://stedolan.github.io/jq/"
        return 1
    fi
    return 0
}

# Get list of regions to clean
get_regions_list() {
    if [ "$DELETE_ALL_REGIONS" = true ]; then
        if [ "$DRY_RUN" = true ]; then
            REGIONS="us-east-1 us-west-2 eu-west-1"
            print_info "[DRY RUN] Would clean all regions"
        else
            REGIONS=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>> "$LOG_FILE" || echo "")
            if [ -z "$REGIONS" ]; then
                print_error "Failed to retrieve regions list"
                exit 1
            fi
        fi
        log "INFO" "Will clean all regions: $REGIONS"
    else
        REGIONS="$REGION"
        log "INFO" "Will clean region: $REGIONS"
    fi
}

# Verify AWS credentials
verify_credentials() {
    log "INFO" "Verifying AWS credentials"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] Would verify AWS credentials"
        return 0
    fi
    
    if ! aws sts get-caller-identity >> "$LOG_FILE" 2>&1; then
        print_error "AWS credentials are not configured properly"
        exit 1
    fi
    
    local account_id=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
    print_success "AWS credentials verified (Account: $account_id)"
}

# Confirm cleanup
confirm_cleanup() {
    if [ "$SKIP_CONFIRMATION" = true ]; then
        log "INFO" "Skipping confirmation (SKIP_CONFIRMATION=true)"
        print_warning "Skipping confirmation prompt (auto-confirmed)"
        return 0
    fi
    
    print_header "⚠️  RESOURCE DELETION WARNING"
    
    cat <<EOF

This script will DELETE the following resources:

SCOPE:
  Region(s):    ${DELETE_ALL_REGIONS:+ALL REGIONS}${DELETE_ALL_REGIONS:-$REGION}
  Project Tag:  $PROJECT_TAG

RESOURCES TO BE DELETED:
  ✗ EC2 instances (tagged with Project=$PROJECT_TAG)
  ✗ EC2 key pairs (pattern: devops-keypair*)
  ✗ Security groups (tagged with Project=$PROJECT_TAG)
  ✗ S3 buckets (pattern: devops-automation-lab* OR tagged)
  ✗ All S3 bucket contents (including versions)
  ✗ Local files (*.pem, welcome*.txt)

⚠️  THIS ACTION CANNOT BE UNDONE! ⚠️

EOF
    
    if [ "$DRY_RUN" = true ]; then
        echo "🔍 DRY-RUN MODE: No resources will be deleted"
        echo ""
        return 0
    fi
    
    if [ "$FORCE_DELETE" = true ]; then
        echo "⚡ FORCE MODE: Deletion will proceed automatically in 5 seconds..."
        echo "   Press Ctrl+C to cancel"
        sleep 5
        log "INFO" "Force delete mode - proceeding automatically"
        return 0
    fi
    
    echo -n "Type 'DELETE' (in capitals) to confirm: "
    read -r CONFIRM
    
    if [ "$CONFIRM" != "DELETE" ]; then
        log "INFO" "Cleanup cancelled by user"
        echo ""
        echo "Cleanup cancelled. No resources were deleted."
        exit 0
    fi
    
    log "INFO" "User confirmed cleanup with DELETE"
    print_info "Starting cleanup process..."
}

# Terminate EC2 instances
terminate_instances() {
    local region="$1"
    
    log "INFO" "Checking for EC2 instances in $region"
    
    local instance_ids
    if [ "$DRY_RUN" = true ]; then
        instance_ids="i-dry-run-12345 i-dry-run-67890"
    else
        instance_ids=$(aws ec2 describe-instances \
            --region "$region" \
            --filters "Name=tag:Project,Values=$PROJECT_TAG" \
                      "Name=instance-state-name,Values=running,stopped,stopping,pending" \
            --query 'Reservations[*].Instances[*].InstanceId' \
            --output text 2>> "$LOG_FILE" | tr '\n' ' ' | xargs || echo "")
    fi
    
    if [ -z "$instance_ids" ] || [ "$instance_ids" = " " ]; then
        print_info "  No EC2 instances found in $region"
        return 0
    fi
    
    print_info "  Found instances: $instance_ids"
    
    if aws_cmd ec2 terminate-instances \
        --instance-ids $instance_ids \
        --region "$region" >> "$LOG_FILE" 2>&1; then
        
        if [ "$DRY_RUN" = false ]; then
            print_info "  ⏳ Waiting for instances to terminate..."
            aws ec2 wait instance-terminated \
                --instance-ids $instance_ids \
                --region "$region" 2>> "$LOG_FILE" || true
        fi
        
        local count=$(echo "$instance_ids" | wc -w)
        DELETED_INSTANCES=$((DELETED_INSTANCES + count))
        print_success "  Terminated $count instance(s) in $region"
    else
        print_error "  Failed to terminate instances in $region"
    fi
}

# Delete key pairs
delete_key_pairs() {
    local region="$1"
    
    log "INFO" "Checking for key pairs in $region"
    
    local key_pairs
    if [ "$DRY_RUN" = true ]; then
        key_pairs="devops-keypair-dry-run-1 devops-keypair-dry-run-2"
    else
        key_pairs=$(aws ec2 describe-key-pairs \
            --region "$region" \
            --query 'KeyPairs[?starts_with(KeyName, `devops-keypair`)].KeyName' \
            --output text 2>> "$LOG_FILE" || echo "")
    fi
    
    if [ -z "$key_pairs" ]; then
        print_info "  No key pairs found in $region"
        return 0
    fi
    
    local deleted_count=0
    for key in $key_pairs; do
        if aws_cmd ec2 delete-key-pair \
            --key-name "$key" \
            --region "$region"; then
            print_success "  Deleted key pair: $key"
            ((deleted_count++))
            
            # Remove local .pem file if exists
            local pem_file="${key}.pem"
            if [ -f "$pem_file" ]; then
                if [ "$DRY_RUN" = false ]; then
                    rm -f "$pem_file"
                fi
                print_success "  Removed local file: $pem_file"
                ((DELETED_LOCAL_FILES++))
            fi
        else
            print_warning "  Could not delete key pair: $key"
        fi
    done
    
    DELETED_KEY_PAIRS=$((DELETED_KEY_PAIRS + deleted_count))
}

# Delete security groups
delete_security_groups() {
    local region="$1"
    
    log "INFO" "Checking for security groups in $region"
    
    # Wait for instances to fully terminate
    if [ "$DRY_RUN" = false ]; then
        sleep 5
    fi
    
    local sg_ids
    if [ "$DRY_RUN" = true ]; then
        sg_ids="sg-dry-run-12345 sg-dry-run-67890"
    else
        sg_ids=$(aws ec2 describe-security-groups \
            --region "$region" \
            --filters "Name=tag:Project,Values=$PROJECT_TAG" \
            --query 'SecurityGroups[*].[GroupId,GroupName]' \
            --output text 2>> "$LOG_FILE" || echo "")
    fi
    
    if [ -z "$sg_ids" ]; then
        print_info "  No security groups found in $region"
        return 0
    fi
    
    local deleted_count=0
    echo "$sg_ids" | while read -r sg_id sg_name; do
        if [ -z "$sg_id" ]; then
            continue
        fi
        
        # Skip default security group
        if [ "$sg_name" = "default" ]; then
            print_info "  Skipping default security group: $sg_id"
            continue
        fi
        
        if aws_cmd ec2 delete-security-group \
            --group-id "$sg_id" \
            --region "$region"; then
            print_success "  Deleted security group: $sg_id ($sg_name)"
            ((deleted_count++))
        else
            print_warning "  Could not delete security group: $sg_id (may have dependencies)"
        fi
    done 2>/dev/null || true
    
    # Update counter (note: subshell issue, so we count again)
    if [ "$DRY_RUN" = false ]; then
        deleted_count=$(echo "$sg_ids" | grep -c "sg-" || echo 0)
    else
        deleted_count=2
    fi
    DELETED_SECURITY_GROUPS=$((DELETED_SECURITY_GROUPS + deleted_count))
}

# Delete S3 buckets completely
empty_bucket() {
    local bucket="$1"
    local bucket_region="$2"
    local jq_available="$3"

    log "INFO" "Emptying bucket: $bucket (region: $bucket_region)"

    if [ "$DRY_RUN" = true ]; then
        print_info "    [DRY RUN] Would empty bucket: $bucket"
        return 0
    fi

    # Best-effort: remove bucket policy, public access block, ownership controls
    aws s3api delete-bucket-policy --bucket "$bucket" --region "$bucket_region" >> "$LOG_FILE" 2>&1 || true
    aws s3api delete-public-access-block --bucket "$bucket" --region "$bucket_region" >> "$LOG_FILE" 2>&1 || true
    aws s3api delete-bucket-ownership-controls --bucket "$bucket" --region "$bucket_region" >> "$LOG_FILE" 2>&1 || true

    # Suspend versioning to help further operations (will not remove versions)
    aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Suspended --region "$bucket_region" >> "$LOG_FILE" 2>&1 || true

    # Abort multipart uploads (if any)
    if [ "$jq_available" = true ]; then
        aws s3api list-multipart-uploads --bucket "$bucket" --output json --region "$bucket_region" 2>> "$LOG_FILE" | \
        jq -r '.Uploads[]? | "\(.Key)\t\(.UploadId)"' 2>> "$LOG_FILE" | \
        while IFS=$'\t' read -r key uploadid; do
            [ -n "$key" ] && aws s3api abort-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$uploadid" --region "$bucket_region" >> "$LOG_FILE" 2>&1 || true
        done
    else
        # Fallback: try aws s3 rm (may not clear multipart uploads)
        print_warning "    jq not available: aborting multipart uploads may be incomplete"
    fi

    # If jq is available try thorough versioned-object deletion
    if [ "$jq_available" = true ]; then
        print_info "    Removing versioned objects and delete markers (using jq)..."
        # Delete versions
        aws s3api list-object-versions --bucket "$bucket" --output json --region "$bucket_region" 2>> "$LOG_FILE" | \
        jq -r '.Versions[]? | "\(.Key)\t\(.VersionId)"' 2>> "$LOG_FILE" | \
        while IFS=$'\t' read -r key version; do
            [ -n "$key" ] && aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$version" --region "$bucket_region" >> "$LOG_FILE" 2>&1 || true
        done

        # Delete delete markers
        aws s3api list-object-versions --bucket "$bucket" --output json --region "$bucket_region" 2>> "$LOG_FILE" | \
        jq -r '.DeleteMarkers[]? | "\(.Key)\t\(.VersionId)"' 2>> "$LOG_FILE" | \
        while IFS=$'\t' read -r key version; do
            [ -n "$key" ] && aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$version" --region "$bucket_region" >> "$LOG_FILE" 2>&1 || true
        done
    else
        print_warning "    jq not available: falling back to aws s3 rm --recursive (may not remove versions)"
        aws s3 rm "s3://$bucket" --recursive --region "$bucket_region" >> "$LOG_FILE" 2>&1 || true
    fi

    # Final best-effort: force empty via aws s3 rb
    aws s3 rb "s3://$bucket" --force --region "$bucket_region" >> "$LOG_FILE" 2>&1 || true
}

delete_s3_buckets() {
    log "INFO" "Checking for S3 buckets"

    local buckets
    if [ "$DRY_RUN" = true ]; then
        buckets="devops-automation-lab-dry-run-1 devops-automation-lab-dry-run-2"
    else
        buckets=$(aws s3api list-buckets \
            --query 'Buckets[?starts_with(Name, `devops-automation-lab`)].Name' \
            --output text 2>> "$LOG_FILE" || echo "")
    fi

    if [ -z "$buckets" ]; then
        print_info "  No S3 buckets found"
        return 0
    fi

    local jq_available=true
    validate_jq || jq_available=false

    for bucket in $buckets; do
        # Get bucket region
        local bucket_region
        if [ "$DRY_RUN" = true ]; then
            bucket_region="us-east-1"
        else
            bucket_region=$(aws s3api get-bucket-location \
                --bucket "$bucket" \
                --query 'LocationConstraint' \
                --output text 2>> "$LOG_FILE" || echo "us-east-1")

            if [ "$bucket_region" = "None" ] || [ -z "$bucket_region" ]; then
                bucket_region="us-east-1"
            fi
        fi

        # Check region filter
        if [ "$DELETE_ALL_REGIONS" = false ] && [ "$REGION" != "$bucket_region" ]; then
            print_info "  Skipping bucket $bucket in $bucket_region (not in selected region)"
            continue
        fi

        print_info "  Processing bucket: $bucket (region: $bucket_region)"

        # Attempt thorough emptying
        empty_bucket "$bucket" "$bucket_region" "$jq_available"

        # Try to delete the bucket
        if aws_cmd s3api delete-bucket \
            --bucket "$bucket" \
            --region "$bucket_region"; then
            print_success "  Deleted bucket: $bucket"
            ((DELETED_BUCKETS++))
        else
            if [ "$DRY_RUN" = false ]; then
                print_warning "  Could not delete bucket: $bucket (attempting final force remove)"
                # One more attempt to remove contents and delete
                aws s3 rb "s3://$bucket" --force --region "$bucket_region" >> "$LOG_FILE" 2>&1 || true
                if aws_cmd s3api delete-bucket --bucket "$bucket" --region "$bucket_region"; then
                    print_success "  Deleted bucket (force): $bucket"
                    ((DELETED_BUCKETS++))
                else
                    print_error "  Failed to delete bucket: $bucket"
                    print_warning "  Common reasons: object lock/retention, bucket ownership or missing permissions."
                    print_info "  To investigate manually: aws s3api list-object-versions --bucket $bucket --region $bucket_region"
                fi
            fi
        fi
    done
}

# Clean up local files
cleanup_local_files() {
    log "INFO" "Cleaning up local files"
    
    local files_to_delete=()
    
    # Find welcome files
    for file in welcome*.txt; do
        [ -f "$file" ] && files_to_delete+=("$file")
    done
    
    # Find .pem files
    for file in devops-keypair-*.pem *.pem; do
        [ -f "$file" ] && files_to_delete+=("$file")
    done
    
    if [ ${#files_to_delete[@]} -eq 0 ]; then
        print_info "  No local files to clean"
        return 0
    fi
    
    for file in "${files_to_delete[@]}"; do
        if [ "$DRY_RUN" = false ]; then
            rm -f "$file"
        fi
        print_success "  Removed: $file"
        ((DELETED_LOCAL_FILES++))
    done
    
    print_success "  Cleaned up ${#files_to_delete[@]} local file(s)"
}

# Display summary
display_summary() {
    print_header "Cleanup Summary"
    
    local summary_text
    summary_text=$(cat <<EOF
Cleanup completed on: $(date)
Region(s): ${DELETE_ALL_REGIONS:+ALL REGIONS}${DELETE_ALL_REGIONS:-$REGION}
Project Tag: $PROJECT_TAG
Dry-Run Mode: $DRY_RUN

Resources Deleted:
  EC2 Instances:      $DELETED_INSTANCES
  Key Pairs:          $DELETED_KEY_PAIRS
  Security Groups:    $DELETED_SECURITY_GROUPS
  S3 Buckets:         $DELETED_BUCKETS
  Local Files:        $DELETED_LOCAL_FILES

Total Resources:      $((DELETED_INSTANCES + DELETED_KEY_PAIRS + DELETED_SECURITY_GROUPS + DELETED_BUCKETS + DELETED_LOCAL_FILES))

Log File: $LOG_FILE
==========================================
EOF
)
    
    echo "$summary_text"
    echo "$summary_text" >> "$LOG_FILE"
    
    # Save summary to file
    if [ "$DRY_RUN" = false ]; then
        echo "$summary_text" > "$OUTPUT_FILE"
        print_info "Summary saved to: $OUTPUT_FILE"
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
    echo "" >&2
    echo "Check log file for details: $LOG_FILE" >&2
    
    # Display partial summary
    if [ "$DELETED_INSTANCES" -gt 0 ] || [ "$DELETED_KEY_PAIRS" -gt 0 ] || \
       [ "$DELETED_SECURITY_GROUPS" -gt 0 ] || [ "$DELETED_BUCKETS" -gt 0 ]; then
        echo "" >&2
        echo "Partial cleanup summary:" >&2
        echo "  Instances: $DELETED_INSTANCES, Key Pairs: $DELETED_KEY_PAIRS" >&2
        echo "  Security Groups: $DELETED_SECURITY_GROUPS, Buckets: $DELETED_BUCKETS" >&2
    fi
    
    exit 1
}

# ===========================
# MAIN EXECUTION
# ===========================
main() {
    # Parse command-line arguments
    parse_args "$@"
    
    # Set up error trap
    trap 'cleanup_on_error $LINENO "$BASH_COMMAND"' ERR
    
    # Initialize
    init_logging
    print_header "AWS Resource Cleanup Script"
    
    # Validate prerequisites
    validate_aws_cli
    validate_jq
    get_regions_list
    verify_credentials
    
    # Display configuration
    print_info "Configuration:"
    print_info "  Region(s):         ${DELETE_ALL_REGIONS:+ALL REGIONS}${DELETE_ALL_REGIONS:-$REGION}"
    print_info "  Project Tag:       $PROJECT_TAG"
    print_info "  Dry-Run:           $DRY_RUN"
    print_info "  Force Delete:      $FORCE_DELETE"
    echo ""
    
    # Confirm cleanup
    confirm_cleanup
    
    echo ""
    
    # Clean resources in each region
    for current_region in $REGIONS; do
        print_header "Cleaning region: $current_region"
        
        print_info "Step 1: Terminating EC2 instances..."
        terminate_instances "$current_region"
        
        print_info "Step 2: Deleting key pairs..."
        delete_key_pairs "$current_region"
        
        print_info "Step 3: Deleting security groups..."
        delete_security_groups "$current_region"
        
        echo ""
    done
    
    # S3 buckets (global but region-aware)
    print_header "Cleaning S3 Buckets"
    print_info "Step 4: Deleting S3 buckets..."
    delete_s3_buckets
    
    echo ""
    
    # Local cleanup
    print_header "Local Cleanup"
    print_info "Step 5: Cleaning up local files..."
    cleanup_local_files
    
    echo ""
    
    # Display summary
    display_summary
    
    log "SUCCESS" "Cleanup completed successfully"
    
    if [ "$DRY_RUN" = true ]; then
        echo ""
        print_info "This was a dry-run. No resources were actually deleted."
        print_info "Run without -d flag to perform actual deletion."
    else
        print_success "All cleanup operations completed!"
    fi
}

# Run main function
main "$@"