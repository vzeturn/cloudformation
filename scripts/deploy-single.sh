#!/bin/bash

################################################################################
# SINGLE STACK DEPLOYMENT SCRIPT
# 
# Deploy or update a single CloudFormation stack
#
# Usage:
#   ./deploy-single.sh --stack STACK_NAME --template PATH [options]
#
# Options:
#   --stack NAME           Stack name (required)
#   --template PATH        Template file path (required)
#   --parameters PATH      Parameters file path (optional)
#   --capabilities CAPS    IAM capabilities (optional)
#   --project NAME         Project name (default: aqua-sample-app)
#   --environment ENV      Environment (default: production)
#   --region REGION        AWS region (default: ap-southeast-1)
#   --wait                 Wait for completion (default: true)
#   --no-wait             Don't wait for completion
#   --dry-run             Validate only, don't deploy
#   --help                Show this help
#
# Examples:
#   # Deploy IAM roles stack
#   ./deploy-single.sh \
#     --stack myproject-production-iam \
#     --template 2-security/iam-roles.yaml \
#     --parameters 2-security/parameters/iam-prod.json \
#     --capabilities CAPABILITY_NAMED_IAM
#
#   # Deploy ECS cluster (using exports from previous stacks)
#   ./deploy-single.sh \
#     --stack myproject-production-ecs \
#     --template 4-compute/ecs-cluster.yaml
#
# Version: 1.0
################################################################################

set -e
set -o pipefail

# ============================================
# DEFAULT CONFIGURATION
# ============================================
STACK_NAME=""
TEMPLATE_FILE=""
PARAMETERS_FILE=""
CAPABILITIES=""
PROJECT_NAME="${PROJECT_NAME:-aqua-sample-app}"
ENVIRONMENT="${ENVIRONMENT:-production}"
REGION="${AWS_REGION:-ap-southeast-1}"
WAIT_FOR_COMPLETION=true
DRY_RUN=false

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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

# ============================================
# HELP FUNCTION
# ============================================
show_help() {
    head -n 50 "$0" | tail -n +3
    exit 0
}

# ============================================
# VALIDATION FUNCTIONS
# ============================================
validate_inputs() {
    local errors=0
    
    if [ -z "$STACK_NAME" ]; then
        log_error "Stack name is required (--stack)"
        ((errors++))
    fi
    
    if [ -z "$TEMPLATE_FILE" ]; then
        log_error "Template file is required (--template)"
        ((errors++))
    fi
    
    if [ ! -f "$TEMPLATE_FILE" ]; then
        log_error "Template file not found: $TEMPLATE_FILE"
        ((errors++))
    fi
    
    if [ -n "$PARAMETERS_FILE" ] && [ ! -f "$PARAMETERS_FILE" ]; then
        log_error "Parameters file not found: $PARAMETERS_FILE"
        ((errors++))
    fi
    
    if [ $errors -gt 0 ]; then
        echo ""
        log_error "Found $errors error(s). Use --help for usage information."
        exit 1
    fi
}

validate_template() {
    log_info "Validating CloudFormation template..."
    
    if aws cloudformation validate-template \
        --template-body file://"$TEMPLATE_FILE" \
        --region "$REGION" &> /dev/null; then
        log_success "Template is valid"
        return 0
    else
        log_error "Template validation failed"
        return 1
    fi
}

# ============================================
# STACK OPERATIONS
# ============================================
get_stack_status() {
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null || echo "NOT_EXISTS"
}

show_stack_info() {
    local status=$(get_stack_status)
    
    echo ""
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  STACK INFORMATION                      ┃"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
    echo "Stack Name:    $STACK_NAME"
    echo "Template:      $TEMPLATE_FILE"
    echo "Parameters:    ${PARAMETERS_FILE:-None}"
    echo "Capabilities:  ${CAPABILITIES:-None}"
    echo "Current Status: $status"
    echo "Region:        $REGION"
    echo "Dry Run:       $DRY_RUN"
    echo ""
}

deploy_stack() {
    local stack_status=$(get_stack_status)
    local operation=""
    
    if [ "$stack_status" == "NOT_EXISTS" ]; then
        operation="create"
        log_info "Stack does not exist - will CREATE"
    elif [[ "$stack_status" == *"COMPLETE"* ]]; then
        operation="update"
        log_info "Stack exists - will UPDATE"
    elif [[ "$stack_status" == *"IN_PROGRESS"* ]]; then
        log_error "Stack is currently being modified: $stack_status"
        log_error "Please wait for current operation to complete"
        return 1
    elif [[ "$stack_status" == *"FAILED"* ]] || [[ "$stack_status" == *"ROLLBACK"* ]]; then
        log_warning "Stack is in failed state: $stack_status"
        log_warning "You may need to delete the stack first"
        read -p "Attempt to update anyway? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Deployment cancelled"
            return 1
        fi
        operation="update"
    else
        log_error "Unknown stack status: $stack_status"
        return 1
    fi
    
    if [ "$DRY_RUN" == "true" ]; then
        log_info "[DRY RUN] Would perform ${operation} operation"
        return 0
    fi
    
    # Build AWS CLI command
    local cmd="aws cloudformation ${operation}-stack"
    cmd="$cmd --stack-name $STACK_NAME"
    cmd="$cmd --template-body file://$TEMPLATE_FILE"
    cmd="$cmd --region $REGION"
    
    if [ -n "$PARAMETERS_FILE" ]; then
        cmd="$cmd --parameters file://$PARAMETERS_FILE"
    fi
    
    if [ -n "$CAPABILITIES" ]; then
        cmd="$cmd --capabilities $CAPABILITIES"
    fi
    
    cmd="$cmd --tags"
    cmd="$cmd Key=Project,Value=$PROJECT_NAME"
    cmd="$cmd Key=Environment,Value=$ENVIRONMENT"
    cmd="$cmd Key=ManagedBy,Value=CloudFormation"
    cmd="$cmd Key=DeployedBy,Value=deploy-single-script"
    
    log_section "EXECUTING ${operation^^} OPERATION"
    
    # Execute command
    if eval "$cmd" 2>&1 | tee /tmp/cfn-output.txt; then
        if grep -q "No updates are to be performed" /tmp/cfn-output.txt; then
            log_info "No changes detected - stack is up to date"
            return 0
        fi
        
        if [ "$WAIT_FOR_COMPLETION" == "true" ]; then
            log_info "Waiting for ${operation} to complete..."
            echo ""
            
            if [ "$operation" == "create" ]; then
                if aws cloudformation wait stack-create-complete \
                    --stack-name "$STACK_NAME" \
                    --region "$REGION"; then
                    log_success "Stack created successfully!"
                else
                    log_error "Stack creation failed or timed out"
                    show_stack_events 10
                    return 1
                fi
            else
                if aws cloudformation wait stack-update-complete \
                    --stack-name "$STACK_NAME" \
                    --region "$REGION"; then
                    log_success "Stack updated successfully!"
                else
                    log_error "Stack update failed or timed out"
                    show_stack_events 10
                    return 1
                fi
            fi
            
            # Show outputs
            show_stack_outputs
            
        else
            log_info "Stack ${operation} initiated (not waiting for completion)"
        fi
        
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

show_stack_outputs() {
    log_section "STACK OUTPUTS"
    
    if aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue,Description]' \
        --output table 2>/dev/null; then
        echo ""
    else
        log_info "No outputs available"
    fi
}

show_stack_events() {
    local count=${1:-20}
    
    log_section "RECENT STACK EVENTS (Last $count)"
    
    aws cloudformation describe-stack-events \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --max-items $count \
        --query 'StackEvents[*].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId,ResourceStatusReason]' \
        --output table 2>/dev/null || log_warning "Could not retrieve stack events"
}

# ============================================
# PARSE ARGUMENTS
# ============================================
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --stack)
                STACK_NAME="$2"
                shift 2
                ;;
            --template)
                TEMPLATE_FILE="$2"
                shift 2
                ;;
            --parameters)
                PARAMETERS_FILE="$2"
                shift 2
                ;;
            --capabilities)
                CAPABILITIES="$2"
                shift 2
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
            --wait)
                WAIT_FOR_COMPLETION=true
                shift
                ;;
            --no-wait)
                WAIT_FOR_COMPLETION=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
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
    log_section "🚀 CLOUDFORMATION SINGLE STACK DEPLOYMENT"
    
    validate_inputs
    show_stack_info
    
    if ! validate_template; then
        exit 1
    fi
    
    if [ "$DRY_RUN" == "true" ]; then
        log_success "Dry run validation passed"
        exit 0
    fi
    
    # Confirm deployment
    if [[ "$WAIT_FOR_COMPLETION" == "true" ]]; then
        read -p "Proceed with deployment? (yes/no): " confirm
        if [ "$confirm" == "no" ]; then
            log_info "Deployment cancelled"
            exit 0
        fi
    fi
    
    # Deploy
    if deploy_stack; then
        log_section "✅ DEPLOYMENT COMPLETE"
        log_success "Stack: $STACK_NAME"
        log_success "Status: $(get_stack_status)"
        exit 0
    else
        log_section "❌ DEPLOYMENT FAILED"
        log_error "Stack: $STACK_NAME"
        log_error "Status: $(get_stack_status)"
        exit 1
    fi
}

main "$@"