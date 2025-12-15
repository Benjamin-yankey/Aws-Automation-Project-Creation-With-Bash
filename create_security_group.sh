#!/bin/bash

# Script: create_security_group.sh
# Purpose: Create and configure security group in eu-west-1
# Opens ports: 22 (SSH) and 80 (HTTP)

set -e

# Configuration
REGION="eu-west-1"
SG_NAME="devops-sg-$(date +%s)"
SG_DESCRIPTION="Security group for DevOps automation lab"

echo "=========================================="
echo "Security Group Creation Script"
echo "Region: $REGION"
echo "=========================================="

# Get default VPC ID
echo "[1/4] Getting default VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
    --region "$REGION" \
    --filters "Name=isDefault,Values=true" \
    --query 'Vpcs[0].VpcId' \
    --output text)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
    echo "✗ No default VPC found in $REGION"
    exit 1
fi
echo "✓ Using VPC: $VPC_ID"

# Create security group
echo "[2/4] Creating security group: $SG_NAME..."
SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "$SG_DESCRIPTION" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text)

if [ -z "$SG_ID" ]; then
    echo "✗ Failed to create security group"
    exit 1
fi
echo "✓ Security group created: $SG_ID"

# Tag security group
aws ec2 create-tags \
    --resources "$SG_ID" \
    --tags Key=Name,Value="$SG_NAME" Key=Project,Value=AutomationLab \
    --region "$REGION"

# Add SSH rule (port 22)
echo "[3/4] Adding SSH rule (port 22)..."
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --region "$REGION" > /dev/null

if [ $? -eq 0 ]; then
    echo "✓ SSH rule added (0.0.0.0/0:22)"
else
    echo "✗ Failed to add SSH rule"
fi

# Add HTTP rule (port 80)
echo "[4/4] Adding HTTP rule (port 80)..."
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0 \
    --region "$REGION" > /dev/null

if [ $? -eq 0 ]; then
    echo "✓ HTTP rule added (0.0.0.0/0:80)"
else
    echo "✗ Failed to add HTTP rule"
fi

# Display security group details
echo ""
echo "=========================================="
echo "Security Group Created Successfully!"
echo "=========================================="
echo "Security Group ID:   $SG_ID"
echo "Security Group Name: $SG_NAME"
echo "VPC ID:              $VPC_ID"
echo "Region:              $REGION"
echo ""
echo "Ingress Rules:"
echo "  - SSH  (TCP/22)  from 0.0.0.0/0"
echo "  - HTTP (TCP/80)  from 0.0.0.0/0"
echo "=========================================="
echo ""

# Show detailed rules
echo "Detailed Security Group Rules:"
aws ec2 describe-security-groups \
    --group-ids "$SG_ID" \
    --region "$REGION" \
    --query 'SecurityGroups[0].IpPermissions' \
    --output table