#!/bin/bash

##############################################
# Script: create_s3_bucket.sh
# Purpose: Create S3 bucket with versioning and upload sample file
##############################################

set -e  # Exit on error

# Configuration Variables
BUCKET_PREFIX="devops-automation-bucket"
PROJECT_TAG="AutomationLab"
SAMPLE_FILE="welcome.txt"

echo "=========================================="
echo "Starting S3 Bucket Creation"
echo "=========================================="

# Generate unique bucket name (S3 bucket names must be globally unique)
TIMESTAMP=$(date +%s)
BUCKET_NAME="${BUCKET_PREFIX}-${TIMESTAMP}"

echo "Bucket name: $BUCKET_NAME"

# Get AWS region
AWS_REGION=$(aws configure get region)
echo "Region: $AWS_REGION"

# Create S3 bucket
echo "Creating S3 bucket..."
if [ "$AWS_REGION" == "us-east-1" ]; then
    # us-east-1 doesn't need LocationConstraint
    aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region "$AWS_REGION"
else
    # Other regions require LocationConstraint
    aws s3api create-bucket \
        --bucket "$BUCKET_NAME" \
        --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
fi

echo "Bucket created successfully!"

# Add tags to bucket
echo "Adding tags to bucket..."
aws s3api put-bucket-tagging \
    --bucket "$BUCKET_NAME" \
    --tagging "TagSet=[{Key=Name,Value=$BUCKET_NAME},{Key=Project,Value=$PROJECT_TAG}]"

# Enable versioning
echo "Enabling versioning..."
aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled

# Create a simple bucket policy (allowing read access to objects)
echo "Setting bucket policy..."
BUCKET_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
    }
  ]
}
EOF
)

# Note: Public access might be blocked by default. 
# For production, use more restrictive policies
aws s3api put-bucket-policy \
    --bucket "$BUCKET_NAME" \
    --policy "$BUCKET_POLICY" 2>/dev/null || echo "Note: Public access blocked by account settings (this is normal)"

# Create sample file if it doesn't exist
if [ ! -f "$SAMPLE_FILE" ]; then
    echo "Creating sample file: $SAMPLE_FILE"
    cat > "$SAMPLE_FILE" <<EOF
Welcome to DevOps Automation Lab!

This file was automatically uploaded to S3 by our automation script.

Bucket: $BUCKET_NAME
Date: $(date)
Project: $PROJECT_TAG

This demonstrates:
- Automated S3 bucket creation
- File upload via AWS CLI
- Bucket versioning
- Infrastructure as Code principles
EOF
fi

# Upload sample file
echo "Uploading sample file to S3..."
aws s3 cp "$SAMPLE_FILE" "s3://${BUCKET_NAME}/${SAMPLE_FILE}" \
    --metadata "project=$PROJECT_TAG"

# Verify upload
echo "Verifying file upload..."
FILE_URL="https://${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/${SAMPLE_FILE}"

echo ""
echo "=========================================="
echo "S3 Bucket Configuration Complete"
echo "=========================================="
echo "Bucket Name: $BUCKET_NAME"
echo "Region: $AWS_REGION"
echo "Versioning: Enabled"
echo "Sample File: $SAMPLE_FILE"
echo "File URL: $FILE_URL"
echo ""
echo "Bucket contents:"
aws s3 ls "s3://${BUCKET_NAME}/" --human-readable

echo ""
echo "Bucket versioning status:"
aws s3api get-bucket-versioning --bucket "$BUCKET_NAME"

# Save bucket name for cleanup
echo "$BUCKET_NAME" > .bucket_name.txt
echo ""
echo "Bucket name saved to .bucket_name.txt"