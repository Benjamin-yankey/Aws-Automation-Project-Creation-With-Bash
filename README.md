# AWS Resource Automation with Bash

![AWS](https://img.shields.io/badge/AWS-Cloud-orange) ![Bash](https://img.shields.io/badge/Bash-Scripting-green) ![Status](https://img.shields.io/badge/Status-Active-success)

## Project Overview

This project automates the creation and management of essential AWS resources using Bash scripts and the AWS CLI. It eliminates manual, error-prone processes by providing scripts to create EC2 instances, Security Groups, and S3 buckets programmatically.

**Project Goal:** Streamline AWS infrastructure provisioning for development teams through automation.

---

## Learning Objectives Achieved

- Programmatic AWS resource management using AWS CLI
- Bash scripting for infrastructure automation
- Error handling and validation in automation scripts
- AWS security best practices (IAM, Security Groups)
- Infrastructure tagging and resource cleanup

---

## Repository Structure

```
aws-automation-project/
│
├── create_security_group.sh    # Creates AWS Security Group
├── create_ec2.sh                # Creates EC2 instance with key pair
├── create_s3_bucket.sh          # Creates S3 bucket with versioning
├── cleanup_resources.sh         # Deletes all created resources
├── README.md                    # This file
├── screenshots/                 # Execution screenshots
│   ├── security-group.png
│   ├── ec2-instance.png
│   ├── s3-bucket.png
│   └── cleanup.png
└── .gitignore                   # Git ignore file
```

---

## Prerequisites

### Required Tools

- **AWS Account** (Free Tier eligible)
- **AWS CLI** v2.x installed
- **Bash** shell (Linux/macOS/WSL/Git Bash)
- **Git** for version control

### AWS Permissions Required

The IAM user needs these policies:

- `AmazonEC2FullAccess`
- `AmazonS3FullAccess`
- `IAMReadOnlyAccess`

---

## Setup Instructions

### 1. Install AWS CLI

**Linux/macOS:**

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version
```

**Windows:**
Download from: https://aws.amazon.com/cli/

### 2. Configure AWS Credentials

```bash
aws configure
```

Enter your:

- AWS Access Key ID
- AWS Secret Access Key
- Default region (e.g., `us-east-1`)
- Output format: `json`

### 3. Verify Configuration

```bash
aws sts get-caller-identity
aws configure list
```

### 4. Clone Repository

```bash
git clone https://github.com/yourusername/aws-automation-project.git
cd aws-automation-project
```

### 5. Make Scripts Executable

```bash
chmod +x *.sh
```

---

## Script Usage Guide

### Script 1: Create Security Group

**Purpose:** Creates a security group with SSH (port 22) and HTTP (port 80) access.

```bash
./create_security_group.sh
```

**What it does:**

- Finds or uses the default VPC
- Creates security group named `devops-sg`
- Opens ports 22 (SSH) and 80 (HTTP)
- Tags resources with `Project=AutomationLab`
- Saves Security Group ID to `.sg_id.txt`

**Output:** Security Group ID, VPC ID, and inbound rules table

---

### Script 2: Create EC2 Instance

**Purpose:** Launches an EC2 instance with an SSH key pair.

```bash
./create_ec2.sh
```

**What it does:**

- Creates SSH key pair (`devops-automation-key.pem`)
- Finds latest Amazon Linux 2 AMI
- Launches t2.micro instance (Free Tier)
- Attaches security group from Script 1
- Tags instance with project metadata
- Saves Instance ID to `.instance_id.txt`

**Output:** Instance ID, Public IP, SSH connection command

**Connect to instance:**

```bash
ssh -i devops-automation-key.pem ec2-user@<PUBLIC_IP>
```

---

### Script 3: Create S3 Bucket

**Purpose:** Creates an S3 bucket with versioning and uploads a sample file.

```bash
./create_s3_bucket.sh
```

**What it does:**

- Creates uniquely named bucket (timestamp-based)
- Enables versioning
- Applies bucket policy
- Creates and uploads `welcome.txt`
- Saves bucket name to `.bucket_name.txt`

**Output:** Bucket name, region, file URL, contents listing

---

### Script 4: Cleanup Resources

**Purpose:** Safely deletes all resources created by the scripts.

```bash
./cleanup_resources.sh
```

**What it does:**

- Terminates EC2 instances
- Deletes key pairs and .pem files
- Empties and deletes S3 buckets (including versions)
- Removes security groups
- Cleans up all tracking files

**Warning:** This is destructive! Confirms before proceeding.

---

## Advanced Usage

### Run All Scripts in Sequence

```bash
./create_security_group.sh && \
./create_ec2.sh && \
./create_s3_bucket.sh
```

### Verify Resources in AWS Console

After running scripts, check:

- **EC2 Dashboard:** Instances, Key Pairs, Security Groups
- **S3 Console:** Buckets and uploaded files
- **CloudTrail:** API activity logs

### Modify Configuration Variables

Edit the scripts to customize:

- Instance types
- Region settings
- Bucket naming conventions
- Security group rules

---

## Testing & Validation

### Manual Testing Steps

1. **Test Security Group:**

   ```bash
   aws ec2 describe-security-groups --group-ids <SG_ID>
   ```

2. **Test EC2 Instance:**

   ```bash
   aws ec2 describe-instances --instance-ids <INSTANCE_ID>
   ssh -i devops-automation-key.pem ec2-user@<PUBLIC_IP>
   ```

3. **Test S3 Bucket:**
   ```bash
   aws s3 ls s3://<BUCKET_NAME>/
   aws s3api get-bucket-versioning --bucket <BUCKET_NAME>
   ```

---

## Troubleshooting

### Common Issues

**Problem:** "InvalidKeyPair.NotFound"

- **Solution:** Delete `.pem` file and re-run `create_ec2.sh`

**Problem:** "BucketAlreadyExists"

- **Solution:** S3 bucket names are globally unique. Script uses timestamps to avoid this.

**Problem:** "UnauthorizedOperation"

- **Solution:** Check IAM permissions for your user

**Problem:** Security group won't delete

- **Solution:** Ensure EC2 instances are fully terminated first (wait 2-3 minutes)

**Problem:** SSH connection timeout

- **Solution:** Check security group allows port 22 from your IP, verify instance is running

---

## Challenges Faced & Solutions

### Challenge 1: Region-Specific S3 Bucket Creation

**Issue:** Different regions require different bucket creation syntax.

**Solution:** Added conditional logic to handle `us-east-1` differently:

```bash
if [ "$AWS_REGION" == "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME"
else
    aws s3api create-bucket --bucket "$BUCKET_NAME" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
fi
```

### Challenge 2: Script Dependencies

**Issue:** EC2 script needs security group ID from previous script.

**Solution:** Scripts save IDs to hidden files (`.sg_id.txt`, `.instance_id.txt`) for inter-script communication.

### Challenge 3: S3 Bucket Cleanup with Versioning

**Issue:** Cannot delete buckets with objects or versions inside.

**Solution:** Cleanup script:

1. Deletes all objects
2. Deletes all versions
3. Deletes delete markers
4. Finally deletes bucket

### Challenge 4: Security Group Deletion Timing

**Issue:** Cannot delete security groups while attached to instances.

**Solution:** Added `sleep 5` delay and error handling to wait for instances to fully terminate.

---

## Security Best Practices

**Implemented in Scripts:**

- Never hardcode credentials (uses `aws configure`)
- Restricts security groups to necessary ports only
- Tags all resources for accountability
- Uses IAM roles/policies principle of least privilege
- `.pem` key files have 400 permissions (read-only by owner)

**Additional Recommendations:**

- Rotate AWS access keys regularly
- Use MFA on AWS root account
- Review CloudTrail logs periodically
- Enable AWS GuardDuty for threat detection
- Use VPC security groups instead of 0.0.0.0/0 in production

---

## Cost Considerations

All resources created are **Free Tier eligible**, but be aware:

| Resource     | Free Tier Limit | Cost if Exceeded  |
| ------------ | --------------- | ----------------- |
| t2.micro EC2 | 750 hrs/month   | ~$0.0116/hour     |
| S3 Storage   | 5 GB            | ~$0.023/GB/month  |
| S3 Requests  | 20,000 GET      | ~$0.0004/1000 GET |

**Tip:** Always run `cleanup_resources.sh` after testing to avoid unexpected charges!

---

## Future Enhancements

Potential improvements for this project:

- [ ] Add CloudFormation template export
- [ ] Implement logging to CloudWatch
- [ ] Add support for multiple regions
- [ ] Create ELB + Auto Scaling Group scripts
- [ ] Integrate with Terraform for state management
- [ ] Add RDS database provisioning
- [ ] Implement automated backups
- [ ] Add CI/CD pipeline integration

---

## References & Resources

- [AWS CLI Documentation](https://docs.aws.amazon.com/cli/)
- [Bash Scripting Guide](https://www.gnu.org/software/bash/manual/)
- [AWS Free Tier](https://aws.amazon.com/free/)
- [AWS Security Best Practices](https://aws.amazon.com/security/best-practices/)

---

## Author

**Your Name**

- GitHub: [@yourusername](https://github.com/yourusername)
- Email: frodoandimaro0@gmail.com

---

## Acknowledgments

- DevOps Academy instructors and mentors
- AWS documentation team
- Open-source community

---

**If you found this project helpful, please give it a star!**
