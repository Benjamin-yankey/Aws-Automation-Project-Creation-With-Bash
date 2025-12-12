#!/bin/bash

##############################################
# Script: create_security_group.sh
# Purpose: Create AWS Security Group with SSH and HTTP access
##############################################

set -e  # Exit immediately if any command fails

# Configuration Variables
SG_NAME="devops-sg"
SG_DESCRIPTION="Security group for DevOps automation lab"
PROJECT_TAG="AutomationLab"

echo "=========================================="
echo "Starting Security Group Creation"
echo "=========================================="

# Get default VPC ID
echo "Fetching default VPC ID..."
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
    echo "ERROR: No default VPC found. Please create a VPC first."
    exit 1
fi

echo "Using VPC: $VPC_ID"

# Check if security group already exists
EXISTING_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query "SecurityGroups[0].GroupId" \
    --output text 2>/dev/null || echo "")

if [ ! -z "$EXISTING_SG" ] && [ "$EXISTING_SG" != "None" ]; then
    echo "Security group '$SG_NAME' already exists with ID: $EXISTING_SG"
    SG_ID=$EXISTING_SG
else
    # Create security group
    echo "Creating security group: $SG_NAME"
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "$SG_DESCRIPTION" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
        --query 'GroupId' \
        --output text)

    echo "Security group created successfully!"
    echo "Security Group ID: $SG_ID"
fi

# Add SSH rule (port 22)
echo "Adding SSH rule (port 22)..."
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 2>/dev/null || echo "SSH rule may already exist"

# Add HTTP rule (port 80)
echo "Adding HTTP rule (port 80)..."
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0 2>/dev/null || echo "HTTP rule may already exist"

# Display security group details
echo ""
echo "=========================================="
echo "Security Group Configuration Complete"
echo "=========================================="
echo "Security Group ID: $SG_ID"
echo "Security Group Name: $SG_NAME"
echo "VPC ID: $VPC_ID"
echo ""
echo "Inbound Rules:"
aws ec2 describe-security-groups \
    --group-ids "$SG_ID" \
    --query "SecurityGroups[0].IpPermissions[*].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp]" \
    --output table

# Save SG ID to file for other scripts to use
echo "$SG_ID" > .sg_id.txt
echo ""
echo "Security Group ID saved to .sg_id.txt"