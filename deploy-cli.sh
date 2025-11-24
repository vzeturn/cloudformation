#!/bin/bash

################################################################################
# AEV DEPLOYMENT - ALL PHASES (AWS CLI Direct)
# Fast deployment using aws cloudformation deploy
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
PROJECT="aev"
ENV="dev"  # Change to "prod" for production
REGION="ap-southeast-1"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_section() { echo -e "\n${CYAN}═══════════════════════════════════════════\n$1\n══════════════════════════════════════════=${NC}\n"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --env) ENV="$2"; shift 2 ;;
        --phase) PHASE="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

clear
echo "╔════════════════════════════════════════════════════╗"
echo "║  AEV INTEGRATION SERVICES - AWS CLI DEPLOYMENT    ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""
echo "Environment:  $ENV"
echo "Region:       $REGION"
echo "Phase:        ${PHASE:-all}"
echo ""

# ============================================
# PHASE 1: FOUNDATION
# ============================================
deploy_phase_1() {
    log_section "PHASE 1: FOUNDATION (KMS, S3, CloudWatch Logs)"
    
    local stack_name="${PROJECT}-${ENV}-foundation"
    
    aws cloudformation deploy \
      --template-file Templates/1-foundation.yaml \
      --stack-name $stack_name \
      --parameter-overrides file://Parameter/1-${ENV}-foundation.json \
      --region $REGION \
      --tags \
        Key=Project,Value=AEV \
        Key=Environment,Value=$ENV \
        Key=Phase,Value=1-Foundation \
        Key=ManagedBy,Value=CloudFormation \
      --no-fail-on-empty-changeset
    
    if [ $? -eq 0 ]; then
        log_success "✓ Phase 1 deployed successfully"
        
        # Show outputs
        log_info "Stack Outputs:"
        aws cloudformation describe-stacks \
          --stack-name $stack_name \
          --region $REGION \
          --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
          --output table
        
        return 0
    else
        log_error "✗ Phase 1 deployment failed"
        return 1
    fi
}

# ============================================
# PHASE 2: NETWORK & SECURITY
# ============================================
deploy_phase_2() {
    log_section "PHASE 2: NETWORK & SECURITY (VPC, ALB, IAM)"
    
    local stack_name="${PROJECT}-${ENV}-network"
    
    # Check if Phase 1 completed
    local kms_key=$(aws cloudformation list-exports \
      --region $REGION \
      --query "Exports[?Name=='${PROJECT}-${ENV}-KMSKeyArn'].Value" \
      --output text 2>/dev/null)
    
    if [ -z "$kms_key" ]; then
        log_error "Phase 1 not completed. Deploy Phase 1 first."
        return 1
    fi
    
    log_info "Phase 1 exports found ✓"
    
    aws cloudformation deploy \
      --template-file Templates/2-network-security.yaml \
      --stack-name $stack_name \
      --parameter-overrides file://Parameter/2-${ENV}-network.json \
      --capabilities CAPABILITY_NAMED_IAM \
      --region $REGION \
      --no-fail-on-empty-changeset
    
    if [ $? -eq 0 ]; then
        log_success "✓ Phase 2 deployed successfully"
        
        # Show ALB DNS
        local alb_dns=$(aws cloudformation describe-stacks \
          --stack-name $stack_name \
          --region $REGION \
          --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerDNS`].OutputValue' \
          --output text)
        
        if [ -n "$alb_dns" ]; then
            log_info "ALB DNS: http://$alb_dns"
        fi
        
        return 0
    else
        log_error "✗ Phase 2 deployment failed"
        return 1
    fi
}

# ============================================
# PHASE 3: SERVICE (Integration Services API)
# ============================================
deploy_phase_3() {
    log_section "PHASE 3: SERVICE (ECS, Task Definitions, Service)"
    
    local stack_name="${PROJECT}-${ENV}-integration-services-api"
    local service_purpose="integration"
    local app_name="services-api"
    
    # Check Phase 2 completed
    local alb_arn=$(aws cloudformation list-exports \
      --region $REGION \
      --query "Exports[?Name=='${PROJECT}-${ENV}-LoadBalancerArn'].Value" \
      --output text 2>/dev/null)
    
    if [ -z "$alb_arn" ]; then
        log_error "Phase 2 not completed. Deploy Phase 2 first."
        return 1
    fi
    
    log_info "Phase 2 exports found ✓"
    
    # Check parameter file exists
    local param_file="Parameter/${ENV}-${service_purpose}-${app_name}.json"
    if [ ! -f "$param_file" ]; then
        log_error "Parameter file not found: $param_file"
        return 1
    fi
    
    aws cloudformation deploy \
      --template-file Templates/3-service-template.yaml \
      --stack-name $stack_name \
      --parameter-overrides file://$param_file \
      --region $REGION \
      --no-fail-on-empty-changeset
    
    if [ $? -eq 0 ]; then
        log_success "✓ Phase 3 deployed successfully"
        
        # Show service URL
        local alb_dns=$(aws cloudformation list-exports \
          --region $REGION \
          --query "Exports[?Name=='${PROJECT}-${ENV}-LoadBalancerDNS'].Value" \
          --output text)
        
        if [ -n "$alb_dns" ]; then
            log_info "Service URL: http://$alb_dns/api/health"
        fi
        
        return 0
    else
        log_error "✗ Phase 3 deployment failed"
        return 1
    fi
}

# ============================================
# PHASE 4: CI/CD PIPELINE
# ============================================
deploy_phase_4() {
    log_section "PHASE 4: CI/CD PIPELINE (CodeBuild, CodePipeline)"
    
    local stack_name="${PROJECT}-${ENV}-pipeline-integration-services-api"
    local service_purpose="integration"
    local app_name="services-api"
    
    # Check Phase 3 completed
    local service_arn=$(aws cloudformation list-exports \
      --region $REGION \
      --query "Exports[?Name=='${PROJECT}-${ENV}-${service_purpose}-${app_name}-ServiceArn'].Value" \
      --output text 2>/dev/null)
    
    if [ -z "$service_arn" ]; then
        log_error "Phase 3 not completed. Deploy Phase 3 first."
        return 1
    fi
    
    log_info "Phase 3 exports found ✓"
    
    # Check parameter file
    local param_file="Parameter/${ENV}-pipeline-${service_purpose}-${app_name}.json"
    if [ ! -f "$param_file" ]; then
        log_error "Parameter file not found: $param_file"
        log_info "Required: GitHub Connection ARN"
        return 1
    fi
    
    # Verify GitHub connection
    local github_conn=$(grep -oP '"ParameterValue":\s*"\K[^"]+' "$param_file" | grep "codeconnections")
    if [ -z "$github_conn" ]; then
        log_error "GitHub Connection ARN not found in parameter file"
        log_info "Please add GitHubConnectionArn parameter"
        return 1
    fi
    
    log_info "GitHub Connection: ${github_conn:0:50}..."
    
    aws cloudformation deploy \
      --template-file Templates/4-pipeline-template.yaml \
      --stack-name $stack_name \
      --parameter-overrides file://$param_file \
      --capabilities CAPABILITY_IAM \
      --region $REGION \
      --no-fail-on-empty-changeset
    
    if [ $? -eq 0 ]; then
        log_success "✓ Phase 4 deployed successfully"
        
        # Show pipeline info
        log_info "Pipeline created. Check AWS Console for status."
        log_info "Console: https://console.aws.amazon.com/codesuite/codepipeline/pipelines"
        
        return 0
    else
        log_error "✗ Phase 4 deployment failed"
        return 1
    fi
}

# ============================================
# MAIN EXECUTION
# ============================================
main() {
    local failed=false
    
    if [ -z "$PHASE" ] || [ "$PHASE" = "all" ]; then
        # Deploy all phases
        deploy_phase_1 || failed=true
        [ "$failed" == "true" ] && exit 1
        
        sleep 5
        deploy_phase_2 || failed=true
        [ "$failed" == "true" ] && exit 1
        
        sleep 5
        deploy_phase_3 || failed=true
        [ "$failed" == "true" ] && exit 1
        
        sleep 5
        deploy_phase_4 || log_error "Phase 4 failed (optional)"
        
    else
        # Deploy specific phase
        case $PHASE in
            1) deploy_phase_1 || failed=true ;;
            2) deploy_phase_2 || failed=true ;;
            3) deploy_phase_3 || failed=true ;;
            4) deploy_phase_4 || failed=true ;;
            *) log_error "Invalid phase: $PHASE"; exit 1 ;;
        esac
    fi
    
    if [ "$failed" == "true" ]; then
        log_error "╔════════════════════════════════════════════════════╗"
        log_error "║  ❌ DEPLOYMENT FAILED                             ║"
        log_error "╚════════════════════════════════════════════════════╝"
        exit 1
    fi
    
    log_success "╔════════════════════════════════════════════════════╗"
    log_success "║  🎉 DEPLOYMENT COMPLETE!                          ║"
    log_success "╚════════════════════════════════════════════════════╝"
    echo ""
    
    # Show summary
    log_info "Summary:"
    echo "  Environment: $ENV"
    echo "  Region:      $REGION"
    echo ""
    
    # Show service URL
    local alb_dns=$(aws cloudformation list-exports \
      --region $REGION \
      --query "Exports[?Name=='${PROJECT}-${ENV}-LoadBalancerDNS'].Value" \
      --output text 2>/dev/null)
    
    if [ -n "$alb_dns" ]; then
        log_info "🌐 Service URLs:"
        echo "  Health Check: http://$alb_dns/api/health"
        echo "  Swagger UI:   http://$alb_dns/swagger"
        echo ""
    fi
    
    log_info "Next Steps:"
    echo "  1. Test health check: curl http://$alb_dns/api/health"
    echo "  2. Check ECS services in AWS Console"
    echo "  3. Monitor CodePipeline for automatic deployments"
}

main