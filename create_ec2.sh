#!/bin/bash

# Script: create_ec2.sh
# Purpose: Automate EC2 instance creation in eu-west-1 with t3.micro
# Region: eu-west-1 (Ireland)
# Instance Type: t3.micro

set -e

# Configuration
REGION="eu-west-1"
KEY_NAME="devops-keypair-$(date +%s)"
INSTANCE_TYPE="t3.micro"
AMI_ID="ami-0d64bb532e0502c46" # Amazon Linux 2023 AMI for eu-west-1
INSTANCE_NAME="AutomationLab-EC2"

echo "=========================================="
echo "EC2 Instance Creation Script"
echo "Region: $REGION"
echo "Instance Type: $INSTANCE_TYPE"
echo "=========================================="

# Create key pair
echo "[1/4] Creating EC2 key pair: $KEY_NAME..."
aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --region "$REGION" \
    --query 'KeyMaterial' \
    --output text > "${KEY_NAME}.pem"

if [ $? -eq 0 ]; then
    chmod 400 "${KEY_NAME}.pem"
    echo "✓ Key pair created and saved to ${KEY_NAME}.pem"
else
    echo "✗ Failed to create key pair"
    exit 1
fi

# Get default VPC ID
echo "[2/4] Getting default VPC..."
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

# Get default security group
SECURITY_GROUP=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=default" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

# Launch EC2 instance
echo "[3/4] Launching EC2 instance (t3.micro)..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP" \
    --region "$REGION" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=AutomationLab},{Key=Environment,Value=Development}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

if [ -z "$INSTANCE_ID" ]; then
    echo "✗ Failed to launch instance"
    exit 1
fi
echo "✓ Instance launched: $INSTANCE_ID"

# Wait for instance to be running
echo "[4/4] Waiting for instance to enter running state..."
aws ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION"

# Get instance details
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

PRIVATE_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)

# Display results
echo ""
echo "=========================================="
echo "EC2 Instance Created Successfully!"
echo "=========================================="
echo "Instance ID:     $INSTANCE_ID"
echo "Instance Type:   $INSTANCE_TYPE"
echo "Region:          $REGION"
echo "Public IP:       $PUBLIC_IP"
echo "Private IP:      $PRIVATE_IP"
echo "Key Pair:        ${KEY_NAME}.pem"
echo "=========================================="
echo ""
echo "To connect via SSH, use:"
echo "ssh -i ${KEY_NAME}.pem ec2-user@$PUBLIC_IP"
echo ""