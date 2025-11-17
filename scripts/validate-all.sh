#!/bin/bash

################################################################################
# TEMPLATE VALIDATION SCRIPT
# 
# Validates all CloudFormation templates in the project
#
# Usage:
#   ./validate-all.sh [options]
#
# Options:
#   --stage N              Validate only templates in stage N (1-6)
#   --template PATH        Validate specific template
#   --verbose              Show detailed validation output
#   --region REGION        AWS region (default: ap-southeast-1)
#   --parallel             Validate templates in parallel
#   --help                 Show this help
#
# Examples:
#   # Validate all templates
#   ./validate-all.sh
#
#   # Validate only Stage 4 templates
#   ./validate-all.sh --stage 4
#
#   # Validate specific template
#   ./validate-all.sh --template 2-security/iam-roles.yaml
#
#   # Validate with detailed output
#   ./validate-all.sh --verbose
#
# Version: 1.0
################################################################################

set -e
set -o pipefail

# ============================================
# DEFAULT CONFIGURATION
# ============================================
SPECIFIC_TEMPLATE=""
SPECIFIC_STAGE=""
VERBOSE=false
REGION="${AWS_REGION:-ap-southeast-1}"
PARALLEL=false

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

# Counters
TOTAL_TEMPLATES=0
VALID_TEMPLATES=0
INVALID_TEMPLATES=0
SKIPPED_TEMPLATES=0

# ============================================
# LOGGING FUNCTIONS
# ============================================
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓ VALID]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[⚠ WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗ INVALID]${NC} $1"
}

log_skip() {
    echo -e "${YELLOW}[⊗ SKIP]${NC} $1"
}

log_section() {
    echo ""
    echo -e "${CYAN}=========================================="
    echo -e "$1"
    echo -e "==========================================${NC}"
    echo ""
}

# ============================================
# TEMPLATE DISCOVERY
# ============================================
get_all_templates() {
    local templates=()
    
    # Stage 1: Foundation
    templates+=(
        "1-foundation/kms-keys.yaml"
        "1-foundation/cloudwatch-log-groups.yaml"
        "1-foundation/vpc-endpoints.yaml"
    )
    
    # Stage 2: Security
    templates+=(
        "2-security/iam-roles.yaml"
        "2-security/secrets-manager.yaml"
    )
    
    # Stage 3: Infrastructure
    templates+=(
        "3-infrastructure/ecr-repositories.yaml"
        "3-infrastructure/s3-buckets.yaml"
        "3-infrastructure/security-groups.yaml"
        "3-infrastructure/alb.yaml"
        "3-infrastructure/waf.yaml"
    )
    
    # Stage 4: Compute
    templates+=(
        "4-compute/ecs-cluster.yaml"
        "4-compute/service-discovery.yaml"
        "4-compute/task-definitions.yaml"
        "4-compute/ecs-services.yaml"
        "4-compute/autoscaling.yaml"
    )
    
    # Stage 5: CI/CD
    templates+=(
        "5-cicd/codebuild-projects.yaml"
        "5-cicd/codepipeline.yaml"
        "5-cicd/initial-image-builders.yaml"
    )
    
    # Stage 6: Monitoring
    templates+=(
        "6-monitoring/sns-topics.yaml"
        "6-monitoring/cloudwatch-alarms.yaml"
        "6-monitoring/cloudwatch-dashboards.yaml"
    )
    
    echo "${templates[@]}"
}

get_stage_templates() {
    local stage=$1
    local templates=()
    
    case $stage in
        1)
            templates=(
                "1-foundation/kms-keys.yaml"
                "1-foundation/cloudwatch-log-groups.yaml"
                "1-foundation/vpc-endpoints.yaml"
            )
            ;;
        2)
            templates=(
                "2-security/iam-roles.yaml"
                "2-security/secrets-manager.yaml"
            )
            ;;
        3)
            templates=(
                "3-infrastructure/ecr-repositories.yaml"
                "3-infrastructure/s3-buckets.yaml"
                "3-infrastructure/security-groups.yaml"
                "3-infrastructure/alb.yaml"
                "3-infrastructure/waf.yaml"
            )
            ;;
        4)
            templates=(
                "4-compute/ecs-cluster.yaml"
                "4-compute/service-discovery.yaml"
                "4-compute/task-definitions.yaml"
                "4-compute/ecs-services.yaml"
                "4-compute/autoscaling.yaml"
            )
            ;;
        5)
            templates=(
                "5-cicd/codebuild-projects.yaml"
                "5-cicd/codepipeline.yaml"
                "5-cicd/initial-image-builders.yaml"
            )
            ;;
        6)
            templates=(
                "6-monitoring/sns-topics.yaml"
                "6-monitoring/cloudwatch-alarms.yaml"
                "6-monitoring/cloudwatch-dashboards.yaml"
            )
            ;;
        *)
            log_error "Invalid stage: $stage (must be 1-6)"
            exit 1
            ;;
    esac
    
    echo "${templates[@]}"
}

# ============================================
# VALIDATION FUNCTIONS
# ============================================
validate_template() {
    local template_path=$1
    local full_path="${CF_DIR}/${template_path}"
    
    ((TOTAL_TEMPLATES++))
    
    # Check if file exists
    if [ ! -f "$full_path" ]; then
        log_error "File not found: $template_path"
        ((SKIPPED_TEMPLATES++))
        return 1
    fi
    
    # Validate with AWS CLI
    if [ "$VERBOSE" == "true" ]; then
        log_info "Validating: $template_path"
    else
        printf "%-60s" "  $template_path"
    fi
    
    local validation_output
    validation_output=$(aws cloudformation validate-template \
        --template-body file://"$full_path" \
        --region "$REGION" 2>&1)
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        if [ "$VERBOSE" == "true" ]; then
            log_success "$template_path"
            echo "$validation_output" | jq '.' 2>/dev/null || echo "$validation_output"
            echo ""
        else
            echo -e "${GREEN}✓${NC}"
        fi
        ((VALID_TEMPLATES++))
        return 0
    else
        if [ "$VERBOSE" == "true" ]; then
            log_error "$template_path"
            echo "$validation_output"
            echo ""
        else
            echo -e "${RED}✗${NC}"
            echo "    Error: $validation_output"
        fi
        ((INVALID_TEMPLATES++))
        return 1
    fi
}

validate_template_parallel() {
    validate_template "$1" &
}

# ============================================
# PARSE ARGUMENTS
# ============================================
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --stage)
                SPECIFIC_STAGE="$2"
                shift 2
                ;;
            --template)
                SPECIFIC_TEMPLATE="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --region)
                REGION="$2"
                shift 2
                ;;
            --parallel)
                PARALLEL=true
                shift
                ;;
            --help)
                head -n 35 "$0" | tail -n +3
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
# REPORTING FUNCTIONS
# ============================================
show_summary() {
    log_section "📊 VALIDATION SUMMARY"
    
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  RESULTS                                ┃"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
    echo "Total Templates:   $TOTAL_TEMPLATES"
    echo "Valid:             $VALID_TEMPLATES"
    echo "Invalid:           $INVALID_TEMPLATES"
    echo "Skipped:           $SKIPPED_TEMPLATES"
    echo ""
    
    if [ $INVALID_TEMPLATES -eq 0 ] && [ $SKIPPED_TEMPLATES -eq 0 ]; then
        log_success "🎉 All templates are valid!"
        return 0
    elif [ $INVALID_TEMPLATES -gt 0 ]; then
        log_error "❌ $INVALID_TEMPLATES template(s) failed validation"
        return 1
    else
        log_warning "⚠ $SKIPPED_TEMPLATES template(s) were skipped"
        return 1
    fi
}

show_stage_info() {
    local stage=$1
    local stage_names=(
        "Foundation (KMS, Logs, VPC Endpoints)"
        "Security (IAM Roles, Secrets)"
        "Infrastructure (ECR, S3, ALB, WAF)"
        "Compute (ECS Cluster, Services, Auto Scaling)"
        "CI/CD (CodeBuild, CodePipeline)"
        "Monitoring (SNS, CloudWatch Alarms, Dashboards)"
    )
    
    local index=$((stage - 1))
    echo "Stage $stage: ${stage_names[$index]}"
}

# ============================================
# MAIN
# ============================================
main() {
    parse_arguments "$@"
    
    clear
    log_section "✅ CLOUDFORMATION TEMPLATE VALIDATOR"
    
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃  CONFIGURATION                          ┃"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
    echo "Region:        $REGION"
    echo "Verbose:       $VERBOSE"
    echo "Parallel:      $PARALLEL"
    
    local templates_to_validate=()
    
    # Determine which templates to validate
    if [ -n "$SPECIFIC_TEMPLATE" ]; then
        echo "Mode:          Single Template"
        echo "Template:      $SPECIFIC_TEMPLATE"
        templates_to_validate=("$SPECIFIC_TEMPLATE")
    elif [ -n "$SPECIFIC_STAGE" ]; then
        echo "Mode:          Stage $SPECIFIC_STAGE"
        echo "Stage:         $(show_stage_info $SPECIFIC_STAGE)"
        templates_to_validate=($(get_stage_templates "$SPECIFIC_STAGE"))
    else
        echo "Mode:          All Templates"
        templates_to_validate=($(get_all_templates))
    fi
    
    echo ""
    log_info "Found ${#templates_to_validate[@]} template(s) to validate"
    echo ""
    
    # Validate templates
    log_section "🔍 VALIDATING TEMPLATES"
    
    if [ "$PARALLEL" == "true" ] && [ -z "$SPECIFIC_TEMPLATE" ]; then
        log_info "Running validation in parallel..."
        echo ""
        
        for template in "${templates_to_validate[@]}"; do
            validate_template_parallel "$template"
        done
        
        # Wait for all background jobs
        wait
        
    else
        for template in "${templates_to_validate[@]}"; do
            validate_template "$template"
        done
    fi
    
    # Show summary and exit
    echo ""
    if show_summary; then
        exit 0
    else
        exit 1
    fi
}

main "$@"