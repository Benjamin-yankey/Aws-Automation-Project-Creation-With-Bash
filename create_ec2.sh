#!/bin/bash

##############################################
# Script: create_ec2.sh
# Purpose: Create EC2 instance with key pair
##############################################

set -e  # Exit on error

# Configuration Variables
KEY_NAME="devops-automation-key"
INSTANCE_TYPE="t2.micro"
PROJECT_TAG="AutomationLab"
INSTANCE_NAME="devops-automation-instance"

echo "=========================================="
echo "Starting EC2 Instance Creation"
echo "=========================================="

# Get latest Amazon Linux 2 AMI ID
echo "Fetching latest Amazon Linux 2 AMI..."
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
              "Name=state,Values=available" \
    --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" \
    --output text)

if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
    echo "ERROR: Could not find Amazon Linux 2 AMI"
    exit 1
fi

echo "Using AMI: $AMI_ID"

# Check if key pair exists, if not create it
echo "Checking for existing key pair..."
KEY_EXISTS=$(aws ec2 describe-key-pairs \
    --key-names "$KEY_NAME" \
    --query "KeyPairs[0].KeyName" \
    --output text 2>/dev/null || echo "")

if [ -z "$KEY_EXISTS" ] || [ "$KEY_EXISTS" == "None" ]; then
    echo "Creating new key pair: $KEY_NAME"
    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text > "${KEY_NAME}.pem"
    
    chmod 400 "${KEY_NAME}.pem"
    echo "Key pair created and saved to ${KEY_NAME}.pem"
else
    echo "Key pair '$KEY_NAME' already exists"
fi

# Get security group ID (created by previous script)
if [ -f ".sg_id.txt" ]; then
    SG_ID=$(cat .sg_id.txt)
    echo "Using existing security group: $SG_ID"
else
    echo "ERROR: Security group not found. Please run create_security_group.sh first"
    exit 1
fi

# Launch EC2 instance
echo "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance launching... Instance ID: $INSTANCE_ID"

# Wait for instance to be running
echo "Waiting for instance to be in running state..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

# Get instance details
echo "Fetching instance details..."
INSTANCE_INFO=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].[PublicIpAddress,State.Name,InstanceType]' \
    --output text)

PUBLIC_IP=$(echo $INSTANCE_INFO | awk '{print $1}')
STATE=$(echo $INSTANCE_INFO | awk '{print $2}')
TYPE=$(echo $INSTANCE_INFO | awk '{print $3}')

echo ""
echo "=========================================="
echo "EC2 Instance Created Successfully"
echo "=========================================="
echo "Instance ID: $INSTANCE_ID"
echo "Instance Type: $TYPE"
echo "State: $STATE"
echo "Public IP: $PUBLIC_IP"
echo "Key Pair: ${KEY_NAME}.pem"
echo ""
echo "To connect via SSH:"
echo "ssh -i ${KEY_NAME}.pem ec2-user@${PUBLIC_IP}"
echo ""

# Save instance ID for cleanup
echo "$INSTANCE_ID" > .instance_id.txt
echo "Instance ID saved to .instance_id.txt"