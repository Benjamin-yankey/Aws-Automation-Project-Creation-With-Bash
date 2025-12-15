#!/bin/bash

# Script: create_s3_bucket.sh
# Purpose: Create S3 bucket in eu-west-1 with versioning and sample file
# Region: eu-west-1

set -e

# Configuration
REGION="eu-west-1"
BUCKET_NAME="devops-automation-lab-$(date +%s)-$RANDOM"
SAMPLE_FILE="welcome.txt"

echo "=========================================="
echo "S3 Bucket Creation Script"
echo "Region: $REGION"
echo "=========================================="

# Create sample file
echo "[1/5] Creating sample file..."
cat > "$SAMPLE_FILE" << EOF
Welcome to DevOps Automation Lab!
==================================

This file was automatically uploaded by create_s3_bucket.sh script.

Bucket: $BUCKET_NAME
Region: $REGION
Created: $(date)

Project: AWS Resource Automation
Purpose: Learning AWS CLI and Bash scripting
EOF

echo "✓ Sample file created: $SAMPLE_FILE"

# Create S3 bucket
echo "[2/5] Creating S3 bucket: $BUCKET_NAME..."
aws s3api create-bucket \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" > /dev/null

if [ $? -eq 0 ]; then
    echo "✓ Bucket created successfully"
else
    echo "✗ Failed to create bucket"
    exit 1
fi

# Add tags to bucket
echo "[3/5] Adding tags to bucket..."
aws s3api put-bucket-tagging \
    --bucket "$BUCKET_NAME" \
    --tagging "TagSet=[{Key=Project,Value=AutomationLab},{Key=Environment,Value=Development},{Key=ManagedBy,Value=BashScript}]" \
    --region "$REGION"

echo "✓ Tags added"

# Enable versioning
echo "[4/5] Enabling versioning..."
aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled \
    --region "$REGION"

if [ $? -eq 0 ]; then
    echo "✓ Versioning enabled"
else
    echo "✗ Failed to enable versioning"
fi

# Apply bucket policy (optional - simple read policy for objects)
echo "[4.5/5] Applying bucket policy..."
BUCKET_POLICY=$(cat <<EOF
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

# Note: Public access might be blocked by default. This is just for demonstration.
# In production, you should use more restrictive policies.
aws s3api put-bucket-policy \
    --bucket "$BUCKET_NAME" \
    --policy "$BUCKET_POLICY" \
    --region "$REGION" 2>/dev/null || echo "⚠ Bucket policy not applied (public access might be blocked)"

# Upload sample file
echo "[5/5] Uploading sample file..."
aws s3 cp "$SAMPLE_FILE" "s3://$BUCKET_NAME/$SAMPLE_FILE" \
    --region "$REGION" > /dev/null

if [ $? -eq 0 ]; then
    echo "✓ File uploaded successfully"
else
    echo "✗ Failed to upload file"
fi

# Verify versioning status
VERSIONING_STATUS=$(aws s3api get-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --region "$REGION" \
    --query 'Status' \
    --output text)

# Display results
echo ""
echo "=========================================="
echo "S3 Bucket Created Successfully!"
echo "=========================================="
echo "Bucket Name:        $BUCKET_NAME"
echo "Region:             $REGION"
echo "Versioning Status:  $VERSIONING_STATUS"
echo "Sample File:        $SAMPLE_FILE"
echo ""
echo "Bucket ARN:         arn:aws:s3:::$BUCKET_NAME"
echo "=========================================="
echo ""
echo "To list bucket contents:"
echo "aws s3 ls s3://$BUCKET_NAME --region $REGION"
echo ""
echo "To download the file:"
echo "aws s3 cp s3://$BUCKET_NAME/$SAMPLE_FILE ./ --region $REGION"
echo ""

# List bucket contents
echo "Current bucket contents:"
aws s3 ls "s3://$BUCKET_NAME" --region "$REGION"