#!/usr/bin/env bash
set -euo pipefail

# ===========================
# CONFIGURATION
# ===========================
REGION="${REGION:-eu-west-1}"
STATE_BUCKET="${STATE_BUCKET:-myproject-infra-state}"
STATE_FILE="${STATE_FILE:-aws_state.json}"
DRY_RUN="${DRY_RUN:-false}"

STATE_JSON="{}"

# ===========================
# LOGGING
# ===========================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

aws_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] aws $*"
    else
        aws "$@"
    fi
}

# ===========================
# STATE HANDLING
# ===========================
load_state() {
    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would load state from s3://$STATE_BUCKET/$STATE_FILE"
        return
    fi

    if ! aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$REGION" &>/dev/null; then
        STATE_JSON='{}'
        return
    fi

    if ! aws s3api head-object --bucket "$STATE_BUCKET" --key "$STATE_FILE" --region "$REGION" &>/dev/null; then
        STATE_JSON='{}'
        return
    fi

    STATE_JSON=$(aws s3 cp "s3://$STATE_BUCKET/$STATE_FILE" - --region "$REGION")
    log "State loaded from s3://$STATE_BUCKET/$STATE_FILE"
}

save_state() {
    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would save state"
        echo "$STATE_JSON" | jq .
        return
    fi

    if ! aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$REGION" &>/dev/null; then
        aws_cmd s3api create-bucket \
            --bucket "$STATE_BUCKET" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION"

        aws_cmd s3api put-bucket-versioning \
            --bucket "$STATE_BUCKET" \
            --versioning-configuration Status=Enabled
    fi

    echo "$STATE_JSON" | aws_cmd s3 cp - "s3://$STATE_BUCKET/$STATE_FILE" --region "$REGION"
    log "State saved"
}

# ===========================
# EC2 MANAGEMENT (KEY-OWNED)
# ===========================
add_ec2_instance() {
    local instance_id="$1"
    local name="$2"
    local instance_type="$3"
    local key_pair="$4"
    local security_groups="$5"   # JSON array string
    local state="${6:-running}"

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg id "$instance_id" \
        --arg name "$name" \
        --arg type "$instance_type" \
        --arg key "$key_pair" \
        --argjson sgs "$security_groups" \
        --arg region "$REGION" \
        --arg state "$state" \
        '
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

    log "EC2 instance registered: $instance_id (key=$key_pair)"
    save_state
}

remove_ec2_instance() {
    local instance_id="$1"

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg id "$instance_id" '
        .ec2_instances |= map(select(.instance_id != $id))
        | .timestamp = now
        '
    )

    log "EC2 instance removed: $instance_id"
    save_state
}

# ===========================
# SECURITY GROUPS
# ===========================
add_security_group() {
    local sg_id="$1"

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg id "$sg_id" '
        .security_groups += [$id]
        | .security_groups |= unique
        | .timestamp = now
        '
    )

    log "Security group added: $sg_id"
    save_state
}

remove_security_group() {
    local sg_id="$1"

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg id "$sg_id" '
        .security_groups |= map(select(. != $id))
        | .timestamp = now
        '
    )

    log "Security group removed: $sg_id"
    save_state
}

# ===========================
# S3 BUCKETS
# ===========================
add_s3_bucket() {
    local bucket="$1"

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg bucket "$bucket" '
        .s3_buckets += [{ bucket_name: $bucket }]
        | .s3_buckets |= unique_by(.bucket_name)
        | .timestamp = now
        '
    )

    log "S3 bucket added: $bucket"
    save_state
}

remove_s3_bucket() {
    local bucket="$1"

    STATE_JSON=$(echo "$STATE_JSON" | jq \
        --arg bucket "$bucket" '
        .s3_buckets |= map(select(.bucket_name != $bucket))
        | .timestamp = now
        '
    )

    log "S3 bucket removed: $bucket"
    save_state
}
cleanup_resources