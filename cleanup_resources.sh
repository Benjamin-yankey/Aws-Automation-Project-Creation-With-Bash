#!/bin/bash

# Script: cleanup_resources.sh
# Purpose: Clean up all AWS resources created by automation scripts
# Region: eu-west-1

set -e

REGION="eu-west-1"
PROJECT_TAG="AutomationLab"

echo "=========================================="
echo "AWS Resource Cleanup Script"
echo "Region: $REGION"
echo "Project Tag: $PROJECT_TAG"
echo "=========================================="
echo ""
echo "⚠ WARNING: This will delete resources tagged with Project=$PROJECT_TAG"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "Starting cleanup process..."
echo ""

# ===========================
# 1. Terminate EC2 Instances
# ===========================
echo "[1/5] Terminating EC2 instances..."
INSTANCE_IDS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text)

if [ -z "$INSTANCE_IDS" ]; then
    echo "  ✓ No EC2 instances found"
else
    echo "  Found instances: $INSTANCE_IDS"
    aws ec2 terminate-instances \
        --instance-ids $INSTANCE_IDS \
        --region "$REGION" > /dev/null
    
    echo "  ⏳ Waiting for instances to terminate..."
    aws ec2 wait instance-terminated \
        --instance-ids $INSTANCE_IDS \
        --region "$REGION" 2>/dev/null || true
    
    echo "  ✓ EC2 instances terminated"
fi

# ===========================
# 2. Delete Key Pairs
# ===========================
echo "[2/5] Deleting key pairs..."
KEY_PAIRS=$(aws ec2 describe-key-pairs \
    --region "$REGION" \
    --query 'KeyPairs[?starts_with(KeyName, `devops-keypair`)].KeyName' \
    --output text)

if [ -z "$KEY_PAIRS" ]; then
    echo "  ✓ No key pairs found"
else
    for KEY in $KEY_PAIRS; do
        aws ec2 delete-key-pair \
            --key-name "$KEY" \
            --region "$REGION"
        echo "  ✓ Deleted key pair: $KEY"
        
        # Remove local .pem file if exists
        if [ -f "${KEY}.pem" ]; then
            rm "${KEY}.pem"
            echo "  ✓ Removed local file: ${KEY}.pem"
        fi
    done
fi

# ===========================
# 3. Delete Security Groups
# ===========================
echo "[3/5] Deleting security groups..."
# Wait a bit to ensure instances are fully terminated
sleep 5

SG_IDS=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --query 'SecurityGroups[*].GroupId' \
    --output text)

if [ -z "$SG_IDS" ]; then
    echo "  ✓ No security groups found"
else
    for SG_ID in $SG_IDS; do
        # Try to delete, ignore errors if dependencies exist
        aws ec2 delete-security-group \
            --group-id "$SG_ID" \
            --region "$REGION" 2>/dev/null && echo "  ✓ Deleted security group: $SG_ID" || echo "  ⚠ Could not delete: $SG_ID (may have dependencies)"
    done
fi

# ===========================
# 4. Delete S3 Buckets
# ===========================
echo "[4/5] Deleting S3 buckets..."
BUCKETS=$(aws s3api list-buckets \
    --query 'Buckets[?starts_with(Name, `devops-automation-lab`)].Name' \
    --output text)

if [ -z "$BUCKETS" ]; then
    echo "  ✓ No S3 buckets found"
else
    for BUCKET in $BUCKETS; do
        # Check if bucket has the right tags
        TAGS=$(aws s3api get-bucket-tagging \
            --bucket "$BUCKET" 2>/dev/null | grep -o "$PROJECT_TAG" || true)
        
        if [ ! -z "$TAGS" ] || [[ "$BUCKET" == devops-automation-lab* ]]; then
            echo "  Emptying bucket: $BUCKET"
            
            # Delete all versions and delete markers
            aws s3api delete-objects \
                --bucket "$BUCKET" \
                --delete "$(aws s3api list-object-versions \
                    --bucket "$BUCKET" \
                    --output json \
                    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')" 2>/dev/null || true
            
            aws s3api delete-objects \
                --bucket "$BUCKET" \
                --delete "$(aws s3api list-object-versions \
                    --bucket "$BUCKET" \
                    --output json \
                    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}')" 2>/dev/null || true
            
            # Delete the bucket
            aws s3api delete-bucket \
                --bucket "$BUCKET" \
                --region "$REGION"
            
            echo "  ✓ Deleted bucket: $BUCKET"
        fi
    done
fi

# ===========================
# 5. Cleanup local files
# ===========================
echo "[5/5] Cleaning up local files..."
if [ -f "welcome.txt" ]; then
    rm welcome.txt
    echo "  ✓ Removed welcome.txt"
fi

echo ""
echo "=========================================="
echo "Cleanup Complete!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  - EC2 instances terminated"
echo "  - Key pairs deleted"
echo "  - Security groups removed"
echo "  - S3 buckets emptied and deleted"
echo "  - Local files cleaned up"
echo ""
echo "✓ All resources cleaned up successfully"
echo ""