#!/bin/bash

################################################################################
# AWS ECS DEPLOYMENT SCRIPT - MODULAR VERSION
# 
# Improved structure with 6 stages for better maintainability:
# Stage 1: Foundation (KMS, VPC Endpoints, Log Groups)
# Stage 2: Security (IAM Roles)
# Stage 3: Infrastructure (ECR, S3, ALB, Security Groups, WAF)
# Stage 4: Compute (ECS Cluster, Services, Auto Scaling)
# Stage 5: CI/CD (CodePipeline, CodeBuild) - Optional
# Stage 6: Monitoring (Dashboards, Alarms) - Optional
#
# Version: 3.0 Modular
################################################################################

set -e
set -o pipefail

# ============================================
# CONFIGURATION
# ============================================
PROJECT_NAME="${PROJECT_NAME:-myapp}"
ENVIRONMENT="${ENVIRONMENT:-production}"
REGION="${AWS_REGION:-ap-southeast-1}"
BASE_STACK_NAME="${PROJECT_NAME}-${ENVIRONMENT}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Deployment stages (can be controlled via flags)
DEPLOY_STAGE_1=true  # Foundation
DEPLOY_STAGE_2=true  # Security
DEPLOY_STAGE_3=true  # Infrastructure
DEPLOY_STAGE_4=true  # Compute
DEPLOY_STAGE_5=false # CI/CD (optional)
DEPLOY_STAGE_6=false # Monitoring (optional)

# Track deployed stacks for rollback
DEPLOYED_STACKS=()
DEPLOYMENT_START_TIME=$(date +%s)

# ============================================
# LOGGING FUNCTIONS
# ============================================
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓ SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[⚠ WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗ ERROR]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${CYAN}=========================================="
    echo -e "$1"
    echo -e "==========================================${NC}"
    echo ""
}

log_step() {
    echo -e "${MAGENTA}[STEP]${NC} $1"
}

log_stage() {
    echo ""
    echo -e "${GREEN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo -e "┃ $1"
    echo -e "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    echo ""
}

# ============================================
# UTILITY FUNCTIONS
# ============================================
get_account_id() {
    aws sts get-caller-identity --query Account --output text
}

check_stack_exists() {
    local stack_name=$1
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$REGION" \
        &> /dev/null
}

get_stack_status() {
    local stack_name=$1
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null || echo "NOT_EXISTS"
}

wait_for_stack() {
    local stack_name=$1
    local operation=$2  # create or update
    
    log_step "Waiting for stack ${operation}..."
    
    if [ "$operation" == "create" ]; then
        aws cloudformation wait stack-create-complete \
            --stack-name "$stack_name" \
            --region "$REGION"
    else
        aws cloudformation wait stack-update-complete \
            --stack-name "$stack_name" \
            --region "$REGION"
    fi
}

show_stack_outputs() {
    local stack_name=$1
    
    log_step "Stack Outputs:"
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
        --output table 2>/dev/null || log_info "No outputs available"
}

# ============================================
# DEPLOYMENT FUNCTION
# ============================================
deploy_stack() {
    local stack_name=$1
    local template_file=$2
    local parameters_file=$3
    local capabilities=$4
    local stage_name=$5
    
    log_section "Deploying: $stage_name"
    log_info "Stack Name: $stack_name"
    log_info "Template: $template_file"
    log_info "Parameters: ${parameters_file:-None}"
    
    # Check if template exists
    if [ ! -f "$template_file" ]; then
        log_error "Template file not found: $template_file"
        return 1
    fi
    
    # Validate template
    log_step "Validating template..."
    if ! aws cloudformation validate-template \
        --template-body file://"$template_file" \
        --region "$REGION" &> /dev/null; then
        log_error "Template validation failed"
        aws cloudformation validate-template \
            --template-body file://"$template_file" \
            --region "$REGION"
        return 1
    fi
    log_success "Template is valid"
    
    # Build command
    local cmd="aws cloudformation"
    local stack_status
    stack_status=$(get_stack_status "$stack_name")
    
    if [ "$stack_status" == "NOT_EXISTS" ]; then
        log_step "Creating new stack..."
        cmd="$cmd create-stack --stack-name $stack_name"
        local operation="create"
    elif [[ "$stack_status" == *"COMPLETE"* ]]; then
        log_step "Updating existing stack..."
        cmd="$cmd update-stack --stack-name $stack_name"
        local operation="update"
    else
        log_error "Stack in invalid state: $stack_status"
        return 1
    fi
    
    cmd="$cmd --template-body file://$template_file"
    cmd="$cmd --region $REGION"
    
    if [ -n "$parameters_file" ] && [ -f "$parameters_file" ]; then
        cmd="$cmd --parameters file://$parameters_file"
    fi
    
    if [ -n "$capabilities" ]; then
        cmd="$cmd --capabilities $capabilities"
    fi
    
    cmd="$cmd --tags Key=Project,Value=$PROJECT_NAME Key=Environment,Value=$ENVIRONMENT Key=ManagedBy,Value=CloudFormation"
    
    # Execute deployment
    if eval "$cmd" 2>&1 | tee /tmp/deploy-output.txt; then
        if grep -q "No updates are to be performed" /tmp/deploy-output.txt; then
            log_info "No changes detected - stack is up to date"
            return 0
        fi
        
        # Wait for completion
        if wait_for_stack "$stack_name" "$operation"; then
            log_success "Stack ${operation}d successfully!"
            DEPLOYED_STACKS+=("$stack_name")
            show_stack_outputs "$stack_name"
            return 0
        else
            log_error "Stack ${operation} failed"
            show_stack_events "$stack_name"
            return 1
        fi
    else
        if grep -q "No updates are to be performed" /tmp/deploy-output.txt; then
            log_info "No changes detected - stack is up to date"
            return 0
        fi
        log_error "Failed to ${operation} stack"
        return 1
    fi
}

show_stack_events() {
    local stack_name=$1
    
    log_error "Recent stack events:"
    aws cloudformation describe-stack-events \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --max-items 15 \
        --query 'StackEvents[?ResourceStatus!=`CREATE_COMPLETE` && ResourceStatus!=`UPDATE_COMPLETE`].[Timestamp,ResourceStatus,ResourceType,ResourceStatusReason]' \
        --output table
}

# ============================================
# ROLLBACK FUNCTION
# ============================================
rollback_deployment() {
    log_section "🔄 Rolling Back Deployment"
    
    log_warning "The following stacks were deployed:"
    for stack in "${DEPLOYED_STACKS[@]}"; do
        echo "  - $stack"
    done
    echo ""
    
    read -p "Do you want to rollback these stacks? (yes/no): " CONFIRM
    
    if [ "$CONFIRM" == "yes" ]; then
        # Rollback in reverse order
        for ((idx=${#DEPLOYED_STACKS[@]}-1 ; idx>=0 ; idx--)); do
            local stack="${DEPLOYED_STACKS[idx]}"
            log_step "Deleting stack: $stack"
            
            aws cloudformation delete-stack \
                --stack-name "$stack" \
                --region "$REGION"
            
            log_info "Waiting for deletion to complete..."
            aws cloudformation wait stack-delete-complete \
                --stack-name "$stack" \
                --region "$REGION" || true
            
            log_success "Stack deleted: $stack"
        done
        
        log_success "Rollback completed"
    else
        log_info "Rollback cancelled - stacks will remain"
    fi
}

# ============================================
# STAGE DEPLOYMENT FUNCTIONS
# ============================================

deploy_stage_1_foundation() {
    if [ "$DEPLOY_STAGE_1" != "true" ]; then
        log_info "Stage 1 (Foundation) skipped"
        return 0
    fi
    
    log_stage "STAGE 1: FOUNDATION"
    log_info "KMS Keys, VPC Endpoints, CloudWatch Log Groups"
    
    # For now, this is combined in the infrastructure template
    # In a fully modular setup, you'd have separate templates:
    # - 1-foundation-kms.yaml
    # - 1-foundation-vpc-endpoints.yaml
    # - 1-foundation-logs.yaml
    
    log_info "Foundation resources will be created in Infrastructure stage"
    log_success "Stage 1 preparation complete"
    return 0
}

deploy_stage_2_security() {
    if [ "$DEPLOY_STAGE_2" != "true" ]; then
        log_info "Stage 2 (Security) skipped"
        return 0
    fi
    
    log_stage "STAGE 2: SECURITY (IAM ROLES)"
    
    local stack_name="${BASE_STACK_NAME}-security"
    local template="2-iam-roles-optimized.yaml"
    local params=""
    
    # IAM roles template uses StackName parameter
    # Create temporary parameter file
    cat > /tmp/iam-params.json <<EOF
[
  {
    "ParameterKey": "StackName",
    "ParameterValue": "${BASE_STACK_NAME}"
  }
]
EOF
    
    if deploy_stack \
        "$stack_name" \
        "$template" \
        "/tmp/iam-params.json" \
        "CAPABILITY_NAMED_IAM" \
        "IAM Roles & Permissions"; then
        log_success "✓ Stage 2 complete"
        return 0
    else
        log_error "✗ Stage 2 failed"
        return 1
    fi
}

deploy_stage_3_infrastructure() {
    if [ "$DEPLOY_STAGE_3" != "true" ]; then
        log_info "Stage 3 (Infrastructure) skipped"
        return 0
    fi
    
    log_stage "STAGE 3: INFRASTRUCTURE"
    log_info "ECR, S3, ALB, Security Groups, VPC Endpoints, WAF"
    
    local stack_name="${BASE_STACK_NAME}"
    local template="1-infrastructure-production-ready.yaml"
    local params="parameters-part1-${ENVIRONMENT}.json"
    
    if [ ! -f "$params" ]; then
        params="parameters-part1-prod.json"
        log_warning "Using default parameters: $params"
    fi
    
    if deploy_stack \
        "$stack_name" \
        "$template" \
        "$params" \
        "" \
        "Infrastructure (ECR, S3, ALB, WAF)"; then
        log_success "✓ Stage 3 complete"
        
        # Show important outputs
        log_info "Important Infrastructure URLs:"
        aws cloudformation describe-stacks \
            --stack-name "$stack_name" \
            --region "$REGION" \
            --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerURL` || OutputKey==`LoadBalancerDNS`].[OutputKey,OutputValue]' \
            --output table
        
        return 0
    else
        log_error "✗ Stage 3 failed"
        return 1
    fi
}

deploy_stage_4_compute() {
    if [ "$DEPLOY_STAGE_4" != "true" ]; then
        log_info "Stage 4 (Compute) skipped"
        return 0
    fi
    
    log_stage "STAGE 4: COMPUTE (ECS)"
    log_info "ECS Cluster, Services, Task Definitions, Auto Scaling"
    
    local stack_name="${BASE_STACK_NAME}"
    local template="3-ecs-cluster-production-ready.yaml"
    local params="parameters-part3-${ENVIRONMENT}.json"
    
    if [ ! -f "$params" ]; then
        params="parameters-part3-prod.json"
        log_warning "Using default parameters: $params"
    fi
    
    if deploy_stack \
        "$stack_name" \
        "$template" \
        "$params" \
        "" \
        "ECS Cluster & Services"; then
        log_success "✓ Stage 4 complete"
        
        # Show ECS services status
        log_info "ECS Services:"
        aws ecs describe-services \
            --cluster "${BASE_STACK_NAME}-Cluster" \
            --services "${BASE_STACK_NAME}-frontend-svc" "${BASE_STACK_NAME}-backend-svc" \
            --region "$REGION" \
            --query 'services[*].[serviceName,status,runningCount,desiredCount]' \
            --output table 2>/dev/null || log_warning "Services not yet ready"
        
        return 0
    else
        log_error "✗ Stage 4 failed"
        return 1
    fi
}

deploy_stage_5_cicd() {
    if [ "$DEPLOY_STAGE_5" != "true" ]; then
        log_info "Stage 5 (CI/CD) skipped"
        return 0
    fi
    
    log_stage "STAGE 5: CI/CD PIPELINE"
    log_info "CodePipeline, CodeBuild, Initial Image Builders"
    
    # Check if GitHub connection exists
    read -p "Enter GitHub Connection ARN (or 'skip' to skip CI/CD): " GITHUB_CONNECTION
    
    if [ "$GITHUB_CONNECTION" == "skip" ]; then
        log_info "CI/CD deployment skipped by user"
        return 0
    fi
    
    local stack_name="${BASE_STACK_NAME}-cicd"
    local template="4-cicd-pipeline-optimized.yaml"
    
    # Create temporary parameter file with GitHub connection
    cat > /tmp/cicd-params.json <<EOF
[
  {
    "ParameterKey": "GitHubConnectionArn",
    "ParameterValue": "${GITHUB_CONNECTION}"
  },
  {
    "ParameterKey": "GitHubRepoFrontend",
    "ParameterValue": "your-org/frontend-repo"
  },
  {
    "ParameterKey": "GitHubRepoBackend",
    "ParameterValue": "your-org/backend-repo"
  },
  {
    "ParameterKey": "GitHubBranch",
    "ParameterValue": "main"
  },
  {
    "ParameterKey": "Environment",
    "ParameterValue": "${ENVIRONMENT}"
  }
]
EOF
    
    log_warning "Update GitHub repository names in /tmp/cicd-params.json before continuing"
    read -p "Press Enter when ready..."
    
    if deploy_stack \
        "$stack_name" \
        "$template" \
        "/tmp/cicd-params.json" \
        "" \
        "CI/CD Pipeline"; then
        log_success "✓ Stage 5 complete"
        return 0
    else
        log_error "✗ Stage 5 failed (but infrastructure is still usable)"
        return 1
    fi
}

deploy_stage_6_monitoring() {
    if [ "$DEPLOY_STAGE_6" != "true" ]; then
        log_info "Stage 6 (Monitoring) skipped"
        return 0
    fi
    
    log_stage "STAGE 6: MONITORING"
    log_info "CloudWatch Dashboards, Additional Alarms"
    
    # Monitoring is currently integrated in the ECS template
    # In a fully modular setup, you'd have:
    # - 6-monitoring-dashboards.yaml
    # - 6-monitoring-alarms.yaml
    
    log_info "Basic monitoring is already included in previous stages"
    
    # Create SNS subscription for alerts
    local sns_topic_arn
    sns_topic_arn=$(aws cloudformation describe-stacks \
        --stack-name "${BASE_STACK_NAME}" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`SNSTopicArn`].OutputValue' \
        --output text 2>/dev/null)
    
    if [ -n "$sns_topic_arn" ]; then
        log_info "SNS Topic for alerts: $sns_topic_arn"
        read -p "Enter email for alert notifications (or 'skip'): " ALERT_EMAIL
        
        if [ "$ALERT_EMAIL" != "skip" ] && [ -n "$ALERT_EMAIL" ]; then
            aws sns subscribe \
                --topic-arn "$sns_topic_arn" \
                --protocol email \
                --notification-endpoint "$ALERT_EMAIL" \
                --region "$REGION"
            log_success "Alert subscription created - check your email for confirmation"
        fi
    fi
    
    log_success "✓ Stage 6 complete"
    return 0
}

# ============================================
# PRE-DEPLOYMENT CHECKS
# ============================================
pre_deployment_checks() {
    log_section "🔍 Pre-Deployment Checks"
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found"
        exit 1
    fi
    log_success "AWS CLI found: $(aws --version 2>&1 | cut -d' ' -f1)"
    
    # Check credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured"
        exit 1
    fi
    
    local account_id
    account_id=$(get_account_id)
    log_success "AWS Account: $account_id"
    
    # Check required files
    local required_files=(
        "1-infrastructure-production-ready.yaml"
        "2-iam-roles-optimized.yaml"
        "3-ecs-cluster-production-ready.yaml"
    )
    
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "Required file not found: $file"
            exit 1
        fi
    done
    log_success "All required files found"
    
    # Validate templates
    log_step "Validating CloudFormation templates..."
    for template in *.yaml; do
        if aws cloudformation validate-template \
            --template-body file://"$template" \
            --region "$REGION" &> /dev/null; then
            log_success "✓ $template"
        else
            log_error "✗ $template validation failed"
            exit 1
        fi
    done
    
    log_success "All checks passed!"
}

# ============================================
# POST-DEPLOYMENT SUMMARY
# ============================================
show_deployment_summary() {
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - DEPLOYMENT_START_TIME))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    log_section "📋 DEPLOYMENT SUMMARY"
    
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  🎉 DEPLOYMENT COMPLETE!                ┃"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
    echo ""
    echo "Project:       $PROJECT_NAME"
    echo "Environment:   $ENVIRONMENT"
    echo "Region:        $REGION"
    echo "Duration:      ${minutes}m ${seconds}s"
    echo ""
    
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  DEPLOYED STACKS                        ┃"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
    for stack in "${DEPLOYED_STACKS[@]}"; do
        local status
        status=$(get_stack_status "$stack")
        echo "  ✓ $stack [$status]"
    done
    echo ""
    
    # Get ALB URL
    local alb_url
    alb_url=$(aws cloudformation describe-stacks \
        --stack-name "${BASE_STACK_NAME}" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerURL`].OutputValue' \
        --output text 2>/dev/null)
    
    if [ -n "$alb_url" ]; then
        echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
        echo "┃  APPLICATION URLs                       ┃"
        echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
        echo "  Frontend:      $alb_url"
        echo "  Backend API:   $alb_url/api"
        echo "  Health Check:  $alb_url/health"
        echo ""
    fi
    
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  NEXT STEPS                             ┃"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
    echo "1. Push Docker images to ECR:"
    echo "   aws ecr get-login-password --region $REGION | \\"
    echo "     docker login --username AWS --password-stdin $(get_account_id).dkr.ecr.$REGION.amazonaws.com"
    echo ""
    echo "2. Monitor ECS services:"
    echo "   watch -n 5 'aws ecs describe-services --cluster ${BASE_STACK_NAME}-Cluster \\"
    echo "     --services ${BASE_STACK_NAME}-frontend-svc ${BASE_STACK_NAME}-backend-svc \\"
    echo "     --region $REGION --query \"services[*].[serviceName,runningCount]\" --output table'"
    echo ""
    echo "3. View logs:"
    echo "   aws logs tail /ecs/${BASE_STACK_NAME}/backend --follow --region $REGION"
    echo ""
    
    log_success "Deployment completed successfully!"
}

# ============================================
# MAIN FUNCTION
# ============================================
main() {
    clear
    
    log_section "🚀 AWS ECS MODULAR DEPLOYMENT v3.0"
    
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  CONFIGURATION                          ┃"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
    echo "Project:       $PROJECT_NAME"
    echo "Environment:   $ENVIRONMENT"
    echo "Region:        $REGION"
    echo "Stack Name:    $BASE_STACK_NAME"
    echo ""
    
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  DEPLOYMENT STAGES                      ┃"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
    echo "  1. Foundation      [$([ "$DEPLOY_STAGE_1" == "true" ] && echo "✓" || echo "⊗")]"
    echo "  2. Security        [$([ "$DEPLOY_STAGE_2" == "true" ] && echo "✓" || echo "⊗")]"
    echo "  3. Infrastructure  [$([ "$DEPLOY_STAGE_3" == "true" ] && echo "✓" || echo "⊗")]"
    echo "  4. Compute         [$([ "$DEPLOY_STAGE_4" == "true" ] && echo "✓" || echo "⊗")]"
    echo "  5. CI/CD           [$([ "$DEPLOY_STAGE_5" == "true" ] && echo "✓" || echo "⊗")] (optional)"
    echo "  6. Monitoring      [$([ "$DEPLOY_STAGE_6" == "true" ] && echo "✓" || echo "⊗")] (optional)"
    echo ""
    
    read -p "Continue with deployment? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log_info "Deployment cancelled"
        exit 0
    fi
    
    # Run pre-deployment checks
    pre_deployment_checks
    
    # Deploy stages
    local failed=false
    
    deploy_stage_1_foundation || failed=true
    [ "$failed" == "true" ] && { rollback_deployment; exit 1; }
    
    deploy_stage_2_security || failed=true
    [ "$failed" == "true" ] && { rollback_deployment; exit 1; }
    
    deploy_stage_3_infrastructure || failed=true
    [ "$failed" == "true" ] && { rollback_deployment; exit 1; }
    
    deploy_stage_4_compute || failed=true
    [ "$failed" == "true" ] && { rollback_deployment; exit 1; }
    
    # Optional stages - don't fail deployment if these fail
    deploy_stage_5_cicd || log_warning "Stage 5 failed but continuing..."
    deploy_stage_6_monitoring || log_warning "Stage 6 failed but continuing..."
    
    # Show summary
    show_deployment_summary
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-cicd)
            DEPLOY_STAGE_5=false
            shift
            ;;
        --skip-monitoring)
            DEPLOY_STAGE_6=false
            shift
            ;;
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
        --help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --project NAME         Project name (default: myapp)"
            echo "  --environment ENV      Environment (default: production)"
            echo "  --region REGION        AWS region (default: ap-southeast-1)"
            echo "  --skip-cicd            Skip CI/CD deployment"
            echo "  --skip-monitoring      Skip monitoring deployment"
            echo "  --help                 Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Run main function
main "$@"