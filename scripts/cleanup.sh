#!/bin/bash

################################################################################
# CLEANUP SCRIPT
# 
# Safely deletes all CloudFormation stacks and associated resources
#
# Usage:
#   ./cleanup.sh [options]
#
# Options:
#   --project NAME         Project name
#   --environment ENV      Environment
#   --region REGION        AWS region
#   --confirm              Skip confirmation prompt
#   --help                 Show help
################################################################################

set -e
set -o pipefail

PROJECT_NAME="${PROJECT_NAME:-aqua-sample-app}"
ENVIRONMENT="${ENVIRONMENT:-production}"
REGION="${AWS_REGION:-ap-southeast-1}"
SKIP_CONFIRM=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[⚠ WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗ ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓ SUCCESS]${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --project)
            PROJECT_NAME="$2"
            shift 2
            ;;
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --confirm)
            SKIP_CONFIRM=true
            shift
            ;;
        --help)
            head -n 20 "$0" | tail -n +3
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

BASE_NAME="${PROJECT_NAME}-${ENVIRONMENT}"

# All stacks in reverse dependency order
STACKS=(
    # Stage 6: Monitoring
    "${BASE_NAME}-dashboards"
    "${BASE_NAME}-alarms"
    "${BASE_NAME}-sns"
    
    # Stage 5: CI/CD
    "${BASE_NAME}-codepipeline"
    "${BASE_NAME}-codebuild"
    "${BASE_NAME}-init-builders"
    
    # Stage 4: Compute
    "${BASE_NAME}-autoscaling"
    "${BASE_NAME}-services"
    "${BASE_NAME}-tasks"
    "${BASE_NAME}-service-discovery"
    "${BASE_NAME}-ecs"
    
    # Stage 3: Infrastructure
    "${BASE_NAME}-waf"
    "${BASE_NAME}-alb"
    "${BASE_NAME}-sg"
    "${BASE_NAME}-s3"
    "${BASE_NAME}-ecr"
    
    # Stage 2: Security
    "${BASE_NAME}-secrets"
    "${BASE_NAME}-iam"
    
    # Stage 1: Foundation
    "${BASE_NAME}-vpc-endpoints"
    "${BASE_NAME}-logs"
    "${BASE_NAME}-kms"
)

echo ""
echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  ⚠️  CLEANUP WARNING                   ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""
log_warning "This will DELETE ALL resources for:"
echo "  Project:     $PROJECT_NAME"
echo "  Environment: $ENVIRONMENT"
echo "  Region:      $REGION"
echo ""
log_warning "This action is IRREVERSIBLE!"
echo ""

# List existing stacks
log_info "Checking for existing stacks..."
EXISTING_STACKS=()

for stack in "${STACKS[@]}"; do
    if aws cloudformation describe-stacks \
        --stack-name "$stack" \
        --region "$REGION" &> /dev/null; then
        EXISTING_STACKS+=("$stack")
    fi
done

if [ ${#EXISTING_STACKS[@]} -eq 0 ]; then
    log_info "No stacks found to delete"
    exit 0
fi

echo ""
log_info "Found ${#EXISTING_STACKS[@]} stack(s) to delete:"
for stack in "${EXISTING_STACKS[@]}"; do
    echo "  - $stack"
done
echo ""

# Confirmation
if [ "$SKIP_CONFIRM" != "true" ]; then
    log_warning "Type 'DELETE' in UPPERCASE to confirm:"
    read -p "> " CONFIRM
    
    if [ "$CONFIRM" != "DELETE" ]; then
        log_info "Cleanup cancelled"
        exit 0
    fi
fi

echo ""
log_info "Starting cleanup process..."
echo ""

# Delete S3 buckets first (empty them)
log_info "Step 1: Emptying S3 buckets..."
for bucket in $(aws s3 ls | grep "${BASE_NAME}" | awk '{print $3}'); do
    log_info "Emptying bucket: $bucket"
    aws s3 rm s3://$bucket --recursive --region "$REGION" || true
done

# Delete ECR images
log_info "Step 2: Deleting ECR images..."
for repo in $(aws ecr describe-repositories \
    --region "$REGION" \
    --query "repositories[?contains(repositoryName, '${BASE_NAME}')].repositoryName" \
    --output text); do
    log_info "Deleting images from: $repo"
    aws ecr batch-delete-image \
        --repository-name "$repo" \
        --region "$REGION" \
        --image-ids "$(aws ecr list-images \
            --repository-name "$repo" \
            --region "$REGION" \
            --query 'imageIds[*]' \
            --output json)" || true
done

# Delete CloudFormation stacks
log_info "Step 3: Deleting CloudFormation stacks..."
echo ""

for stack in "${EXISTING_STACKS[@]}"; do
    log_info "Deleting: $stack"
    
    aws cloudformation delete-stack \
        --stack-name "$stack" \
        --region "$REGION"
    
    log_info "Waiting for deletion..."
    
    if aws cloudformation wait stack-delete-complete \
        --stack-name "$stack" \
        --region "$REGION" 2>/dev/null; then
        log_success "✓ Deleted: $stack"
    else
        log_warning "⚠ Deletion may have failed or timed out: $stack"
        log_info "Check AWS Console for details"
    fi
    
    echo ""
done

# Final cleanup check
log_info "Step 4: Final verification..."
REMAINING=0

for stack in "${EXISTING_STACKS[@]}"; do
    if aws cloudformation describe-stacks \
        --stack-name "$stack" \
        --region "$REGION" &> /dev/null; then
        log_warning "Stack still exists: $stack"
        ((REMAINING++))
    fi
done

echo ""
if [ $REMAINING -eq 0 ]; then
    log_success "🎉 All stacks deleted successfully!"
else
    log_warning "$REMAINING stack(s) may still exist"
    log_info "Run this script again or check AWS Console"
fi

echo ""
log_info "Cleanup Summary:"
echo "  Total stacks found:    ${#EXISTING_STACKS[@]}"
echo "  Successfully deleted:  $((${#EXISTING_STACKS[@]} - REMAINING))"
echo "  Remaining:             $REMAINING"
echo ""

if [ $REMAINING -eq 0 ]; then
    log_success "✓ Cleanup completed successfully"
    exit 0
else
    log_warning "⚠ Some resources may need manual cleanup"
    exit 1
fi