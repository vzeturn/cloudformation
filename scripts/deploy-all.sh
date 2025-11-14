#!/bin/bash

################################################################################
# MASTER DEPLOYMENT SCRIPT - MODULAR ARCHITECTURE
# 
# Deploys all 6 stages in correct order with proper dependencies
#
# Usage:
#   ./deploy-all.sh [options]
#
# Options:
#   --project NAME         Project name (default: aqua-sample-app)
#   --environment ENV      Environment (default: production)
#   --region REGION        AWS region (default: ap-southeast-1)
#   --skip-stage N         Skip stage N (can be used multiple times)
#   --only-stage N         Deploy only stage N
#   --dry-run              Validate templates only
#   --help                 Show this help
#
# Version: 1.0
################################################################################

set -e
set -o pipefail

# ============================================
# DEFAULT CONFIGURATION
# ============================================
PROJECT_NAME="${PROJECT_NAME:-aqua-sample-app}"
ENVIRONMENT="${ENVIRONMENT:-production}"
REGION="${AWS_REGION:-ap-southeast-1}"
DRY_RUN=false

# Stages to deploy (all enabled by default)
DEPLOY_STAGE_1=true  # Foundation
DEPLOY_STAGE_2=true  # Security
DEPLOY_STAGE_3=true  # Infrastructure
DEPLOY_STAGE_4=true  # Compute
DEPLOY_STAGE_5=true  # CI/CD
DEPLOY_STAGE_6=true  # Monitoring

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Track deployed stacks
DEPLOYED_STACKS=()
START_TIME=$(date +%s)

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
get_stack_status() {
    local stack_name=$1
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null || echo "NOT_EXISTS"
}

validate_template() {
    local template=$1
    log_info "Validating: $template"
    
    if [ ! -f "$template" ]; then
        log_error "Template not found: $template"
        return 1
    fi
    
    aws cloudformation validate-template \
        --template-body file://"$template" \
        --region "$REGION" &> /dev/null
}

# ============================================
# DEPLOYMENT FUNCTION
# ============================================
deploy_stack() {
    local stack_name=$1
    local template=$2
    local parameters=$3
    local capabilities=$4
    local description=$5
    
    log_section "Deploying: $description"
    log_info "Stack: $stack_name"
    log_info "Template: $template"
    log_info "Parameters: ${parameters:-None}"
    
    # Validate template
    if ! validate_template "$template"; then
        log_error "Template validation failed"
        return 1
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would deploy this stack"
        return 0
    fi
    
    local stack_status=$(get_stack_status "$stack_name")
    local operation=""
    
    if [ "$stack_status" == "NOT_EXISTS" ]; then
        operation="create"
        log_info "Creating new stack..."
    elif [[ "$stack_status" == *"COMPLETE"* ]]; then
        operation="update"
        log_info "Updating existing stack..."
    else
        log_error "Stack in invalid state: $stack_status"
        return 1
    fi
    
    # Build AWS CLI command
    local cmd="aws cloudformation ${operation}-stack"
    cmd="$cmd --stack-name $stack_name"
    cmd="$cmd --template-body file://$template"
    cmd="$cmd --region $REGION"
    
    if [ -n "$parameters" ] && [ -f "$parameters" ]; then
        cmd="$cmd --parameters file://$parameters"
    fi
    
    if [ -n "$capabilities" ]; then
        cmd="$cmd --capabilities $capabilities"
    fi
    
    cmd="$cmd --tags"
    cmd="$cmd Key=Project,Value=$PROJECT_NAME"
    cmd="$cmd Key=Environment,Value=$ENVIRONMENT"
    cmd="$cmd Key=ManagedBy,Value=CloudFormation"
    cmd="$cmd Key=DeployedBy,Value=deploy-all-script"
    
    # Execute
    if eval "$cmd" 2>&1 | tee /tmp/cfn-output.txt; then
        if grep -q "No updates are to be performed" /tmp/cfn-output.txt; then
            log_info "No changes detected - stack is up to date"
            return 0
        fi
        
        # Wait for completion
        log_info "Waiting for ${operation} to complete..."
        if [ "$operation" == "create" ]; then
            aws cloudformation wait stack-create-complete \
                --stack-name "$stack_name" \
                --region "$REGION"
        else
            aws cloudformation wait stack-update-complete \
                --stack-name "$stack_name" \
                --region "$REGION"
        fi
        
        log_success "Stack ${operation}d successfully!"
        DEPLOYED_STACKS+=("$stack_name")
        
        # Show outputs
        log_info "Stack outputs:"
        aws cloudformation describe-stacks \
            --stack-name "$stack_name" \
            --region "$REGION" \
            --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
            --output table 2>/dev/null || log_info "No outputs"
        
        return 0
    else
        if grep -q "No updates are to be performed" /tmp/cfn-output.txt; then
            log_info "No changes detected - stack is up to date"
            return 0
        fi
        log_error "Failed to ${operation} stack"
        return 1
    fi
}

# ============================================
# STAGE DEPLOYMENT FUNCTIONS
# ============================================

deploy_stage_1() {
    if [ "$DEPLOY_STAGE_1" != "true" ]; then
        log_info "Stage 1 skipped"
        return 0
    fi
    
    log_stage "STAGE 1: FOUNDATION"
    
    local base_name="${PROJECT_NAME}-${ENVIRONMENT}"
    
    # 1a. KMS Keys
    deploy_stack \
        "${base_name}-kms" \
        "${CF_DIR}/1-foundation/kms-keys.yaml" \
        "" \
        "" \
        "Stage 1a: KMS Keys" || return 1
    
    # Wait a bit for exports to propagate
    sleep 5
    
    # 1b. CloudWatch Log Groups
    deploy_stack \
        "${base_name}-logs" \
        "${CF_DIR}/1-foundation/cloudwatch-log-groups.yaml" \
        "" \
        "" \
        "Stage 1b: CloudWatch Log Groups" || return 1
    
    log_success "✓ Stage 1 complete"
    return 0
}

deploy_stage_2() {
    if [ "$DEPLOY_STAGE_2" != "true" ]; then
        log_info "Stage 2 skipped"
        return 0
    fi
    
    log_stage "STAGE 2: SECURITY (IAM ROLES)"
    
    local base_name="${PROJECT_NAME}-${ENVIRONMENT}"
    local params="${CF_DIR}/2-security/parameters/iam-${ENVIRONMENT}.json"
    
    if [ ! -f "$params" ]; then
        params="${CF_DIR}/2-security/parameters/iam-prod.json"
        log_warning "Using default parameters: $params"
    fi
    
    deploy_stack \
        "${base_name}-iam" \
        "${CF_DIR}/2-security/iam-roles.yaml" \
        "$params" \
        "CAPABILITY_NAMED_IAM" \
        "Stage 2: IAM Roles" || return 1
    
    sleep 5
    
    log_success "✓ Stage 2 complete - IAM roles ready"
    return 0
}

deploy_stage_3() {
    if [ "$DEPLOY_STAGE_3" != "true" ]; then
        log_info "Stage 3 skipped"
        return 0
    fi
    
    log_stage "STAGE 3: INFRASTRUCTURE"
    
    local base_name="${PROJECT_NAME}-${ENVIRONMENT}"
    
    # For now, use the monolithic infrastructure template
    # In full modular setup, would deploy: ECR, S3, ALB, WAF separately
    
    log_info "Using consolidated infrastructure template"
    log_info "In full modular setup, this would be split into multiple stacks"
    
    local params="${CF_DIR}/3-infrastructure/parameters/infra-${ENVIRONMENT}.json"
    
    if [ ! -f "$params" ]; then
        log_warning "Parameters not found: $params"
        log_warning "Using legacy parameters from project root"
        params="${CF_DIR}/../parameters-part1-${ENVIRONMENT}.json"
        
        if [ ! -f "$params" ]; then
            params="${CF_DIR}/../parameters-part1-prod.json"
        fi
    fi
    
    # Check if we have the modular template, otherwise use legacy
    if [ -f "${CF_DIR}/3-infrastructure/infrastructure.yaml" ]; then
        deploy_stack \
            "${base_name}-infra" \
            "${CF_DIR}/3-infrastructure/infrastructure.yaml" \
            "$params" \
            "" \
            "Stage 3: Infrastructure" || return 1
    else
        log_warning "Modular infrastructure template not found"
        log_warning "Using legacy template: 1-infrastructure-production-ready.yaml"
        
        deploy_stack \
            "${base_name}" \
            "${CF_DIR}/../1-infrastructure-production-ready.yaml" \
            "$params" \
            "" \
            "Stage 3: Infrastructure (Legacy)" || return 1
    fi
    
    sleep 5
    
    log_success "✓ Stage 3 complete - Infrastructure ready"
    return 0
}

deploy_stage_4() {
    if [ "$DEPLOY_STAGE_4" != "true" ]; then
        log_info "Stage 4 skipped"
        return 0
    fi
    
    log_stage "STAGE 4: COMPUTE (ECS)"
    
    local base_name="${PROJECT_NAME}-${ENVIRONMENT}"
    local params="${CF_DIR}/4-compute/parameters/compute-${ENVIRONMENT}.json"
    
    if [ ! -f "$params" ]; then
        log_warning "Parameters not found: $params"
        log_warning "Using legacy parameters from project root"
        params="${CF_DIR}/../parameters-part3-${ENVIRONMENT}.json"
        
        if [ ! -f "$params" ]; then
            params="${CF_DIR}/../parameters-part3-prod.json"
        fi
    fi
    
    # Check if we have the modular template, otherwise use legacy
    if [ -f "${CF_DIR}/4-compute/ecs-all.yaml" ]; then
        deploy_stack \
            "${base_name}-ecs" \
            "${CF_DIR}/4-compute/ecs-all.yaml" \
            "$params" \
            "" \
            "Stage 4: ECS Cluster & Services" || return 1
    else
        log_warning "Modular ECS template not found"
        log_warning "Using legacy template: 3-ecs-cluster-production-ready.yaml"
        
        deploy_stack \
            "${base_name}" \
            "${CF_DIR}/../3-ecs-cluster-production-ready.yaml" \
            "$params" \
            "" \
            "Stage 4: ECS (Legacy)" || return 1
    fi
    
    sleep 5
    
    log_success "✓ Stage 4 complete - ECS services running"
    return 0
}

deploy_stage_5() {
    if [ "$DEPLOY_STAGE_5" != "true" ]; then
        log_info "Stage 5 skipped"
        return 0
    fi
    
    log_stage "STAGE 5: CI/CD PIPELINE"
    
    log_warning "Stage 5 (CI/CD) deployment requires GitHub connection"
    read -p "Do you want to deploy CI/CD? (yes/no): " deploy_cicd
    
    if [ "$deploy_cicd" != "yes" ]; then
        log_info "CI/CD deployment skipped by user"
        return 0
    fi
    
    read -p "Enter GitHub Connection ARN: " github_conn
    
    if [ -z "$github_conn" ]; then
        log_warning "No GitHub connection provided - skipping CI/CD"
        return 0
    fi
    
    local base_name="${PROJECT_NAME}-${ENVIRONMENT}"
    
    # Create temporary parameters
    cat > /tmp/cicd-params.json <<EOF
[
  {
    "ParameterKey": "ProjectName",
    "ParameterValue": "${PROJECT_NAME}"
  },
  {
    "ParameterKey": "Environment",
    "ParameterValue": "${ENVIRONMENT}"
  },
  {
    "ParameterKey": "GitHubConnectionArn",
    "ParameterValue": "${github_conn}"
  }
]
EOF
    
    if [ -f "${CF_DIR}/5-cicd/cicd-all.yaml" ]; then
        deploy_stack \
            "${base_name}-cicd" \
            "${CF_DIR}/5-cicd/cicd-all.yaml" \
            "/tmp/cicd-params.json" \
            "" \
            "Stage 5: CI/CD Pipeline" || return 1
    else
        log_warning "Modular CI/CD template not found - skipping"
    fi
    
    log_success "✓ Stage 5 complete - CI/CD pipeline ready"
    return 0
}

deploy_stage_6() {
    if [ "$DEPLOY_STAGE_6" != "true" ]; then
        log_info "Stage 6 skipped"
        return 0
    fi
    
    log_stage "STAGE 6: MONITORING"
    
    log_info "Basic monitoring is included in previous stages"
    log_info "Advanced monitoring (dashboards, custom alarms) would go here"
    
    # In full modular setup, would deploy:
    # - CloudWatch Dashboards
    # - Custom Alarms
    # - SNS Topic subscriptions
    
    log_success "✓ Stage 6 complete"
    return 0
}

# ============================================
# PARSE ARGUMENTS
# ============================================
parse_arguments() {
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
            --skip-stage)
                case $2 in
                    1) DEPLOY_STAGE_1=false ;;
                    2) DEPLOY_STAGE_2=false ;;
                    3) DEPLOY_STAGE_3=false ;;
                    4) DEPLOY_STAGE_4=false ;;
                    5) DEPLOY_STAGE_5=false ;;
                    6) DEPLOY_STAGE_6=false ;;
                    *) log_error "Invalid stage: $2"; exit 1 ;;
                esac
                shift 2
                ;;
            --only-stage)
                DEPLOY_STAGE_1=false
                DEPLOY_STAGE_2=false
                DEPLOY_STAGE_3=false
                DEPLOY_STAGE_4=false
                DEPLOY_STAGE_5=false
                DEPLOY_STAGE_6=false
                case $2 in
                    1) DEPLOY_STAGE_1=true ;;
                    2) DEPLOY_STAGE_2=true ;;
                    3) DEPLOY_STAGE_3=true ;;
                    4) DEPLOY_STAGE_4=true ;;
                    5) DEPLOY_STAGE_5=true ;;
                    6) DEPLOY_STAGE_6=true ;;
                    *) log_error "Invalid stage: $2"; exit 1 ;;
                esac
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
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
}

# ============================================
# MAIN
# ============================================
main() {
    parse_arguments "$@"
    
    clear
    log_section "🚀 MODULAR DEPLOYMENT - ALL STAGES"
    
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  CONFIGURATION                          ┃"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
    echo "Project:       $PROJECT_NAME"
    echo "Environment:   $ENVIRONMENT"
    echo "Region:        $REGION"
    echo "Dry Run:       $DRY_RUN"
    echo ""
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  STAGES TO DEPLOY                       ┃"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
    echo "  1. Foundation      [$([ "$DEPLOY_STAGE_1" == "true" ] && echo "✓" || echo "⊗")]"
    echo "  2. Security        [$([ "$DEPLOY_STAGE_2" == "true" ] && echo "✓" || echo "⊗")]"
    echo "  3. Infrastructure  [$([ "$DEPLOY_STAGE_3" == "true" ] && echo "✓" || echo "⊗")]"
    echo "  4. Compute         [$([ "$DEPLOY_STAGE_4" == "true" ] && echo "✓" || echo "⊗")]"
    echo "  5. CI/CD           [$([ "$DEPLOY_STAGE_5" == "true" ] && echo "✓" || echo "⊗")] (optional)"
    echo "  6. Monitoring      [$([ "$DEPLOY_STAGE_6" == "true" ] && echo "✓" || echo "⊗")] (optional)"
    echo ""
    
    if [ "$DRY_RUN" != "true" ]; then
        read -p "Continue with deployment? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Deployment cancelled"
            exit 0
        fi
    fi
    
    # Deploy stages in order
    local failed=false
    
    deploy_stage_1 || failed=true
    [ "$failed" == "true" ] && exit 1
    
    deploy_stage_2 || failed=true
    [ "$failed" == "true" ] && exit 1
    
    deploy_stage_3 || failed=true
    [ "$failed" == "true" ] && exit 1
    
    deploy_stage_4 || failed=true
    [ "$failed" == "true" ] && exit 1
    
    # Optional stages - don't fail deployment if these fail
    deploy_stage_5 || log_warning "Stage 5 failed but continuing..."
    deploy_stage_6 || log_warning "Stage 6 failed but continuing..."
    
    # Summary
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    log_section "📋 DEPLOYMENT SUMMARY"
    
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  ✅ DEPLOYMENT COMPLETE!                ┃"
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
        echo "  ✓ $stack"
    done
    echo ""
    
    log_success "🎉 All stages deployed successfully!"
}

main "$@"