#!/bin/bash

################################################################################
# ROLLBACK SCRIPT
# 
# Rollback CloudFormation stacks to previous stable state
#
# Usage:
#   ./rollback.sh [options]
#
# Options:
#   --stack NAME           Specific stack to rollback
#   --project NAME         Project name (default: aqua-sample-app)
#   --environment ENV      Environment (default: production)
#   --region REGION        AWS region (default: ap-southeast-1)
#   --stage N              Rollback specific stage (1-6)
#   --all                  Rollback all failed stacks
#   --force                Skip confirmation prompts
#   --help                 Show this help
#
# Examples:
#   # Rollback a specific stack
#   ./rollback.sh --stack myproject-production-ecs
#
#   # Rollback all failed stacks in stage 4
#   ./rollback.sh --stage 4 --environment production
#
#   # Rollback all failed stacks
#   ./rollback.sh --all --environment production
#
# Version: 1.0
################################################################################

set -e
set -o pipefail

# ============================================
# DEFAULT CONFIGURATION
# ============================================
SPECIFIC_STACK=""
PROJECT_NAME="${PROJECT_NAME:-aqua-sample-app}"
ENVIRONMENT="${ENVIRONMENT:-production}"
REGION="${AWS_REGION:-ap-southeast-1}"
STAGE=""
ROLLBACK_ALL=false
FORCE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
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

is_rollbackable() {
    local status=$1
    
    case $status in
        UPDATE_FAILED|UPDATE_ROLLBACK_FAILED|CREATE_FAILED|ROLLBACK_FAILED)
            return 0
            ;;
        UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS|UPDATE_ROLLBACK_IN_PROGRESS|ROLLBACK_IN_PROGRESS)
            return 1  # Already rolling back
            ;;
        *)
            return 1  # Not in a failed state
            ;;
    esac
}

get_all_stacks() {
    local base_name="${PROJECT_NAME}-${ENVIRONMENT}"
    
    # All possible stacks for the project
    local stacks=(
        # Stage 1: Foundation
        "${base_name}-kms"
        "${base_name}-logs"
        "${base_name}-vpc-endpoints"
        
        # Stage 2: Security
        "${base_name}-iam"
        "${base_name}-secrets"
        
        # Stage 3: Infrastructure
        "${base_name}-ecr"
        "${base_name}-s3"
        "${base_name}-sg"
        "${base_name}-alb"
        "${base_name}-waf"
        
        # Stage 4: Compute
        "${base_name}-ecs"
        "${base_name}-service-discovery"
        "${base_name}-tasks"
        "${base_name}-services"
        "${base_name}-autoscaling"
        
        # Stage 5: CI/CD
        "${base_name}-init-builders"
        "${base_name}-codebuild"
        "${base_name}-codepipeline"
        
        # Stage 6: Monitoring
        "${base_name}-sns"
        "${base_name}-alarms"
        "${base_name}-dashboards"
    )
    
    echo "${stacks[@]}"
}

get_stage_stacks() {
    local stage=$1
    local base_name="${PROJECT_NAME}-${ENVIRONMENT}"
    local stacks=()
    
    case $stage in
        1)
            stacks=(
                "${base_name}-kms"
                "${base_name}-logs"
                "${base_name}-vpc-endpoints"
            )
            ;;
        2)
            stacks=(
                "${base_name}-iam"
                "${base_name}-secrets"
            )
            ;;
        3)
            stacks=(
                "${base_name}-ecr"
                "${base_name}-s3"
                "${base_name}-sg"
                "${base_name}-alb"
                "${base_name}-waf"
            )
            ;;
        4)
            stacks=(
                "${base_name}-ecs"
                "${base_name}-service-discovery"
                "${base_name}-tasks"
                "${base_name}-services"
                "${base_name}-autoscaling"
            )
            ;;
        5)
            stacks=(
                "${base_name}-init-builders"
                "${base_name}-codebuild"
                "${base_name}-codepipeline"
            )
            ;;
        6)
            stacks=(
                "${base_name}-sns"
                "${base_name}-alarms"
                "${base_name}-dashboards"
            )
            ;;
        *)
            log_error "Invalid stage: $stage"
            exit 1
            ;;
    esac
    
    echo "${stacks[@]}"
}

find_failed_stacks() {
    local stacks_to_check=("$@")
    local failed_stacks=()
    
    for stack in "${stacks_to_check[@]}"; do
        local status=$(get_stack_status "$stack")
        
        if [ "$status" != "NOT_EXISTS" ] && is_rollbackable "$status"; then
            failed_stacks+=("$stack:$status")
        fi
    done
    
    echo "${failed_stacks[@]}"
}

# ============================================
# ROLLBACK FUNCTIONS
# ============================================
rollback_stack() {
    local stack_name=$1
    local status=$(get_stack_status "$stack_name")
    
    log_section "Rolling back: $stack_name"
    log_info "Current status: $status"
    
    case $status in
        UPDATE_FAILED|UPDATE_ROLLBACK_FAILED)
            log_info "Continuing rollback..."
            
            if aws cloudformation continue-update-rollback \
                --stack-name "$stack_name" \
                --region "$REGION" 2>&1 | tee /tmp/rollback-output.txt; then
                
                log_info "Rollback initiated, waiting for completion..."
                
                if aws cloudformation wait stack-update-rollback-complete \
                    --stack-name "$stack_name" \
                    --region "$REGION" 2>/dev/null; then
                    log_success "✓ Rollback completed successfully"
                    return 0
                else
                    log_error "✗ Rollback failed or timed out"
                    show_stack_events "$stack_name" 10
                    return 1
                fi
            else
                if grep -q "No updates are to be performed" /tmp/rollback-output.txt; then
                    log_info "Stack already in stable state"
                    return 0
                fi
                log_error "Failed to initiate rollback"
                return 1
            fi
            ;;
            
        CREATE_FAILED|ROLLBACK_FAILED)
            log_warning "Stack in FAILED state: $status"
            log_warning "Recommend deleting and recreating the stack"
            
            if [ "$FORCE" == "true" ]; then
                log_info "Force mode: Deleting failed stack..."
                delete_stack "$stack_name"
                return $?
            else
                read -p "Delete this stack? (yes/no): " confirm
                if [ "$confirm" == "yes" ]; then
                    delete_stack "$stack_name"
                    return $?
                else
                    log_info "Skipping deletion"
                    return 1
                fi
            fi
            ;;
            
        UPDATE_ROLLBACK_IN_PROGRESS|ROLLBACK_IN_PROGRESS)
            log_info "Rollback already in progress, waiting..."
            
            if aws cloudformation wait stack-update-rollback-complete \
                --stack-name "$stack_name" \
                --region "$REGION" 2>/dev/null; then
                log_success "✓ Rollback completed"
                return 0
            else
                log_error "✗ Rollback failed"
                return 1
            fi
            ;;
            
        *)
            log_warning "Stack not in rollbackable state: $status"
            return 1
            ;;
    esac
}

delete_stack() {
    local stack_name=$1
    
    log_info "Deleting stack: $stack_name"
    
    if aws cloudformation delete-stack \
        --stack-name "$stack_name" \
        --region "$REGION"; then
        
        log_info "Waiting for deletion to complete..."
        
        if aws cloudformation wait stack-delete-complete \
            --stack-name "$stack_name" \
            --region "$REGION" 2>/dev/null; then
            log_success "✓ Stack deleted successfully"
            return 0
        else
            log_error "✗ Stack deletion failed or timed out"
            return 1
        fi
    else
        log_error "Failed to initiate stack deletion"
        return 1
    fi
}

show_stack_events() {
    local stack_name=$1
    local count=${2:-20}
    
    echo ""
    log_info "Recent events for $stack_name:"
    echo ""
    
    aws cloudformation describe-stack-events \
        --stack-name "$stack_name" \
        --region "$REGION" \
        --max-items $count \
        --query 'StackEvents[*].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId,ResourceStatusReason]' \
        --output table 2>/dev/null || log_warning "Could not retrieve events"
}

# ============================================
# PARSE ARGUMENTS
# ============================================
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --stack)
                SPECIFIC_STACK="$2"
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
            --stage)
                STAGE="$2"
                shift 2
                ;;
            --all)
                ROLLBACK_ALL=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --help)
                head -n 30 "$0" | tail -n +3
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
    log_section "🔄 CLOUDFORMATION ROLLBACK UTILITY"
    
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  CONFIGURATION                          ┃"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
    echo "Project:       $PROJECT_NAME"
    echo "Environment:   $ENVIRONMENT"
    echo "Region:        $REGION"
    echo "Force Mode:    $FORCE"
    echo ""
    
    local stacks_to_check=()
    local failed_stacks=()
    
    # Determine which stacks to check
    if [ -n "$SPECIFIC_STACK" ]; then
        log_info "Checking specific stack: $SPECIFIC_STACK"
        stacks_to_check=("$SPECIFIC_STACK")
    elif [ -n "$STAGE" ]; then
        log_info "Checking stacks in Stage $STAGE"
        stacks_to_check=($(get_stage_stacks "$STAGE"))
    elif [ "$ROLLBACK_ALL" == "true" ]; then
        log_info "Checking all stacks"
        stacks_to_check=($(get_all_stacks))
    else
        log_error "Must specify --stack, --stage, or --all"
        echo "Use --help for usage information"
        exit 1
    fi
    
    # Find failed stacks
    log_info "Scanning for failed stacks..."
    failed_stacks=($(find_failed_stacks "${stacks_to_check[@]}"))
    
    if [ ${#failed_stacks[@]} -eq 0 ]; then
        log_success "✓ No failed stacks found!"
        exit 0
    fi
    
    # Display failed stacks
    echo ""
    log_section "FOUND ${#failed_stacks[@]} FAILED STACK(S)"
    
    for item in "${failed_stacks[@]}"; do
        IFS=':' read -r stack status <<< "$item"
        echo "  ✗ $stack"
        echo "    Status: $status"
    done
    echo ""
    
    # Confirm rollback
    if [ "$FORCE" != "true" ]; then
        log_warning "This will attempt to rollback the above stack(s)"
        read -p "Continue? (yes/no): " confirm
        
        if [ "$confirm" != "yes" ]; then
            log_info "Rollback cancelled"
            exit 0
        fi
    fi
    
    # Perform rollbacks
    echo ""
    log_section "STARTING ROLLBACK PROCESS"
    
    local success_count=0
    local fail_count=0
    
    for item in "${failed_stacks[@]}"; do
        IFS=':' read -r stack status <<< "$item"
        
        if rollback_stack "$stack"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
        
        echo ""
    done
    
    # Summary
    log_section "📊 ROLLBACK SUMMARY"
    
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  RESULTS                                ┃"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
    echo "Total stacks:     ${#failed_stacks[@]}"
    echo "Successful:       $success_count"
    echo "Failed:           $fail_count"
    echo ""
    
    if [ $fail_count -eq 0 ]; then
        log_success "🎉 All rollbacks completed successfully!"
        exit 0
    else
        log_warning "⚠ $fail_count rollback(s) failed"
        log_info "Check stack events and AWS Console for details"
        exit 1
    fi
}

main "$@"