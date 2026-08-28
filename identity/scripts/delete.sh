#!/bin/bash
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CFN_DIR="$SCRIPTS_DIR/../cloudformation"

echo ""
echo "  WARNING: This will permanently delete all Identity domain resources:"
echo "    - Group memberships"
echo "    - Account assignments (all group → Permission Set → account links)"
echo "    - Groups"
echo "    - Permission Sets"
echo ""
read -r -p "  Are you sure you want to proceed? [y/N]: " CONFIRM
echo ""

if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "  Deletion cancelled."
  exit 0
fi

echo "=== STEP 1: RESOLVING IDENTITY CENTER INSTANCE ==="
source "$SCRIPTS_DIR/../common/resolve-instance.sh"

PROJECT_PREFIX_LOWER=$(echo "$PROJECT_PREFIX" | tr '[:upper:]' '[:lower:]')

echo ""
echo "=== STEP 2: REMOVING IDENTITY-ENHANCED SESSIONS CONFIGURATION ==="
ABAC_STATUS=$(aws sso-admin describe-instance-access-control-attribute-configuration \
  --instance-arn "$INSTANCE_ARN" \
  --region "$REGION" \
  --query 'InstanceAccessControlAttributeConfiguration.Status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$ABAC_STATUS" = "NOT_FOUND" ] || [ -z "$ABAC_STATUS" ]; then
  echo "Identity-enhanced sessions not configured, skipping."
else
  aws sso-admin delete-instance-access-control-attribute-configuration \
    --instance-arn "$INSTANCE_ARN" \
    --region "$REGION"
  echo "Identity-enhanced sessions configuration removed."
fi

echo ""
echo "=== STEP 3: REMOVING GROUP MEMBERSHIPS ==="

# Group memberships must be removed before the groups can be deleted.
# CloudFormation does not manage memberships — they must be deleted via CLI.

remove_group_memberships() {
  local GROUP_NAME="$1"
  local OUTPUT_KEY="$2"

  GROUP_ID=$(aws cloudformation describe-stacks \
    --stack-name "${PROJECT_PREFIX_LOWER}-identity-groups" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='${OUTPUT_KEY}GroupId'].OutputValue" \
    --output text 2>/dev/null || echo "")

  if [ -z "$GROUP_ID" ] || [ "$GROUP_ID" = "None" ]; then
    echo "  $GROUP_NAME — stack output not found, skipping."
    return
  fi

  MEMBERSHIP_IDS=$(aws identitystore list-group-memberships \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --group-id "$GROUP_ID" \
    --region "$REGION" \
    --query 'GroupMemberships[].MembershipId' \
    --output text)

  if [ -z "$MEMBERSHIP_IDS" ] || [ "$MEMBERSHIP_IDS" = "None" ]; then
    echo "  $GROUP_NAME — no memberships found, skipping."
    return
  fi

  # --output text returns IDs tab-separated on a single line on macOS.
  # Convert tabs to newlines before iterating.
  echo "$MEMBERSHIP_IDS" | tr '\t' '\n' | while IFS= read -r MEMBERSHIP_ID; do
    if [ -n "$MEMBERSHIP_ID" ]; then
      aws identitystore delete-group-membership \
        --identity-store-id "$IDENTITY_STORE_ID" \
        --membership-id "$MEMBERSHIP_ID" \
        --region "$REGION" \
        > /dev/null 2>&1
      echo "  $GROUP_NAME — membership $MEMBERSHIP_ID removed."
    fi
  done
}

remove_group_memberships "${PROJECT_PREFIX}-Infrastructure-Admins" "InfrastructureAdmins"
remove_group_memberships "${PROJECT_PREFIX}-Platform-Admins"       "PlatformAdmins"
remove_group_memberships "${PROJECT_PREFIX}-Developers"            "Developers"
remove_group_memberships "${PROJECT_PREFIX}-Operations"            "Operations"

echo "Group memberships removed."

echo ""
echo "=== STEP 4: DELETING ACCOUNT ASSIGNMENTS STACK ==="
ASSIGNMENTS_STACK=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_PREFIX_LOWER}-identity-assignments" \
  --region "$REGION" \
  --query 'Stacks[0].StackName' \
  --output text 2>/dev/null || echo "")

if [ -z "$ASSIGNMENTS_STACK" ] || [ "$ASSIGNMENTS_STACK" = "None" ]; then
  echo "  Stack not found, skipping."
else
  aws cloudformation delete-stack \
    --stack-name "${PROJECT_PREFIX_LOWER}-identity-assignments" \
    --region "$REGION"
  echo "  Waiting for stack deletion..."
  aws cloudformation wait stack-delete-complete \
    --stack-name "${PROJECT_PREFIX_LOWER}-identity-assignments" \
    --region "$REGION"
  echo "  Stack deleted."
fi

echo ""
echo "=== STEP 5: DELETING GROUPS STACK ==="
GROUPS_STACK=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_PREFIX_LOWER}-identity-groups" \
  --region "$REGION" \
  --query 'Stacks[0].StackName' \
  --output text 2>/dev/null || echo "")

if [ -z "$GROUPS_STACK" ] || [ "$GROUPS_STACK" = "None" ]; then
  echo "  Stack not found, skipping."
else
  aws cloudformation delete-stack \
    --stack-name "${PROJECT_PREFIX_LOWER}-identity-groups" \
    --region "$REGION"
  echo "  Waiting for stack deletion..."
  aws cloudformation wait stack-delete-complete \
    --stack-name "${PROJECT_PREFIX_LOWER}-identity-groups" \
    --region "$REGION"
  echo "  Stack deleted."
fi

echo ""
echo "=== STEP 6: DELETING PERMISSION SETS STACK ==="
PERMISSION_SETS_STACK=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_PREFIX_LOWER}-identity-permission-sets" \
  --region "$REGION" \
  --query 'Stacks[0].StackName' \
  --output text 2>/dev/null || echo "")

if [ -z "$PERMISSION_SETS_STACK" ] || [ "$PERMISSION_SETS_STACK" = "None" ]; then
  echo "  Stack not found, skipping."
else
  aws cloudformation delete-stack \
    --stack-name "${PROJECT_PREFIX_LOWER}-identity-permission-sets" \
    --region "$REGION"
  echo "  Waiting for stack deletion..."
  aws cloudformation wait stack-delete-complete \
    --stack-name "${PROJECT_PREFIX_LOWER}-identity-permission-sets" \
    --region "$REGION"
  echo "  Stack deleted."
fi

echo ""
echo "=== DONE. Identity domain resources removed. ==="
echo ""
echo "  Control Tower resources (AWSControlTower* groups, AWSAdministratorAccess"
echo "  Permission Set, Account Factory assignments) were NOT modified."
