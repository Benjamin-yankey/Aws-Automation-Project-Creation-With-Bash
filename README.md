# AWS Resource Automation with Bash Scripts

**Project**: Automate AWS Resource Creation  
**Region**: eu-west-1 (Ireland)  
**Instance Type**: t3.micro

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Setup Instructions](#setup-instructions)
- [Script Descriptions](#script-descriptions)
- [Usage Guide](#usage-guide)
- [Challenges & Solutions](#challenges--solutions)
- [Screenshots](#screenshots)
- [Best Practices](#best-practices)

---

## Overview

This project automates the creation and management of AWS resources using Bash scripts and AWS CLI. It provisions:

- **EC2 Instances** (t3.micro in eu-west-1)
- **Security Groups** (with SSH and HTTP access)
- **S3 Buckets** (with versioning enabled)

All resources are properly tagged for easy identification and cleanup.

---

## Prerequisites

### Required Software

- AWS CLI (version 2.x or higher)
- Bash shell (Linux/macOS or WSL on Windows)
- An AWS account with appropriate IAM permissions

### Required IAM Permissions

Your AWS user/role needs permissions for:

- EC2: `ec2:*` (or specific actions like RunInstances, CreateKeyPair, etc.)
- S3: `s3:*` (or specific bucket operations)
- IAM: `sts:GetCallerIdentity` (for verification)

---

## 🔧 Setup Instructions

### Step 1: Install AWS CLI

**On Linux/macOS:**

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

**On Windows (PowerShell):**

```powershell
msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
```

Verify installation:

```bash
aws --version
```

### Step 2: Configure AWS CLI

```bash
aws configure
```

Enter your credentials:

- **AWS Access Key ID**: [Your access key]
- **AWS Secret Access Key**: [Your secret key]
- **Default region**: `eu-west-1`
- **Default output format**: `json`

### Step 3: Verify Configuration

```bash
# Verify credentials
aws sts get-caller-identity

# Verify configuration
aws configure list
```

Expected output:

```json
{
  "UserId": "AIDAXXXXXXXXXXXXXXXXX",
  "Account": "123456789012",
  "Arn": "arn:aws:iam::123456789012:user/your-username"
}
```

### Step 4: Clone and Setup Scripts

```bash
# Clone the repository
git clone https://github.com/yourusername/aws-automation-lab.git
cd aws-automation-lab

# Make scripts executable
chmod +x *.sh

# Verify scripts
ls -lh *.sh
```

---

## Script Descriptions

### 1. `create_ec2.sh`

**Purpose**: Automates EC2 instance creation in eu-west-1

**Features**:

- Creates a new EC2 key pair and saves it locally
- Launches a t3.micro instance with Amazon Linux 2023 AMI
- Tags the instance with Project=AutomationLab
- Displays instance ID and public IP address
- Provides SSH connection command

**Key Commands Used**:

- `aws ec2 create-key-pair`
- `aws ec2 run-instances`
- `aws ec2 wait instance-running`
- `aws ec2 describe-instances`

### 2. `create_security_group.sh`

**Purpose**: Creates and configures a security group

**Features**:

- Creates a new security group in the default VPC
- Opens port 22 for SSH access (0.0.0.0/0)
- Opens port 80 for HTTP traffic (0.0.0.0/0)
- Tags the security group appropriately
- Displays all configured rules

**Key Commands Used**:

- `aws ec2 create-security-group`
- `aws ec2 authorize-security-group-ingress`
- `aws ec2 describe-security-groups`
- `aws ec2 create-tags`

### 3. `create_s3_bucket.sh`

**Purpose**: Creates an S3 bucket with versioning

**Features**:

- Creates a uniquely named S3 bucket
- Enables versioning for the bucket
- Applies bucket tags (Project=AutomationLab)
- Creates and uploads a sample welcome.txt file
- Sets up a basic bucket policy

**Key Commands Used**:

- `aws s3api create-bucket`
- `aws s3api put-bucket-versioning`
- `aws s3api put-bucket-tagging`
- `aws s3 cp`

### 4. `cleanup_resources.sh`

**Purpose**: Safely removes all created resources

**Features**:

- Prompts for confirmation before deletion
- Terminates EC2 instances tagged with Project=AutomationLab
- Deletes associated key pairs (both AWS and local .pem files)
- Removes security groups
- Empties and deletes S3 buckets (including all versions)
- Cleans up local files

**Key Commands Used**:

- `aws ec2 terminate-instances`
- `aws ec2 delete-key-pair`
- `aws ec2 delete-security-group`
- `aws s3api delete-bucket`

---

## Usage Guide

### Running the Scripts

#### 1. Create EC2 Instance

```bash
./create_ec2.sh
```

**Expected Output**:

```
==========================================
EC2 Instance Creation Script
Region: eu-west-1
Instance Type: t3.micro
==========================================
[1/4] Creating EC2 key pair: devops-keypair-1234567890...
✓ Key pair created and saved to devops-keypair-1234567890.pem
[2/4] Getting default VPC...
✓ Using VPC: vpc-xxxxx
[3/4] Launching EC2 instance (t3.micro)...
✓ Instance launched: i-xxxxx
[4/4] Waiting for instance to enter running state...

==========================================
EC2 Instance Created Successfully!
==========================================
Instance ID:     i-xxxxx
Instance Type:   t3.micro
Region:          eu-west-1
Public IP:       54.xxx.xxx.xxx
Private IP:      172.31.xxx.xxx
Key Pair:        devops-keypair-1234567890.pem
==========================================

To connect via SSH, use:
ssh -i devops-keypair-1234567890.pem ec2-user@54.xxx.xxx.xxx
```

#### 2. Create Security Group

```bash
./create_security_group.sh
```

#### 3. Create S3 Bucket

```bash
./create_s3_bucket.sh
```

#### 4. Cleanup All Resources

```bash
./cleanup_resources.sh
```

**Important**: The cleanup script will ask for confirmation before proceeding.

### Testing Your Setup

After running the scripts, verify resources:

```bash
# List EC2 instances
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=AutomationLab" \
  --region eu-west-1 \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress]' \
  --output table

# List security groups
aws ec2 describe-security-groups \
  --filters "Name=tag:Project,Values=AutomationLab" \
  --region eu-west-1 \
  --query 'SecurityGroups[*].[GroupId,GroupName]' \
  --output table

# List S3 buckets
aws s3 ls | grep devops-automation-lab
```

---

## Challenges & Solutions

### Challenge 1: Region Restrictions

**Problem**: Can only create resources in eu-west-1  
**Solution**: Hard-coded `REGION="eu-west-1"` in all scripts and used region-specific AMI IDs

### Challenge 2: Instance Type Limitation

**Problem**: Limited to t3.micro instance type  
**Solution**: Set `INSTANCE_TYPE="t3.micro"` and verified AMI compatibility with t3.micro

### Challenge 3: AMI ID Varies by Region

**Problem**: Default AMIs differ across regions  
**Solution**: Used region-specific AMI ID `ami-0d64bb532e0502c46` for Amazon Linux 2023 in eu-west-1

### Challenge 4: S3 Bucket Naming Conflicts

**Problem**: S3 bucket names must be globally unique  
**Solution**: Added timestamp and random number to bucket names: `devops-automation-lab-$(date +%s)-$RANDOM`

### Challenge 5: Public Access Block on S3

**Problem**: AWS blocks public bucket policies by default  
**Solution**: Added error handling for bucket policy application; policy fails gracefully with a warning

### Challenge 6: Security Group Dependencies

**Problem**: Cannot delete security groups while EC2 instances are using them  
**Solution**: Cleanup script waits for instances to terminate before attempting security group deletion

### Challenge 7: S3 Bucket Versioning Cleanup

**Problem**: Cannot delete bucket with versioned objects  
**Solution**: Cleanup script deletes all object versions and delete markers before removing bucket

---

## Screenshots

Include the following screenshots in your submission:

1. **AWS CLI Configuration**

   - Output of `aws sts get-caller-identity`

![Script Execution](screenshots/Identity.png)

- Output of `aws configure list`

![Script Execution](screenshots/Awsconfigure.png)

2. **EC2 Instance Creation**

   - Script execution output

![Script Execution](screenshots/Ec2instance.png)

- AWS Console showing the instance

![Script Execution](screenshots/Instances.png)

3. **Security Group Creation**

   - Script output with rules

![Script Execution](screenshots/securitygroup.png)

- AWS Console security group details

![Script Execution](screenshots/Security_Group.png)

4. **S3 Bucket Creation**

   - Script output

![Script Execution](screenshots/s3bucket.png)

- AWS Console showing bucket and uploaded file

![Script Execution](screenshots/s3_Bucket.png)

5. **Cleanup Process**
   - Cleanup script execution

![Script Execution](screenshots/Outputofcleanup.png)

---

## Best Practices Implemented

### 1. Error Handling

```bash
set -e  # Exit on error
if [ $? -eq 0 ]; then
    echo "✓ Success"
else
    echo "✗ Failed"
    exit 1
fi
```

### 2. Parameterization

- All configurable values stored in variables at script start
- Easy to modify region, instance types, names

### 3. Clear Output

- Progress indicators ([1/4], [2/4], etc.)
- Success (✓) and error (✗) symbols
- Formatted summaries

### 4. Security

- Key pair files set to 400 permissions
- Credentials never hard-coded in scripts
- Proper IAM role usage recommended

### 5. Resource Tagging

- All resources tagged with Project=AutomationLab
- Enables easy filtering and cleanup

### 6. Documentation

- Inline comments explaining complex operations
- Comprehensive README with examples
- Usage instructions in script output

### 7. Idempotency Considerations

- Unique naming with timestamps to avoid conflicts
- Proper error checking before operations

---

## Learning Outcomes

By completing this project, you will:

- Understand AWS CLI fundamentals
- Master Bash scripting for automation
- Learn AWS resource management
- Practice infrastructure-as-code principles
- Implement proper error handling and logging
- Apply security best practices

---

## Additional Resources

- [AWS CLI Command Reference](https://docs.aws.amazon.com/cli/latest/)
- [EC2 User Guide](https://docs.aws.amazon.com/ec2/)
- [S3 Developer Guide](https://docs.aws.amazon.com/s3/)
- [Bash Scripting Tutorial](https://www.gnu.org/software/bash/manual/)

---

## Contributing

Feel free to submit issues or pull requests to improve these scripts.

---

**Author**: Benjamin Huey Kofi Yankey  
**Date**: December 2025  
**Project**: AWS Automation Lab
