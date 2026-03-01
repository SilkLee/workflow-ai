#!/bin/bash
#
# Quick EC2 Redeploy Script for WorkflowAI Day 10
# 
# This script creates a new EC2 instance with existing IAM roles and deploys
# the complete workflow-ai stack in one command.
#
# Prerequisites:
# - WSL environment
# - AWS CLI configured
# - Existing IAM role: WorkflowAI-SSM-FixedRole
# - Corporate network: AWS_CLI_SSL_NO_VERIFY=1 required
#
# Usage:
#   wsl -e bash quick-redeploy-ec2.sh [instance-type]
#
# Examples:
#   wsl -e bash quick-redeploy-ec2.sh              # Uses t3.xlarge (default)
#   wsl -e bash quick-redeploy-ec2.sh t3.2xlarge  # Uses larger instance
#   wsl -e bash quick-redeploy-ec2.sh t3.large    # Uses smaller instance (may be slow)

set -e  # Exit on error

# ============================================================================
# Configuration
# ============================================================================

export AWS_CLI_SSL_NO_VERIFY=1
REGION="ap-southeast-1"
INSTANCE_TYPE="${1:-t3.xlarge}"  # Default to t3.xlarge, override with first arg
AMI_ID="ami-047126e50991d067b"  # Amazon Linux 2023 AMI (ap-southeast-1)
KEY_NAME=""  # No SSH key needed (SSM only)
IAM_ROLE="WorkflowAI-SSM-FixedRole"
INSTANCE_NAME="workflow-ai-$(date +%Y%m%d-%H%M%S)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

wait_for_ssm() {
    local instance_id=$1
    local max_attempts=30
    local attempt=1
    
    log_info "Waiting for SSM agent to be ready (may take 2-3 minutes)..."
    
    while [ $attempt -le $max_attempts ]; do
        SSM_STATUS=$(aws ssm describe-instance-information \
            --region "$REGION" \
            --filters "Key=InstanceIds,Values=$instance_id" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text 2>/dev/null || echo "NotFound")
        
        if [ "$SSM_STATUS" = "Online" ]; then
            log_success "SSM agent is online!"
            return 0
        fi
        
        echo -n "."
        sleep 5
        attempt=$((attempt + 1))
    done
    
    log_error "SSM agent did not come online within 2.5 minutes"
    return 1
}

wait_for_command() {
    local command_id=$1
    local instance_id=$2
    local max_attempts=60
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        STATUS=$(aws ssm get-command-invocation \
            --region "$REGION" \
            --command-id "$command_id" \
            --instance-id "$instance_id" \
            --query 'Status' \
            --output text 2>/dev/null || echo "Pending")
        
        case "$STATUS" in
            "Success")
                log_success "Command completed successfully"
                return 0
                ;;
            "Failed"|"Cancelled"|"TimedOut")
                log_error "Command failed with status: $STATUS"
                # Show error output
                aws ssm get-command-invocation \
                    --region "$REGION" \
                    --command-id "$command_id" \
                    --instance-id "$instance_id" \
                    --query '[StandardErrorContent,StandardOutputContent]' \
                    --output text
                return 1
                ;;
            *)
                echo -n "."
                sleep 5
                attempt=$((attempt + 1))
                ;;
        esac
    done
    
    log_error "Command timed out after 5 minutes"
    return 1
}

cleanup_on_error() {
    local instance_id=$1
    if [ -n "$instance_id" ]; then
        log_warn "Cleaning up failed instance: $instance_id"
        aws ec2 terminate-instances --region "$REGION" --instance-ids "$instance_id" >/dev/null 2>&1 || true
    fi
}

# ============================================================================
# Main Deployment Flow
# ============================================================================

log_info "Starting WorkflowAI EC2 deployment..."
log_info "Region: $REGION"
log_info "Instance Type: $INSTANCE_TYPE"
log_info "Instance Name: $INSTANCE_NAME"

# Step 1: Check if IAM role exists
log_info "Checking IAM role: $IAM_ROLE"
ROLE_ARN=$(aws iam get-role --role-name "$IAM_ROLE" --query 'Role.Arn' --output text 2>/dev/null || true)

if [ -z "$ROLE_ARN" ]; then
    log_error "IAM role '$IAM_ROLE' not found!"
    log_error "Please ensure the role exists before running this script."
    exit 1
fi
log_success "IAM role found: $ROLE_ARN"

# Step 2: Check/Create Instance Profile
log_info "Checking instance profile..."
PROFILE_ARN=$(aws iam get-instance-profile --instance-profile-name "$IAM_ROLE" --query 'InstanceProfile.Arn' --output text 2>/dev/null || true)

if [ -z "$PROFILE_ARN" ]; then
    log_info "Creating instance profile: $IAM_ROLE"
    aws iam create-instance-profile --instance-profile-name "$IAM_ROLE" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$IAM_ROLE" --role-name "$IAM_ROLE" >/dev/null
    # Wait for propagation
    sleep 10
    log_success "Instance profile created"
else
    log_success "Instance profile already exists"
fi

# Step 3: Check/Create Security Group
log_info "Checking security group..."
SG_ID=$(aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters "Name=group-name,Values=workflow-ai-sg" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")

if [ "$SG_ID" = "None" ]; then
    log_info "Creating security group..."
    DEFAULT_VPC=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)
    
    SG_ID=$(aws ec2 create-security-group \
        --region "$REGION" \
        --group-name "workflow-ai-sg" \
        --description "Security group for WorkflowAI deployment" \
        --vpc-id "$DEFAULT_VPC" \
        --output text --query 'GroupId')
    
    # No inbound rules needed (SSM only)
    log_success "Security group created: $SG_ID"
else
    log_success "Security group exists: $SG_ID"
fi

# Step 4: Create User Data script
log_info "Preparing user data script..."
cat > /tmp/workflow-ai-userdata.sh <<'EOF'
#!/bin/bash
set -e

# Update system
dnf update -y

# Install Docker
dnf install -y docker git
systemctl enable docker
systemctl start docker

# Install Docker Compose
DOCKER_COMPOSE_VERSION="2.24.5"
curl -L "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

# Add ec2-user to docker group
usermod -aG docker ec2-user

# Clone repository
cd /home/ec2-user
sudo -u ec2-user git clone https://github.com/SilkLee/workflow-ai.git
chown -R ec2-user:ec2-user /home/ec2-user/workflow-ai

# Create .env file (optional, can be customized)
cat > /home/ec2-user/workflow-ai/.env <<'ENVEOF'
# Model Service
MODEL_SERVICE_PORT=8004
MODEL_NAME=Qwen/Qwen2.5-1.5B-Instruct
MODEL_DEVICE=cpu

# Agent Service
AGENT_SERVICE_PORT=8002

# Infrastructure
REDIS_HOST=redis
REDIS_PORT=6379
ELASTICSEARCH_HOST=elasticsearch
ELASTICSEARCH_PORT=9200

# Optional (can leave blank if not using OpenAI)
OPENAI_API_KEY=
ENVEOF

chown ec2-user:ec2-user /home/ec2-user/workflow-ai/.env

# Start services
cd /home/ec2-user/workflow-ai
sudo -u ec2-user docker-compose up -d

# Signal completion
echo "WorkflowAI deployment complete!" > /tmp/deployment-status.txt
EOF

USER_DATA=$(base64 -w 0 /tmp/workflow-ai-userdata.sh)

# Step 5: Launch EC2 Instance
log_info "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --iam-instance-profile "Name=$IAM_ROLE" \
    --security-group-ids "$SG_ID" \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2" \
    --query 'Instances[0].InstanceId' \
    --output text)

if [ -z "$INSTANCE_ID" ]; then
    log_error "Failed to launch EC2 instance"
    exit 1
fi

log_success "Instance launched: $INSTANCE_ID"

# Set up cleanup on error from this point
trap "cleanup_on_error $INSTANCE_ID" ERR

# Step 6: Wait for instance to be running
log_info "Waiting for instance to be running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
log_success "Instance is running"

# Get instance details
INSTANCE_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)

log_info "Private IP: $INSTANCE_IP"

# Step 7: Wait for SSM agent
if ! wait_for_ssm "$INSTANCE_ID"; then
    log_error "SSM agent failed to come online"
    cleanup_on_error "$INSTANCE_ID"
    exit 1
fi

# Step 8: Wait for user data script to complete
log_info "Waiting for deployment to complete (this may take 5-10 minutes)..."
log_warn "The instance is downloading Docker images and starting services..."

sleep 60  # Give user-data script time to start

# Check deployment status
CMD_ID=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["tail -20 /var/log/cloud-init-output.log 2>/dev/null || echo \"Log not ready yet\"","test -f /tmp/deployment-status.txt && echo \"DEPLOYMENT_COMPLETE\" || echo \"DEPLOYMENT_IN_PROGRESS\""]' \
    --timeout-seconds 30 \
    --query 'Command.CommandId' \
    --output text)

sleep 10

# Check if deployment is still running
for i in {1..20}; do
    OUTPUT=$(aws ssm get-command-invocation \
        --region "$REGION" \
        --command-id "$CMD_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'StandardOutputContent' \
        --output text 2>/dev/null || echo "")
    
    if echo "$OUTPUT" | grep -q "DEPLOYMENT_COMPLETE"; then
        log_success "Deployment completed!"
        break
    fi
    
    if [ $i -eq 20 ]; then
        log_warn "Deployment is still in progress after 3+ minutes"
        log_warn "This is normal for first-time Docker image downloads"
    fi
    
    echo -n "."
    sleep 10
done

# Step 9: Verify services
log_info "Verifying services..."
sleep 30  # Give services time to fully start

VERIFY_CMD=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["cd /home/ec2-user/workflow-ai && docker-compose ps"]' \
    --timeout-seconds 30 \
    --query 'Command.CommandId' \
    --output text)

if wait_for_command "$VERIFY_CMD" "$INSTANCE_ID"; then
    log_success "Service status retrieved"
    aws ssm get-command-invocation \
        --region "$REGION" \
        --command-id "$VERIFY_CMD" \
        --instance-id "$INSTANCE_ID" \
        --query 'StandardOutputContent' \
        --output text
fi

# ============================================================================
# Deployment Complete
# ============================================================================

echo ""
echo "========================================================================"
log_success "WorkflowAI Deployment Complete!"
echo "========================================================================"
echo ""
log_info "Instance Details:"
echo "  Instance ID:   $INSTANCE_ID"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  Private IP:    $INSTANCE_IP"
echo "  Region:        $REGION"
echo ""
log_info "Connect to instance (SSM Session Manager):"
echo "  wsl -e bash -c \"export AWS_CLI_SSL_NO_VERIFY=1 && aws ssm start-session --region $REGION --target $INSTANCE_ID\""
echo ""
log_info "Test Agent Workflow:"
echo "  # After connecting via SSM:"
echo "  cd /home/ec2-user/workflow-ai"
echo "  curl -X POST http://localhost:8002/workflows/analyze-log -H 'Content-Type: application/json' -d @test-payload.json | python3 -m json.tool"
echo ""
log_info "View logs:"
echo "  docker-compose logs -f agent-orchestrator"
echo "  docker-compose logs -f model-service"
echo ""
log_info "Cleanup when done:"
echo "  wsl -e bash -c \"export AWS_CLI_SSL_NO_VERIFY=1 && aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID\""
echo ""
log_warn "Note: First Model Service request may take 30-60s to download Qwen model"
echo "========================================================================"
echo ""

# Save instance info to file
cat > workflow-ai-instance-info.txt <<INFOEOF
WorkflowAI EC2 Instance Information
====================================
Deployed: $(date)

Instance ID:   $INSTANCE_ID
Instance Type: $INSTANCE_TYPE
Private IP:    $INSTANCE_IP
Region:        $REGION
IAM Role:      $IAM_ROLE
Security Group: $SG_ID

Connect via SSM:
wsl -e bash -c "export AWS_CLI_SSL_NO_VERIFY=1 && aws ssm start-session --region $REGION --target $INSTANCE_ID"

Terminate instance:
wsl -e bash -c "export AWS_CLI_SSL_NO_VERIFY=1 && aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID"
INFOEOF

log_success "Instance info saved to: workflow-ai-instance-info.txt"

exit 0
