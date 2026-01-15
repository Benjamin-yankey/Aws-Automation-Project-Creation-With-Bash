#!/usr/bin/env bash
set -euo pipefail

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prevent double-sourcing
if [ -n "${COMMON_UTILS_LOADED:-}" ]; then
    : # Already loaded, skip
elif [ -f "${SCRIPT_DIR}/lib/common_utils.sh" ]; then
    source "${SCRIPT_DIR}/lib/common_utils.sh"
    export COMMON_UTILS_LOADED=true
else
    echo "Error: common_utils.sh not found in ${SCRIPT_DIR}/lib" >&2
    exit 1
fi

# ===========================
# CONFIGURATION
# ===========================
REGION="${REGION:-eu-west-1}"
STATE_BUCKET="${STATE_BUCKET:-myproject-infra-state}"
STATE_FILE="${STATE_FILE:-aws_state.json}"

STATE_JSON="{}"

# ===========================
# STATE INITIALIZATION
# ===========================

# Initialize state with empty arrays if needed
init_state_structure() {
    STATE_JSON=$(echo "$STATE_JSON" | jq -c '
        # Initialize arrays if null
        if .ec2_instances == null then .ec2_instances = [] else . end |
        if .security_groups == null then .security_groups = [] else . end |
        if .s3_buckets == null then .s3_buckets = [] else . end |
        if .key_pairs == null then .key_pairs = [] else . end |
        if .timestamp == null then .timestamp = now else . end |
        
        # Migrate old string-based arrays to object-based arrays
        # EC2 instances: if array contains strings, convert to objects
        if (.ec2_instances | length > 0) and (.ec2_instances[0] | type == "string") then
            .ec2_instances = [.ec2_instances[] | {
                instance_id: .,
                name: "Unknown",
                instance_type: "unknown",
                key_pair: "unknown",
                security_groups: [],
                region: "'"$REGION"'",
                state: "unknown",
                created_at: now
            }]
        else . end |
        
        # Security groups: if array contains strings, convert to objects
        if (.security_groups | length > 0) and (.security_groups[0] | type == "string") then
            .security_groups = [.security_groups[] | {
                group_id: .,
                group_name: "unknown",
                vpc_id: "unknown",
                region: "'"$REGION"'",
                created_at: now
            }]
        else . end |
        
        # S3 buckets: if array contains strings, convert to objects
        if (.s3_buckets | length > 0) and (.s3_buckets[0] | type == "string") then
            .s3_buckets = [.s3_buckets[] | {
                bucket_name: .,
                region: "'"$REGION"'",
                created_at: now
            }]
        else . end |
        
        # Key pairs: if array contains strings, convert to objects
        if (.key_pairs | length > 0) and (.key_pairs[0] | type == "string") then
            .key_pairs = [.key_pairs[] | {
                key_name: .,
                region: "'"$REGION"'",
                created_at: now
            }]
        else . end
    ')
}

# ===========================
# STATE LOADING
# ===========================

# Check if bucket exists
bucket_exists() {
    local bucket="$1"
    local region="$2"
    
    if dry_run_guard "Would check if bucket $bucket exists" >&2; then
        return 1
    fi
    
    aws s3api head-bucket --bucket "$bucket" --region "$region" &>/dev/null
}

# Check if state file exists
state_file_exists() {
    local bucket="$1"
    local key="$2"
    local region="$3"
    
    if dry_run_guard "Would check if state file exists" >&2; then
        return 1
    fi
    
    aws s3api head-object --bucket "$bucket" --key "$key" --region "$region" &>/dev/null
}

load_state() {
    log_info "Loading state from s3://$STATE_BUCKET/$STATE_FILE"
    
    # Note: We always load state, even in dry-run mode
    # Dry-run only prevents modifications, not reading
    
    if ! bucket_exists "$STATE_BUCKET" "$REGION"; then
        log_warn "State bucket does not exist, starting with empty state"
        STATE_JSON='{}'
        init_state_structure
        return 0
    fi

    if ! state_file_exists "$STATE_BUCKET" "$STATE_FILE" "$REGION"; then
        log_warn "State file does not exist, starting with empty state"
        STATE_JSON='{}'
        init_state_structure
        return 0
    fi

    # Load state from S3
    local loaded_state=$(aws s3 cp "s3://$STATE_BUCKET/$STATE_FILE" - --region "$REGION" 2>> "${LOG_FILE:-/dev/null}")
    
    # Validate it's proper JSON
    if echo "$loaded_state" | jq empty 2>/dev/null; then
        STATE_JSON="$loaded_state"
    else
        log_warn "Loaded state is not valid JSON, starting fresh"
        STATE_JSON='{}'
    fi
    
    # Ensure state has proper structure
    init_state_structure
    
    log_success "State loaded from s3://$STATE_BUCKET/$STATE_FILE"
}

# ===========================
# STATE SAVING
# ===========================

# Create state bucket if it doesn't exist
ensure_state_bucket() {
    log_info "Ensuring state bucket exists: $STATE_BUCKET"
    
    if dry_run_guard "Would ensure state bucket exists"; then
        return 0
    fi

    if bucket_exists "$STATE_BUCKET" "$REGION"; then
        log_info "State bucket already exists"
        return 0
    fi

    log_info "Creating state bucket: $STATE_BUCKET"
    
    if [ "$REGION" = "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket "$STATE_BUCKET" \
            --region "$REGION" \
            2>> "${LOG_FILE:-/dev/null}"
    else
        aws s3api create-bucket \
            --bucket "$STATE_BUCKET" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION" \
            2>> "${LOG_FILE:-/dev/null}"
    fi

    aws s3api put-bucket-versioning \
        --bucket "$STATE_BUCKET" \
        --region "$REGION" \
        --versioning-configuration Status=Enabled \
        2>> "${LOG_FILE:-/dev/null}"

    log_success "State bucket created with versioning enabled"
}

save_state() {
    log_info "Saving state to s3://$STATE_BUCKET/$STATE_FILE"
    
    if dry_run_guard "Would save state"; then
        echo "$STATE_JSON" | jq . 2>/dev/null || echo "$STATE_JSON"
        return 0
    fi

    ensure_state_bucket

    echo "$STATE_JSON" | aws s3 cp - "s3://$STATE_BUCKET/$STATE_FILE" --region "$REGION" 2>> "${LOG_FILE:-/dev/null}"
    log_success "State saved successfully"
}

# ===========================
# EC2 INSTANCE MANAGEMENT
# ===========================

add_ec2_instance() {
    local instance_id="$1"
    local name="$2"
    local instance_type="$3"
    local key_pair="$4"
    local security_groups="$5"   # JSON array string
    local state="${6:-running}"

    log_info "Registering EC2 instance: $instance_id"
    
    if dry_run_guard "Would add EC2 instance $instance_id to state"; then
        return 0
    fi

    # Ensure STATE_JSON is valid JSON before processing
    if ! echo "$STATE_JSON" | jq empty 2>/dev/null; then
        log_warn "STATE_JSON is not valid JSON, reinitializing"
        STATE_JSON='{}'
        init_state_structure
    fi

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg id "$instance_id" \
        --arg name "$name" \
        --arg type "$instance_type" \
        --arg key "$key_pair" \
        --argjson sgs "$security_groups" \
        --arg region "$REGION" \
        --arg state "$state" \
        '
        # Ensure ec2_instances array exists
        if .ec2_instances == null then .ec2_instances = [] else . end |
        .ec2_instances += [{
            instance_id: $id,
            name: $name,
            instance_type: $type,
            key_pair: $key,
            security_groups: $sgs,
            region: $region,
            state: $state,
            created_at: now
        }]
        | .ec2_instances |= unique_by(.instance_id)
        | .timestamp = now
        '
    )

    log_success "EC2 instance registered: $instance_id (key=$key_pair)"
    save_state
}

remove_ec2_instance() {
    local instance_id="$1"

    log_info "Removing EC2 instance from state: $instance_id"
    
    if dry_run_guard "Would remove EC2 instance $instance_id from state"; then
        return 0
    fi

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg id "$instance_id" '
        .ec2_instances |= map(select(.instance_id != $id))
        | .timestamp = now
        '
    )

    log_success "EC2 instance removed: $instance_id"
    save_state
}

get_ec2_instances() {
    echo "$STATE_JSON" | jq -r '.ec2_instances[]? | @json' 2>/dev/null || echo ""
}

# ===========================
# SECURITY GROUP MANAGEMENT
# ===========================

add_security_group() {
    local sg_id="$1"
    local sg_name="${2:-}"
    local vpc_id="${3:-}"

    log_info "Registering security group: $sg_id"
    
    if dry_run_guard "Would add security group $sg_id to state"; then
        return 0
    fi

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg id "$sg_id" \
        --arg name "$sg_name" \
        --arg vpc "$vpc_id" \
        --arg region "$REGION" \
        '
        .security_groups += [{
            group_id: $id,
            group_name: $name,
            vpc_id: $vpc,
            region: $region,
            created_at: now
        }]
        | .security_groups |= unique_by(.group_id)
        | .timestamp = now
        '
    )

    log_success "Security group registered: $sg_id"
    save_state
}

remove_security_group() {
    local sg_id="$1"

    log_info "Removing security group from state: $sg_id"
    
    if dry_run_guard "Would remove security group $sg_id from state"; then
        return 0
    fi

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg id "$sg_id" '
        .security_groups |= map(select(.group_id != $id))
        | .timestamp = now
        '
    )

    log_success "Security group removed: $sg_id"
    save_state
}

get_security_groups() {
    echo "$STATE_JSON" | jq -r '.security_groups[]? | @json' 2>/dev/null || echo ""
}

# ===========================
# S3 BUCKET MANAGEMENT
# ===========================

add_s3_bucket() {
    local bucket="$1"
    local bucket_region="${2:-$REGION}"

    log_info "Registering S3 bucket: $bucket"
    
    if dry_run_guard "Would add S3 bucket $bucket to state"; then
        return 0
    fi

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg bucket "$bucket" \
        --arg region "$bucket_region" \
        '
        .s3_buckets += [{
            bucket_name: $bucket,
            region: $region,
            created_at: now
        }]
        | .s3_buckets |= unique_by(.bucket_name)
        | .timestamp = now
        '
    )

    log_success "S3 bucket registered: $bucket"
    save_state
}

remove_s3_bucket() {
    local bucket="$1"

    log_info "Removing S3 bucket from state: $bucket"
    
    if dry_run_guard "Would remove S3 bucket $bucket from state"; then
        return 0
    fi

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg bucket "$bucket" '
        .s3_buckets |= map(select(.bucket_name != $bucket))
        | .timestamp = now
        '
    )

    log_success "S3 bucket removed: $bucket"
    save_state
}

get_s3_buckets() {
    echo "$STATE_JSON" | jq -r '.s3_buckets[]? | @json' 2>/dev/null || echo ""
}

# ===========================
# KEY PAIR MANAGEMENT
# ===========================

add_key_pair() {
    local key_name="$1"
    local key_region="${2:-$REGION}"

    log_info "Registering key pair: $key_name"
    
    if dry_run_guard "Would add key pair $key_name to state"; then
        return 0
    fi

    # Ensure STATE_JSON is valid JSON before processing
    if ! echo "$STATE_JSON" | jq empty 2>/dev/null; then
        log_warn "STATE_JSON is not valid JSON, reinitializing"
        STATE_JSON='{}'
        init_state_structure
    fi

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg key "$key_name" \
        --arg region "$key_region" \
        '
        # Ensure key_pairs array exists
        if .key_pairs == null then .key_pairs = [] else . end |
        .key_pairs += [{
            key_name: $key,
            region: $region,
            created_at: now
        }]
        | .key_pairs |= unique_by(.key_name)
        | .timestamp = now
        '
    )

    log_success "Key pair registered: $key_name"
    save_state
}

remove_key_pair() {
    local key_name="$1"

    log_info "Removing key pair from state: $key_name"
    
    if dry_run_guard "Would remove key pair $key_name from state"; then
        return 0
    fi

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg key "$key_name" '
        .key_pairs |= map(select(.key_name != $key))
        | .timestamp = now
        '
    )

    log_success "Key pair removed: $key_name"
    save_state
}

get_key_pairs() {
    echo "$STATE_JSON" | jq -r '.key_pairs[]? | @json' 2>/dev/null || echo ""
}

# ===========================
# STATE QUERIES
# ===========================

show_state() {
    log_info "Current state:"
    echo "$STATE_JSON" | jq . 2>/dev/null || echo "$STATE_JSON"
}

get_state_summary() {
    local ec2_count=$(echo "$STATE_JSON" | jq '.ec2_instances | length' 2>/dev/null || echo 0)
    local sg_count=$(echo "$STATE_JSON" | jq '.security_groups | length' 2>/dev/null || echo 0)
    local s3_count=$(echo "$STATE_JSON" | jq '.s3_buckets | length' 2>/dev/null || echo 0)
    local key_count=$(echo "$STATE_JSON" | jq '.key_pairs | length' 2>/dev/null || echo 0)
    
    cat <<EOF
State Summary:
  EC2 Instances:    $ec2_count
  Security Groups:  $sg_count
  S3 Buckets:       $s3_count
  Key Pairs:        $key_count
EOF
}