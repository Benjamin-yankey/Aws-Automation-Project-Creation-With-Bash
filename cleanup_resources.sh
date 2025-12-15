#!/usr/bin/env bash


# Script: cleanup_resources.sh
# Purpose: Clean up all AWS resources with logging and safety checks
# Author: DevOps Automation Lab
# Date: December 2025

set -euo pipefail

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_NAME="cleanup_resources.sh"
LOG_DIR="./logs"
LOG_FILE="${LOG_DIR}/cleanup_$(date +%Y%m%d_%H%M%S).log"
PROJECT_TAG="AutomationLab"

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

# Print error message
print_error() {
    local message="$1"
    echo "✗ ERROR: $message" | tee -a "$LOG_FILE"
    log "ERROR" "$message"
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
        exit 1
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
    echo "  5. All regions"
    echo "  6. Custom region"
    echo ""
    
    read -p "Enter region number or press Enter for eu-west-1 [$default_region]: " region_choice
    
    case "$region_choice" in
        1|"") REGION="eu-west-1" ;;
        2) REGION="us-east-1" ;;
        3) REGION="us-west-2" ;;
        4) REGION="ap-southeast-1" ;;
        5) REGION="all" ;;
        6)
            read -p "Enter custom region: " REGION
            ;;
        *)
            REGION="$default_region"
            ;;
    esac
    
    log "INFO" "Selected region: $REGION"
    print_info "Selected region: $REGION"
}

# Get list of regions to clean
get_regions_list() {
    if [ "$REGION" == "all" ]; then
        REGIONS=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>> "$LOG_FILE")
        log "INFO" "Will clean all regions: $REGIONS"
    else
        REGIONS="$REGION"
        log "INFO" "Will clean region: $REGIONS"
    fi
}

# Verify AWS credentials
verify_credentials() {
    log "INFO" "Verifying AWS credentials"
    
    if ! aws sts get-caller-identity >> "$LOG_FILE" 2>&1; then
        print_error "AWS credentials are not configured properly"
        exit 1
    fi
    
    print_success "AWS credentials verified"
}

# Confirm cleanup
confirm_cleanup() {
    print_header "WARNING: Resource Cleanup"
    
    cat <<EOF
This script will DELETE the following resources tagged with Project=$PROJECT_TAG:
  - EC2 instances
  - EC2 key pairs
  - Security groups
  - S3 buckets (and all contents)
  - Local files (*.pem, welcome.txt)

Region(s): $REGION

⚠ THIS ACTION CANNOT BE UNDONE! ⚠
EOF
    
    echo ""
    read -p "Are you absolutely sure you want to continue? (type 'yes' to confirm): " CONFIRM
    
    if [ "$CONFIRM" != "yes" ]; then
        log "INFO" "Cleanup cancelled by user"
        echo "Cleanup cancelled."
        exit 0
    fi
    
    log "INFO" "User confirmed cleanup"
    print_info "Starting cleanup process..."
}

# Terminate EC2 instances
terminate_instances() {
    local region="$1"
    
    log "INFO" "Checking for EC2 instances in $region"
    
    local instance_ids=$(aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=tag:Project,Values=$PROJECT_TAG" \
                  "Name=instance-state-name,Values=running,stopped,stopping,pending" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text 2>> "$LOG_FILE" || echo "")
    
    if [ -z "$instance_ids" ]; then
        print_info "  No EC2 instances found in $region"
        return
    fi
    
    print_info "  Found instances in $region: $instance_ids"
    
    if aws ec2 terminate-instances \
        --instance-ids $instance_ids \
        --region "$region" >> "$LOG_FILE" 2>&1; then
        
        print_info "  ⏳ Waiting for instances to terminate..."
        aws ec2 wait instance-terminated \
            --instance-ids $instance_ids \
            --region "$region" 2>> "$LOG_FILE" || true
        
        print_success "  EC2 instances terminated in $region"
    else
        print_error "  Failed to terminate instances in $region"
    fi
}

# Delete key pairs
delete_key_pairs() {
    local region="$1"
    
    log "INFO" "Checking for key pairs in $region"
    
    local key_pairs=$(aws ec2 describe-key-pairs \
        --region "$region" \
        --query 'KeyPairs[?starts_with(KeyName, `devops-keypair`)].KeyName' \
        --output text 2>> "$LOG_FILE" || echo "")
    
    if [ -z "$key_pairs" ]; then
        print_info "  No key pairs found in $region"
        return
    fi
    
    for key in $key_pairs; do
        if aws ec2 delete-key-pair \
            --key-name "$key" \
            --region "$region" 2>> "$LOG_FILE"; then
            print_success "  Deleted key pair: $key"
            
            # Remove local .pem file if exists
            if [ -f "${key}.pem" ]; then
                rm -f "${key}.pem"
                print_success "  Removed local file: ${key}.pem"
            fi
        else
            print_warning "  Could not delete key pair: $key"
        fi
    done
}

# Delete security groups
delete_security_groups() {
    local region="$1"
    
    log "INFO" "Checking for security groups in $region"
    
    # Wait a bit to ensure instances are fully terminated
    sleep 5
    
    local sg_ids=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=tag:Project,Values=$PROJECT_TAG" \
        --query 'SecurityGroups[*].GroupId' \
        --output text 2>> "$LOG_FILE" || echo "")
    
    if [ -z "$sg_ids" ]; then
        print_info "  No security groups found in $region"
        return
    fi
    
    for sg_id in $sg_ids; do
        if aws ec2 delete-security-group \
            --group-id "$sg_id" \
            --region "$region" 2>> "$LOG_FILE"; then
            print_success "  Deleted security group: $sg_id"
        else
            print_warning "  Could not delete security group: $sg_id may have dependencies"
        fi
    done
}

# Delete S3 buckets
delete_s3_buckets() {
    log "INFO" "Checking for S3 buckets"
    
    local buckets=$(aws s3api list-buckets \
        --query 'Buckets[?starts_with(Name, `devops-automation-lab`)].Name' \
        --output text 2>> "$LOG_FILE" || echo "")
    
    if [ -z "$buckets" ]; then
        print_info "  No S3 buckets found"
        return
    fi
    
    for bucket in $buckets; do
        # Get bucket region
        local bucket_region=$(aws s3api get-bucket-location \
            --bucket "$bucket" \
            --query 'LocationConstraint' \
            --output text 2>> "$LOG_FILE" || echo "us-east-1")
        
        # Handle us-east-1 (returns null)
        if [ "$bucket_region" == "None" ] || [ -z "$bucket_region" ]; then
            bucket_region="us-east-1"
        fi
        
        # Check if we should clean this bucket based on region filter
        if [ "$REGION" != "all" ] && [ "$REGION" != "$bucket_region" ]; then
            print_info "  Skipping bucket $bucket in $bucket_region"
            continue
        fi
        
        # Verify it has the right tags or name pattern
        local has_project_tag=$(aws s3api get-bucket-tagging \
            --bucket "$bucket" 2>> "$LOG_FILE" | grep -o "$PROJECT_TAG" || echo "")
        
        if [ -n "$has_project_tag" ] || [[ "$bucket" == devops-automation-lab* ]]; then
            print_info "  Emptying bucket: $bucket"
            
            # Delete all versions
            aws s3api list-object-versions \
                --bucket "$bucket" \
                --output json \
                --query 'Versions[].{Key:Key,VersionId:VersionId}' 2>> "$LOG_FILE" | \
            jq -c '.[]' 2>> "$LOG_FILE" | \
            while read -r obj; do
                local key=$(echo "$obj" | jq -r '.Key')
                local version=$(echo "$obj" | jq -r '.VersionId')
                aws s3api delete-object \
                    --bucket "$bucket" \
                    --key "$key" \
                    --version-id "$version" >> "$LOG_FILE" 2>&1 || true
            done
            
            # Delete all delete markers
            aws s3api list-object-versions \
                --bucket "$bucket" \
                --output json \
                --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' 2>> "$LOG_FILE" | \
            jq -c '.[]' 2>> "$LOG_FILE" | \
            while read -r obj; do
                local key=$(echo "$obj" | jq -r '.Key')
                local version=$(echo "$obj" | jq -r '.VersionId')
                aws s3api delete-object \
                    --bucket "$bucket" \
                    --key "$key" \
                    --version-id "$version" >> "$LOG_FILE" 2>&1 || true
            done
            
            # Fallback: force delete with s3 rb
            aws s3 rb "s3://$bucket" --force >> "$LOG_FILE" 2>&1 || true
            
            # Delete the bucket
            if aws s3api delete-bucket \
                --bucket "$bucket" 2>> "$LOG_FILE"; then
                print_success "  Deleted bucket: $bucket"
            else
                print_warning "  Could not delete bucket: $bucket"
            fi
        fi
    done
}

# Clean up local files
cleanup_local_files() {
    log "INFO" "Cleaning up local files"
    
    local files_deleted=0
    
    # Remove welcome.txt
    if [ -f "welcome.txt" ]; then
        rm -f welcome.txt
        print_success "  Removed welcome.txt"
        ((files_deleted++))
    fi
    
    # Remove any remaining .pem files
    for pem_file in devops-keypair-*.pem; do
        if [ -f "$pem_file" ]; then
            rm -f "$pem_file"
            print_success "  Removed $pem_file"
            ((files_deleted++))
        fi
    done
    
    if [ $files_deleted -eq 0 ]; then
        print_info "  No local files to clean"
    else
        print_success "  Cleaned up $files_deleted local file(s)"
    fi
}

# Display summary
display_summary() {
    print_header "Cleanup Complete!"
    
    cat <<EOF | tee -a "$LOG_FILE"
Summary of cleanup actions:
  ✓ EC2 instances terminated
  ✓ Key pairs deleted
  ✓ Security groups removed
  ✓ S3 buckets emptied and deleted
  ✓ Local files cleaned up

Region(s) cleaned: $REGION
Project tag: $PROJECT_TAG

Log file saved to: $LOG_FILE
==========================================
EOF
}

# ===========================
# MAIN EXECUTION
# ===========================
main() {
    # Initialize
    init_logging
    print_header "AWS Resource Cleanup Script"
    
    # Validate and setup
    validate_aws_cli
    get_region
    get_regions_list
    verify_credentials
    confirm_cleanup
    
    echo ""
    
    # Clean resources in each region
    for current_region in $REGIONS; do
        print_header "Cleaning region: $current_region"
        
        print_info "[1/3] Terminating EC2 instances..."
        terminate_instances "$current_region"
        
        print_info "[2/3] Deleting key pairs..."
        delete_key_pairs "$current_region"
        
        print_info "[3/3] Deleting security groups..."
        delete_security_groups "$current_region"
    done
    
    # S3 buckets (region-aware but handled separately)
    print_header "Cleaning S3 Buckets"
    print_info "[4/4] Deleting S3 buckets..."
    delete_s3_buckets
    
    # Local cleanup
    print_header "Local Cleanup"
    print_info "[5/5] Cleaning up local files..."
    cleanup_local_files
    
    # Display summary
    display_summary
    
    log "SUCCESS" "Cleanup completed successfully"
}

# Run main function
main "$@"