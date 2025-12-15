# AWS Resource Automation with Bash Scripts

**Project**: Automate AWS Resource Creation  
**Region**: User-selectable (default: eu-west-1)  
**Instance Type**: t3.micro  
**Features**: Logging, Error Handling, Functions, User Input

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [New Features](#new-features)
- [Setup Instructions](#setup-instructions)
- [Script Descriptions](#script-descriptions)
- [Usage Guide](#usage-guide)
- [Logging System](#logging-system)
- [Challenges & Solutions](#challenges--solutions)
- [Screenshots](#screenshots)
- [Best Practices](#best-practices)

---

## Overview

This project automates the creation and management of AWS resources using Bash scripts and AWS CLI. It provisions:

- **EC2 Instances** (t3.micro, user-selectable region)
- **Security Groups** (with SSH and HTTP access)
- **S3 Buckets** (with versioning enabled)

All resources are properly tagged for easy identification and cleanup.

---

## New Features

### 1. **Enhanced Error Handling**

```bash
set -euo pipefail
```

- `-e`: Exit immediately if any command fails
- `-u`: Treat unset variables as errors
- `-o pipefail`: Return exit code of last failed command in pipeline

### 2. **Comprehensive Logging**

- All operations logged to timestamped files in `./logs/` directory
- Log levels: INFO, SUCCESS, ERROR, WARNING
- Both console and file output with `tee`

### 3. **Modular Functions**

- Reusable utility functions for common tasks
- Cleaner code structure and easier maintenance
- Error traps for automatic cleanup on failure

### 4. **Interactive Region Selection**

- Users can select from common regions or enter custom ones
- No need to edit scripts for different regions
- Supports multi-region cleanup

### 5. **Automatic AMI Detection**

- Dynamically fetches latest Amazon Linux 2023 AMI for selected region
- No need to update AMI IDs manually

---

## Prerequisites

### Required Software

- AWS CLI (version 2.x or higher)
- Bash shell (Linux/macOS or WSL on Windows)
- jq (for JSON parsing in cleanup script)
- An AWS account with appropriate IAM permissions

### Install jq (for cleanup script)

```bash
# Ubuntu/Debian
sudo apt-get install jq

# macOS
brew install jq

# Amazon Linux
sudo yum install jq
```

### Required IAM Permissions

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:*", "s3:*", "sts:GetCallerIdentity"],
      "Resource": "*"
    }
  ]
}
```

---

## Setup Instructions

### Step 1: Install AWS CLI

**On Linux/macOS:**

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

**Verify installation:**

```bash
aws --version
# Expected: aws-cli/2.x.x or higher
```

### Step 2: Configure AWS CLI

```bash
aws configure
```

Enter your credentials:

```
AWS Access Key ID [None]: AKIAIOSFODNN7EXAMPLE
AWS Secret Access Key [None]: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
Default region name [None]: eu-west-1
Default output format [None]: json
```

### Step 3: Verify Configuration

```bash
# Verify credentials
aws sts get-caller-identity

# Expected output:
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/your-username"
}

# Verify configuration
aws configure list
```

### Step 4: Clone and Setup Scripts

```bash
# Clone the repository
git clone https://github.com/yourusername/aws-automation-lab.git
cd aws-automation-lab

# Make scripts executable
chmod +x create_ec2.sh
chmod +x create_security_group.sh
chmod +x create_s3_bucket.sh
chmod +x cleanup_resources.sh

# Verify permissions
ls -lh *.sh
```

---

## Script Descriptions

### 1. `create_ec2.sh` (Enhanced)

**Purpose**: Automates EC2 instance creation with logging

**New Features**:

- `set -euo pipefail` for strict error handling
- Comprehensive logging to `./logs/ec2_creation_*.log`
- Interactive region selection
- Automatic AMI detection for selected region
- Modular functions for each task
- Error trap for automatic cleanup on failure

**Functions**:

- `init_logging()` - Initialize logging system
- `log()` - Write to log file and console
- `validate_aws_cli()` - Check AWS CLI installation
- `get_region()` - Interactive region selection
- `get_ami_id()` - Fetch latest AMI for region
- `verify_credentials()` - Validate AWS credentials
- `create_key_pair()` - Create and save SSH key
- `get_vpc_id()` - Get default VPC
- `launch_instance()` - Launch EC2 instance
- `wait_for_instance()` - Wait for instance to be ready
- `display_results()` - Show creation summary

### 2. `create_security_group.sh` (Enhanced)

**Purpose**: Creates and configures security group with logging

**New Features**:

- `set -euo pipefail` for error handling
- Logging to `./logs/sg_creation_*.log`
- Interactive region selection
- Reusable function for adding ingress rules
- Automatic cleanup on failure

**Functions**:

- `add_ingress_rule()` - Reusable function for adding rules
- `create_security_group()` - Create SG in VPC
- `tag_security_group()` - Apply tags
- `display_rules()` - Show configured rules

### 3. `create_s3_bucket.sh` (Enhanced)

**Purpose**: Creates S3 bucket with versioning and logging

**New Features**:

- `set -euo pipefail` for error handling
- Logging to `./logs/s3_creation_*.log`
- Interactive region selection
- Handles us-east-1 special case (no LocationConstraint)
- Warning system for policy application failures

**Functions**:

- `create_sample_file()` - Generate welcome file
- `create_bucket()` - Create bucket (region-aware)
- `tag_bucket()` - Apply tags
- `enable_versioning()` - Enable versioning
- `apply_bucket_policy()` - Set bucket policy
- `upload_file()` - Upload sample file

### 4. `cleanup_resources.sh` (Enhanced)

**Purpose**: Safely removes all created resources

**New Features**:

- `set -euo pipefail` for error handling
- Logging to `./logs/cleanup_*.log`
- Multi-region cleanup support
- Interactive confirmation with warning
- Handles versioned S3 objects properly
- Progress indicators for long operations

**Functions**:

- `confirm_cleanup()` - Get user confirmation
- `terminate_instances()` - Terminate EC2 instances
- `delete_key_pairs()` - Delete key pairs
- `delete_security_groups()` - Delete security groups
- `delete_s3_buckets()` - Empty and delete buckets
- `cleanup_local_files()` - Remove local files

---

## Usage Guide

### Running the Scripts

#### 1. Create EC2 Instance

```bash
./create_ec2.sh
```

**Interactive Prompts**:

```
Available AWS Regions:
  1. eu-west-1 (Ireland)
  2. us-east-1 (N. Virginia)
  3. us-west-2 (Oregon)
  4. ap-southeast-1 (Singapore)
  5. Custom region

Enter region number or press Enter for eu-west-1 [eu-west-1]: 1
```

**Expected Output**:

```
==========================================
EC2 Instance Creation Script
==========================================
✓ AWS CLI is installed
Selected region: eu-west-1
✓ Found AMI: ami-0d64bb532e0502c46
✓ AWS credentials verified
[1/7] Creating EC2 key pair...
✓ Key pair created: devops-keypair-1734278400.pem
[2/7] Getting default VPC...
✓ Using VPC: vpc-xxxxx
[3/7] Getting security group...
✓ Using security group: sg-xxxxx
[4/7] Launching EC2 instance...
✓ Instance launched: i-xxxxx
[5/7] Waiting for instance to be running...
⏳ This may take 30-60 seconds...
✓ Instance is now running
[6/7] Retrieving instance details...
✓ Retrieved instance details
[7/7] Finalizing...

==========================================
EC2 Instance Created Successfully!
==========================================
Instance ID:     i-0abc123def456789
Instance Type:   t3.micro
Region:          eu-west-1
AMI ID:          ami-0d64bb532e0502c46
Public IP:       54.123.45.67
Private IP:      172.31.10.20
Key Pair:        devops-keypair-1734278400.pem
VPC ID:          vpc-xxxxx

To connect via SSH, use:
  ssh -i devops-keypair-1734278400.pem ec2-user@54.123.45.67

Log file saved to: ./logs/ec2_creation_20251215_140000.log
```

#### 2. Create Security Group

```bash
./create_security_group.sh
```

**Output includes**:

- Region selection
- Security group creation
- SSH and HTTP rule configuration
- Detailed rule display

#### 3. Create S3 Bucket

```bash
./create_s3_bucket.sh
```

**Output includes**:

- Region selection
- Bucket creation with unique name
- Versioning enablement
- Sample file upload

#### 4. Cleanup All Resources

```bash
./cleanup_resources.sh
```

**Interactive Confirmation**:

```
==========================================
WARNING: Resource Cleanup
==========================================
This script will DELETE the following resources tagged with Project=AutomationLab:
  - EC2 instances
  - EC2 key pairs
  - Security groups
  - S3 buckets (and all contents)
  - Local files (*.pem, welcome.txt)

Region(s): eu-west-1

⚠ THIS ACTION CANNOT BE UNDONE! ⚠

Are you absolutely sure you want to continue? (type 'yes' to confirm):
```

### Testing Your Setup

After running the scripts, verify resources:

```bash
# List EC2 instances
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=AutomationLab" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress]' \
  --output table

# List security groups
aws ec2 describe-security-groups \
  --filters "Name=tag:Project,Values=AutomationLab" \
  --query 'SecurityGroups[*].[GroupId,GroupName]' \
  --output table

# List S3 buckets
aws s3 ls | grep devops-automation-lab

# View logs
ls -lh logs/
tail -f logs/ec2_creation_*.log
```

---

## Logging System

### Log Directory Structure

```
aws-automation-lab/
├── logs/
│   ├── ec2_creation_20251215_140000.log
│   ├── sg_creation_20251215_140230.log
│   ├── s3_creation_20251215_140445.log
│   └── cleanup_20251215_150000.log
├── create_ec2.sh
├── create_security_group.sh
├── create_s3_bucket.sh
├── cleanup_resources.sh
└── README.md
```

### Log Format

```
[2025-12-15 14:00:00] [INFO] Logging initialized: ./logs/ec2_creation_20251215_140000.log
[2025-12-15 14:00:01] [SUCCESS] AWS CLI is installed
[2025-12-15 14:00:02] [INFO] Selected region: eu-west-1
[2025-12-15 14:00:05] [SUCCESS] Found AMI: ami-0d64bb532e0502c46
[2025-12-15 14:00:06] [SUCCESS] AWS credentials verified
```

### Log Levels

- **INFO**: General information and progress
- **SUCCESS**: Successful operations
- **WARNING**: Non-critical issues
- **ERROR**: Critical failures

### Viewing Logs

```bash
# View latest EC2 creation log
tail -f logs/ec2_creation_*.log | tail -1

# Search for errors across all logs
grep ERROR logs/*.log

# View specific log
cat logs/ec2_creation_20251215_140000.log

# Monitor cleanup in real-time
tail -f logs/cleanup_*.log
```

---

## Challenges & Solutions

### Challenge 1: Strict Error Handling

**Problem**: Scripts should exit immediately on any error  
**Solution**: Implemented `set -euo pipefail` for robust error handling

```bash
set -e   # Exit on error
set -u   # Error on unset variables
set -o pipefail  # Pipeline fails if any command fails
```

### Challenge 2: Region Flexibility

**Problem**: Users need to work in different regions  
**Solution**: Added interactive region selection menu with common regions and custom option

### Challenge 3: AMI ID Variations

**Problem**: AMI IDs differ across regions and change over time  
**Solution**: Implemented automatic AMI detection using AWS CLI

```bash
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023.*-x86_64" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)
```

### Challenge 4: Code Duplication

**Problem**: Similar code repeated across scripts  
**Solution**: Created reusable utility functions:

- `log()` - Centralized logging
- `print_success()`, `print_error()` - Consistent output
- `validate_aws_cli()` - AWS CLI verification
- `verify_credentials()` - Credential validation

### Challenge 5: Cleanup Complexity

**Problem**: Resources have dependencies and versioning  
**Solution**:

- Wait for instances to terminate before deleting security groups
- Handle S3 versioning by deleting all versions and delete markers
- Use error handling to continue cleanup even if some operations fail

### Challenge 6: Debugging Issues

**Problem**: Hard to troubleshoot when scripts fail  
**Solution**: Comprehensive logging system:

- All operations logged with timestamps
- Both console and file output
- Log levels for different severity
- Error traps for automatic cleanup

### Challenge 7: us-east-1 S3 Exception

**Problem**: us-east-1 doesn't use LocationConstraint parameter  
**Solution**: Conditional bucket creation logic

```bash
if [ "$REGION" == "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
else
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION"
fi
```

---

## Screenshots

Include the following screenshots in your submission:

### 1. **AWS CLI Configuration**

- Output of `aws sts get-caller-identity`

![Script Execution](screenshots/Identity.png)

- Output of `aws configure list`

![Script Execution](screenshots/Awsconfigure.png)

### 2. **EC2 Instance Creation**

- Script execution output

![Script Execution](screenshots/Ec2instance.png)

- AWS Console showing the instance

![Script Execution](screenshots/Instances.png)

### 3. **Security Group Creation**

- Script output with rules

![Script Execution](screenshots/securitygroup.png)

- AWS Console security group details

![Script Execution](screenshots/Security_Group.png)

### 4. **S3 Bucket Creation**

- Script output

![Script Execution](screenshots/s3bucket.png)

- AWS Console showing bucket and uploaded file

![Script Execution](screenshots/s3_Bucket.png)

### 5. **Cleanup Process**

- Cleanup script execution

![Script Execution](screenshots/Outputofcleanup.png)

### 6. **Log Files**

```bash
ls -lh logs/
cat logs/ec2_creation_*.log
```

---

## Best Practices Implemented

### 1. **Strict Error Handling**

```bash
set -euo pipefail

# Error trap
trap cleanup_on_error ERR
```

### 2. **Comprehensive Logging**

```bash
log "INFO" "Operation started"
log "SUCCESS" "Operation completed"
log "ERROR" "Operation failed"
```

### 3. **Modular Functions**

```bash
# Reusable function
add_ingress_rule() {
    local port="$1"
    local protocol="$2"
    local description="$3"
    # Implementation
}

# Usage
add_ingress_rule "22" "tcp" "SSH"
add_ingress_rule "80" "tcp" "HTTP"
```

### 4. **Input Validation**

```bash
if [ -z "$INSTANCE_ID" ]; then
    print_error "Failed to launch instance"
fi
```

### 5. **Progress Indicators**

```bash
print_info "[1/7] Creating EC2 key pair..."
print_info "[2/7] Getting default VPC..."
# ...
```

### 6. **Security Best Practices**

- Key files set to 400 permissions
- No hard-coded credentials
- Proper resource tagging
- Cleanup on error

### 7. **User Experience**

- Clear output with symbols (✓, ✗, ⏳, ⚠)
- Interactive prompts
- Helpful error messages
- Usage instructions in output

---

## Learning Outcomes

By completing this project, you will:

- Master `set -euo pipefail` for robust scripts
- Implement comprehensive logging systems
- Write modular, reusable functions
- Handle user input interactively
- Manage AWS resources programmatically
- Apply infrastructure-as-code principles
- Debug complex automation scripts
- Implement proper error handling and recovery

---

## Additional Resources

- [Bash Best Practices](https://bertvv.github.io/cheat-sheets/Bash.html)
- [AWS CLI Command Reference](https://docs.aws.amazon.com/cli/latest/)
- [EC2 User Guide](https://docs.aws.amazon.com/ec2/)
- [S3 Developer Guide](https://docs.aws.amazon.com/s3/)
- [Shell Script Best Practices](https://google.github.io/styleguide/shellguide.html)
