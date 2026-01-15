#!/usr/bin/env bash

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="cleanup_resources.sh"
LOG_DIR="./logs"
export LOG_FILE="${LOG_DIR}/cleanup_$(date +%Y%m%d_%H%M%S).log"

# Source common utilities and state manager
source "${SCRIPT_DIR}/lib/common_utils.sh"
source "${SCRIPT_DIR}/state_manager.sh"

# Default configuration
REGION="${REGION:-eu-west-1}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_CONFIRMATION="${SKIP_CONFIRMATION:-false}"

# Tracking counters
DELETED_INSTANCES=0
DELETED_KEY_PAIRS=0
DELETED_SECURITY_GROUPS=0
DELETED_BUCKETS=0
DELETED_LOCAL_FILES=0

# ===========================
# EC2 INSTANCE CLEANUP (FROM STATE)
# ===========================

terminate_instances_from_state() {
    log_info "Terminating EC2 instances from state file"
    
    # Get instances from state
    local instances=$(get_ec2_instances)
    
    if [ -z "$instances" ]; then
        log_info "  No EC2 instances in state"
        return 0
    fi
    
    local count=0
    while IFS= read -r instance_json; do
        [ -z "$instance_json" ] && continue
        
        local instance_id=$(echo "$instance_json" | jq -r '.instance_id')
        local instance_name=$(echo "$instance_json" | jq -r '.name // "Unknown"')
        local instance_region=$(echo "$instance_json" | jq -r '.region // "eu-west-1"')
        local instance_state=$(echo "$instance_json" | jq -r '.state // "unknown"')
        
        log_info "  Found: $instance_id ($instance_name) in $instance_region [state: $instance_state]"
        
        if dry_run_guard "Would terminate instance: $instance_id in $instance_region"; then
            ((count++))
            continue
        fi
        
        # Check if instance still exists
        if ! aws ec2 describe-instances \
            --instance-ids "$instance_id" \
            --region "$instance_region" \
            >> "$LOG_FILE" 2>&1; then
            log_warn "    Instance $instance_id not found in AWS (already deleted?)"
            remove_ec2_instance "$instance_id"
            continue
        fi
        
        # Terminate the instance
        if aws ec2 terminate-instances \
            --instance-ids "$instance_id" \
            --region "$instance_region" \
            >> "$LOG_FILE" 2>&1; then
            
            log_success "  Terminated: $instance_id"
            
            # Wait for termination (with timeout)
            log_info "    ⏳ Waiting for termination..."
            aws ec2 wait instance-terminated \
                --instance-ids "$instance_id" \
                --region "$instance_region" \
                2>> "$LOG_FILE" || log_warn "    Timeout waiting for termination"
            
            # Remove from state
            remove_ec2_instance "$instance_id"
            ((count++))
        else
            log_error "  Failed to terminate: $instance_id"
        fi
    done <<< "$instances"
    
    DELETED_INSTANCES=$count
    
    if [ $count -gt 0 ]; then
        log_success "Terminated $count instance(s)"
    fi
}

# ===========================
# KEY PAIR CLEANUP (FROM STATE)
# ===========================

delete_local_pem_file() {
    local key_name="$1"
    local pem_file="${key_name}.pem"
    
    if [ ! -f "$pem_file" ]; then
        return 0
    fi
    
    if dry_run_guard "Would delete local file: $pem_file"; then
        return 0
    fi
    
    rm -f "$pem_file"
    ((DELETED_LOCAL_FILES++))
    log_success "    Removed local file: $pem_file"
}

delete_key_pairs_from_state() {
    log_info "Deleting key pairs from state file"
    
    # Get key pairs from state
    local key_pairs=$(get_key_pairs)
    
    if [ -z "$key_pairs" ]; then
        log_info "  No key pairs in state"
        return 0
    fi
    
    local count=0
    while IFS= read -r key_json; do
        [ -z "$key_json" ] && continue
        
        local key_name=$(echo "$key_json" | jq -r '.key_name')
        local key_region=$(echo "$key_json" | jq -r '.region // "eu-west-1"')
        
        log_info "  Found: $key_name in $key_region"
        
        if dry_run_guard "Would delete key pair: $key_name in $key_region"; then
            ((count++))
            delete_local_pem_file "$key_name"
            continue
        fi
        
        # Delete from AWS
        if aws ec2 delete-key-pair \
            --key-name "$key_name" \
            --region "$key_region" \
            2>> "$LOG_FILE"; then
            
            log_success "  Deleted: $key_name"
            
            # Remove from state
            remove_key_pair "$key_name"
            
            # Remove local .pem file
            delete_local_pem_file "$key_name"
            
            ((count++))
        else
            log_warn "  Could not delete key pair: $key_name (may not exist)"
            # Still remove from state since it's gone
            remove_key_pair "$key_name"
        fi
    done <<< "$key_pairs"
    
    DELETED_KEY_PAIRS=$count
    
    if [ $count -gt 0 ]; then
        log_success "Deleted $count key pair(s)"
    fi
}

# ===========================
# SECURITY GROUP CLEANUP (FROM STATE)
# ===========================

delete_security_groups_from_state() {
    log_info "Deleting security groups from state file"
    
    # Wait a bit for instances to fully terminate
    if [ "$DELETED_INSTANCES" -gt 0 ]; then
        log_info "  Waiting 5 seconds for instances to release security groups..."
        sleep 5
    fi
    
    # Get security groups from state
    local security_groups=$(get_security_groups)
    
    if [ -z "$security_groups" ]; then
        log_info "  No security groups in state"
        return 0
    fi
    
    local count=0
    while IFS= read -r sg_json; do
        [ -z "$sg_json" ] && continue
        
        local sg_id=$(echo "$sg_json" | jq -r '.group_id')
        local sg_name=$(echo "$sg_json" | jq -r '.group_name // "Unknown"')
        local sg_region=$(echo "$sg_json" | jq -r '.region // "eu-west-1"')
        
        # Skip default security groups
        if [ "$sg_name" = "default" ]; then
            log_info "  Skipping default security group: $sg_id"
            remove_security_group "$sg_id"
            continue
        fi
        
        log_info "  Found: $sg_id ($sg_name) in $sg_region"
        
        if dry_run_guard "Would delete security group: $sg_id in $sg_region"; then
            ((count++))
            continue
        fi
        
        # Delete from AWS
        if aws ec2 delete-security-group \
            --group-id "$sg_id" \
            --region "$sg_region" \
            2>> "$LOG_FILE"; then
            
            log_success "  Deleted: $sg_id ($sg_name)"
            
            # Remove from state
            remove_security_group "$sg_id"
            
            ((count++))
        else
            log_warn "  Could not delete: $sg_id (may have dependencies or not exist)"
            # Try to check if it exists
            if ! aws ec2 describe-security-groups \
                --group-ids "$sg_id" \
                --region "$sg_region" \
                >> "$LOG_FILE" 2>&1; then
                log_info "    Security group doesn't exist, removing from state"
                remove_security_group "$sg_id"
            fi
        fi
    done <<< "$security_groups"
    
    DELETED_SECURITY_GROUPS=$count
    
    if [ $count -gt 0 ]; then
        log_success "Deleted $count security group(s)"
    fi
}

# ===========================
# S3 BUCKET CLEANUP (FROM STATE)
# ===========================

get_bucket_region() {
    local bucket="$1"
    
    if dry_run_guard "Would get bucket region for $bucket" >&2; then
        echo "us-east-1"
        return 0
    fi
    
    local region=$(aws s3api get-bucket-location \
        --bucket "$bucket" \
        --query 'LocationConstraint' \
        --output text 2>> "$LOG_FILE" || echo "us-east-1")
    
    # AWS returns "None" for us-east-1
    [ "$region" = "None" ] || [ -z "$region" ] && region="us-east-1"
    
    echo "$region"
}

empty_and_delete_bucket() {
    local bucket="$1"
    local bucket_region="$2"
    
    if dry_run_guard "Would empty and delete bucket: $bucket"; then
        return 0
    fi
    
    log_info "    Emptying bucket contents..."
    
    # Remove bucket policy and configurations
    aws s3api delete-bucket-policy --bucket "$bucket" --region "$bucket_region" >> "$LOG_FILE" 2>&1 || true
    aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Suspended --region "$bucket_region" >> "$LOG_FILE" 2>&1 || true
    
    # Empty bucket contents
    aws s3 rm "s3://$bucket" --recursive --region "$bucket_region" >> "$LOG_FILE" 2>&1 || true
    
    # Delete versioned objects if jq is available
    if command -v jq &> /dev/null; then
        log_info "    Removing versioned objects..."
        
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
    fi
    
    # Delete bucket
    if aws s3api delete-bucket --bucket "$bucket" --region "$bucket_region" 2>> "$LOG_FILE"; then
        log_success "  Deleted bucket: $bucket"
        return 0
    else
        log_warn "  Could not delete bucket: $bucket"
        return 1
    fi
}

delete_s3_buckets_from_state() {
    log_info "Deleting S3 buckets from state file"
    
    # Get buckets from state
    local buckets=$(get_s3_buckets)
    
    if [ -z "$buckets" ]; then
        log_info "  No S3 buckets in state"
        return 0
    fi
    
    local count=0
    while IFS= read -r bucket_json; do
        [ -z "$bucket_json" ] && continue
        
        local bucket_name=$(echo "$bucket_json" | jq -r '.bucket_name')
        local bucket_region=$(echo "$bucket_json" | jq -r '.region // "us-east-1"')
        
        log_info "  Found: $bucket_name in $bucket_region"
        
        # Verify region from AWS (state might be outdated)
        if [ "$DRY_RUN" != "true" ]; then
            local actual_region=$(get_bucket_region "$bucket_name")
            if [ -n "$actual_region" ] && [ "$actual_region" != "$bucket_region" ]; then
                log_info "    Updating region: $bucket_region -> $actual_region"
                bucket_region="$actual_region"
            fi
        fi
        
        if empty_and_delete_bucket "$bucket_name" "$bucket_region"; then
            # Remove from state
            remove_s3_bucket "$bucket_name"
            ((count++))
        else
            # Check if bucket exists
            if ! aws s3api head-bucket --bucket "$bucket_name" --region "$bucket_region" 2>> "$LOG_FILE"; then
                log_info "    Bucket doesn't exist, removing from state"
                remove_s3_bucket "$bucket_name"
            fi
        fi
    done <<< "$buckets"
    
    DELETED_BUCKETS=$count
    
    if [ $count -gt 0 ]; then
        log_success "Deleted $count bucket(s)"
    fi
}

# ===========================
# LOCAL FILE CLEANUP
# ===========================

cleanup_local_files() {
    log_info "Cleaning up local files"
    
    local files_deleted=0
    
    # Clean welcome files
    for file in welcome*.txt; do
        [ -f "$file" ] || continue
        
        if dry_run_guard "Would delete: $file"; then
            ((files_deleted++))
            continue
        fi
        
        rm -f "$file"
        log_success "  Removed: $file"
        ((files_deleted++))
    done
    
    # Clean .pem files not already deleted
    for file in *.pem; do
        [ -f "$file" ] || continue
        
        if dry_run_guard "Would delete: $file"; then
            ((files_deleted++))
            continue
        fi
        
        rm -f "$file"
        log_success "  Removed: $file"
        ((files_deleted++))
    done
    
    DELETED_LOCAL_FILES=$((DELETED_LOCAL_FILES + files_deleted))
    
    if [ $files_deleted -eq 0 ]; then
        log_info "  No additional local files to clean"
    else
        log_success "  Cleaned up $files_deleted additional file(s)"
    fi
}

# ===========================
# CONFIRMATION & SUMMARY
# ===========================

show_cleanup_preview() {
    print_header "⚠️  RESOURCE DELETION PREVIEW"
    
    # Count resources from state
    local ec2_count=$(echo "$STATE_JSON" | jq '.ec2_instances | length' 2>/dev/null || echo 0)
    local key_count=$(echo "$STATE_JSON" | jq '.key_pairs | length' 2>/dev/null || echo 0)
    local sg_count=$(echo "$STATE_JSON" | jq '.security_groups | length' 2>/dev/null || echo 0)
    local s3_count=$(echo "$STATE_JSON" | jq '.s3_buckets | length' 2>/dev/null || echo 0)
    
    cat <<EOF

This script will DELETE resources tracked in the state file:

RESOURCES TO BE DELETED:
  ✗ EC2 Instances:     $ec2_count
  ✗ Key Pairs:         $key_count
  ✗ Security Groups:   $sg_count
  ✗ S3 Buckets:        $s3_count
  ✗ Local files:       (*.pem, welcome*.txt)

State file location:
  s3://$STATE_BUCKET/$STATE_FILE

⚠️  THIS ACTION CANNOT BE UNDONE! ⚠️

EOF
    
    if [ "$DRY_RUN" = "true" ]; then
        echo "🔍 DRY-RUN MODE: No resources will be deleted"
        echo ""
    fi
    
    # Show detailed list
    if [ $ec2_count -gt 0 ]; then
        echo "EC2 Instances:"
        get_ec2_instances | while IFS= read -r instance; do
            [ -z "$instance" ] && continue
            local id=$(echo "$instance" | jq -r '.instance_id')
            local name=$(echo "$instance" | jq -r '.name // "Unknown"')
            local region=$(echo "$instance" | jq -r '.region')
            echo "  - $id ($name) in $region"
        done
        echo ""
    fi
    
    if [ $key_count -gt 0 ]; then
        echo "Key Pairs:"
        get_key_pairs | while IFS= read -r key; do
            [ -z "$key" ] && continue
            local name=$(echo "$key" | jq -r '.key_name')
            local region=$(echo "$key" | jq -r '.region')
            echo "  - $name in $region"
        done
        echo ""
    fi
    
    if [ $sg_count -gt 0 ]; then
        echo "Security Groups:"
        get_security_groups | while IFS= read -r sg; do
            [ -z "$sg" ] && continue
            local id=$(echo "$sg" | jq -r '.group_id')
            local name=$(echo "$sg" | jq -r '.group_name // "Unknown"')
            local region=$(echo "$sg" | jq -r '.region')
            echo "  - $id ($name) in $region"
        done
        echo ""
    fi
    
    if [ $s3_count -gt 0 ]; then
        echo "S3 Buckets:"
        get_s3_buckets | while IFS= read -r bucket; do
            [ -z "$bucket" ] && continue
            local name=$(echo "$bucket" | jq -r '.bucket_name')
            local region=$(echo "$bucket" | jq -r '.region')
            echo "  - $name in $region"
        done
        echo ""
    fi
}

display_summary() {
    print_header "Cleanup Summary"
    
    local total=$((DELETED_INSTANCES + DELETED_KEY_PAIRS + DELETED_SECURITY_GROUPS + DELETED_BUCKETS + DELETED_LOCAL_FILES))
    
    cat <<EOF
Completed: $(date)
Dry-Run: $DRY_RUN

Resources Deleted:
  EC2 Instances:      $DELETED_INSTANCES
  Key Pairs:          $DELETED_KEY_PAIRS
  Security Groups:    $DELETED_SECURITY_GROUPS
  S3 Buckets:         $DELETED_BUCKETS
  Local Files:        $DELETED_LOCAL_FILES
  
  Total:              $total

State file: s3://$STATE_BUCKET/$STATE_FILE
Log file: $LOG_FILE
==========================================
EOF
    
    if [ "$DRY_RUN" = "true" ]; then
        echo ""
        log_info "This was a dry-run. No resources were actually deleted."
        echo "Run without --dry-run to perform actual cleanup."
    fi
}

# ===========================
# ARGUMENT PARSING
# ===========================

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Clean up AWS resources tracked in the state file.

OPTIONS:
  -d, --dry-run              Preview mode - no actual changes
  -y, --yes                  Skip confirmation prompt
  -h, --help                 Show this help message

ENVIRONMENT VARIABLES:
  DRY_RUN                    Enable dry-run mode (true/false)
  SKIP_CONFIRMATION          Skip confirmation (true/false)
  STATE_BUCKET               S3 bucket for state file
  STATE_FILE                 State file name

EXAMPLES:
  $SCRIPT_NAME --dry-run     # Preview what would be deleted
  $SCRIPT_NAME --yes         # Delete without confirmation
  
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
            --yes|-y)
                export SKIP_CONFIRMATION=true
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
    print_header "AWS Resource Cleanup Script (State-Based)"
    
    # Load existing state
    load_state
    
    # Validate prerequisites
    require_command "aws" "Install from: https://aws.amazon.com/cli/"
    require_command "jq" "Install from: https://stedolan.github.io/jq/"
    
    # Verify credentials
    verify_aws_credentials "$REGION"
    
    # Show what will be deleted
    show_cleanup_preview
    
    # Confirm
    if [ "$SKIP_CONFIRMATION" != "true" ]; then
        confirm_action "Do you want to proceed with deletion?" "DELETE"
    fi
    
    echo ""
    
    # Execute cleanup
    print_header "Starting Cleanup"
    
    log_info "[1/5] Terminating EC2 instances..."
    terminate_instances_from_state
    echo ""
    
    log_info "[2/5] Deleting key pairs..."
    delete_key_pairs_from_state
    echo ""
    
    log_info "[3/5] Deleting security groups..."
    delete_security_groups_from_state
    echo ""
    
    log_info "[4/5] Deleting S3 buckets..."
    delete_s3_buckets_from_state
    echo ""
    
    log_info "[5/5] Cleaning local files..."
    cleanup_local_files
    echo ""
    
    # Display summary
    display_summary
    
    log_success "Cleanup completed successfully!"
}

# Run main function
main "$@"