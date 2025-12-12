#!/bin/bash

##############################################
# Script: cleanup_resources.sh
# Purpose: Delete all AWS resources created by automation scripts
##############################################

set -e  # Exit on error

PROJECT_TAG="AutomationLab"

echo "=========================================="
echo "AWS Resource Cleanup Script"
echo "=========================================="
echo "WARNING: This will delete resources tagged with Project=$PROJECT_TAG"
echo ""

# Function to ask for confirmation
confirm_cleanup() {
    read -p "Are you sure you want to proceed? (yes/no): " response
    if [ "$response" != "yes" ]; then
        echo "Cleanup cancelled."
        exit 0
    fi
}

confirm_cleanup

echo ""
echo "Starting cleanup process..."

# 1. Terminate EC2 Instances
echo ""
echo "=== Cleaning up EC2 Instances ==="
if [ -f ".instance_id.txt" ]; then
    INSTANCE_ID=$(cat .instance_id.txt)
    echo "Terminating instance: $INSTANCE_ID"
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" || echo "Instance may already be terminated"
    echo "Waiting for instance to terminate..."
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" 2>/dev/null || echo "Instance terminated"
    rm .instance_id.txt
else
    echo "Finding instances by tag..."
    INSTANCE_IDS=$(aws ec2 describe-instances \
        --filters "Name=tag:Project,Values=$PROJECT_TAG" \
                  "Name=instance-state-name,Values=running,stopped,stopping,pending" \
        --query "Reservations[].Instances[].InstanceId" \
        --output text)
    
    if [ ! -z "$INSTANCE_IDS" ]; then
        echo "Terminating instances: $INSTANCE_IDS"
        aws ec2 terminate-instances --instance-ids $INSTANCE_IDS
        echo "Waiting for instances to terminate..."
        for id in $INSTANCE_IDS; do
            aws ec2 wait instance-terminated --instance-ids "$id" 2>/dev/null || echo "Instance $id terminated"
        done
    else
        echo "No instances found to terminate"
    fi
fi

# 2. Delete Key Pairs
echo ""
echo "=== Cleaning up Key Pairs ==="
KEY_NAME="devops-automation-key"
aws ec2 delete-key-pair --key-name "$KEY_NAME" 2>/dev/null || echo "Key pair not found or already deleted"
if [ -f "${KEY_NAME}.pem" ]; then
    rm "${KEY_NAME}.pem"
    echo "Deleted local key file: ${KEY_NAME}.pem"
fi

# 3. Empty and Delete S3 Buckets
echo ""
echo "=== Cleaning up S3 Buckets ==="
if [ -f ".bucket_name.txt" ]; then
    BUCKET_NAME=$(cat .bucket_name.txt)
    echo "Deleting bucket: $BUCKET_NAME"
    
    # Empty bucket (including all versions)
    echo "Emptying bucket..."
    aws s3 rm "s3://${BUCKET_NAME}" --recursive 2>/dev/null || echo "Bucket already empty"
    
    # Delete all object versions
    aws s3api delete-objects \
        --bucket "$BUCKET_NAME" \
        --delete "$(aws s3api list-object-versions \
            --bucket "$BUCKET_NAME" \
            --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
            --output json)" 2>/dev/null || echo "No versions to delete"
    
    # Delete delete markers
    aws s3api delete-objects \
        --bucket "$BUCKET_NAME" \
        --delete "$(aws s3api list-object-versions \
            --bucket "$BUCKET_NAME" \
            --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
            --output json)" 2>/dev/null || echo "No delete markers"
    
    # Delete bucket
    aws s3api delete-bucket --bucket "$BUCKET_NAME"
    echo "Bucket deleted: $BUCKET_NAME"
    rm .bucket_name.txt
else
    echo "Finding buckets by tag..."
    BUCKETS=$(aws s3api list-buckets --query "Buckets[].Name" --output text)
    
    for bucket in $BUCKETS; do
        TAGS=$(aws s3api get-bucket-tagging --bucket "$bucket" 2>/dev/null || echo "")
        if echo "$TAGS" | grep -q "$PROJECT_TAG"; then
            echo "Found bucket with project tag: $bucket"
            echo "Emptying and deleting bucket: $bucket"
            aws s3 rm "s3://${bucket}" --recursive 2>/dev/null || echo "Bucket already empty"
            aws s3api delete-bucket --bucket "$bucket"
        fi
    done
fi

# Delete sample file if it exists
if [ -f "welcome.txt" ]; then
    rm welcome.txt
    echo "Deleted local sample file: welcome.txt"
fi

# 4. Delete Security Groups
echo ""
echo "=== Cleaning up Security Groups ==="
sleep 5  # Wait a bit for instances to fully terminate

if [ -f ".sg_id.txt" ]; then
    SG_ID=$(cat .sg_id.txt)
    echo "Deleting security group: $SG_ID"
    aws ec2 delete-security-group --group-id "$SG_ID" || echo "Security group may be in use or already deleted"
    rm .sg_id.txt
else
    echo "Finding security groups by tag..."
    SG_IDS=$(aws ec2 describe-security-groups \
        --filters "Name=tag:Project,Values=$PROJECT_TAG" \
        --query "SecurityGroups[].GroupId" \
        --output text)
    
    if [ ! -z "$SG_IDS" ]; then
        for sg in $SG_IDS; do
            echo "Deleting security group: $sg"
            aws ec2 delete-security-group --group-id "$sg" || echo "Could not delete $sg (may be in use)"
        done
    else
        echo "No security groups found to delete"
    fi
fi

echo ""
echo "=========================================="
echo "Cleanup Complete!"
echo "=========================================="
echo ""
echo "All resources have been removed."
echo "Please verify in AWS Console if needed."