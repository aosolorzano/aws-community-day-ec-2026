#!/bin/bash
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CFN_DIR="$SCRIPTS_DIR/../cloudformation"
PROJECT_PREFIX_LOWER=$(echo "$PROJECT_PREFIX" | tr '[:upper:]' '[:lower:]')

delete_stack_if_exists() {
  local STACK_NAME="$1"

  if aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    > /dev/null 2>&1; then
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
    echo "  Stack '$STACK_NAME' deleted."
  else
    echo "  Stack '$STACK_NAME' not found, skipping."
  fi
}

echo ""
echo "  WARNING: This will permanently delete all Organizations domain resources:"
echo "    - Landing Zone and all Control Tower configuration"
echo "    - All member accounts (accounts will be closed)"
echo "    - All OUs, guardrails, SCPs, and RCPs"
echo "    - Identity Center instance"
echo ""
echo "  This operation is IRREVERSIBLE. Account emails are blocked for 90 days"
echo "  after closure."
echo ""
read -r -p "  Are you sure you want to proceed? [y/N]: " CONFIRM
echo ""

if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "  Deletion cancelled."
  exit 0
fi

echo ""
echo "=== STEP 1: REMOVING CUSTOM GOVERNANCE STACKS ==="
# These stacks must be removed before the Landing Zone and OUs because they
# attach controls and organization policies to the target OUs.
delete_stack_if_exists "${PROJECT_PREFIX_LOWER}-org-guardrails"
delete_stack_if_exists "${PROJECT_PREFIX_LOWER}-org-scps"
delete_stack_if_exists "${PROJECT_PREFIX_LOWER}-org-rcps"

echo ""
echo "=== STEP 2: DELETING LANDING ZONE ==="
LZ_ARN=$(aws controltower list-landing-zones \
  --region "$REGION" \
  --query 'landingZones[0].arn' --output text 2>/dev/null || echo "")

if [ -n "$LZ_ARN" ] && [ "$LZ_ARN" != "None" ]; then
  OPERATION_ID=$(aws controltower delete-landing-zone \
    --landing-zone-identifier "$LZ_ARN" \
    --region "$REGION" \
    --query 'operationIdentifier' --output text)

  echo "Landing Zone deletion started. Operation ID: $OPERATION_ID"
  while true; do
    STATUS=$(aws controltower get-landing-zone-operation \
      --operation-identifier "$OPERATION_ID" \
      --region "$REGION" \
      --query 'operationDetails.status' --output text)
    echo "$(date '+%H:%M:%S') - Status: $STATUS"
    if [ "$STATUS" = "SUCCEEDED" ]; then
      echo "Landing Zone deleted successfully."
      break
    elif [ "$STATUS" = "FAILED" ]; then
      echo "ERROR: Landing Zone deletion failed."
      exit 1
    fi
    sleep 30
  done
else
  echo "No Landing Zone found. Skipping."
fi

echo ""
echo "=== STEP 3: CLOSING MEMBER ACCOUNTS ==="
MGMT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
ACCOUNTS=$(aws organizations list-accounts \
  --query "Accounts[?Status=='ACTIVE' && Id!='$MGMT_ID'].Id" --output text)

for ACCOUNT_ID in $ACCOUNTS; do
  echo "Closing account $ACCOUNT_ID..."
  aws organizations close-account --account-id "$ACCOUNT_ID" || true
done
echo "Member accounts closed."

echo ""
echo "=== STEP 4: MOVING ACCOUNTS TO CLEANUP OUs ==="
ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)

# Create 'Suspended' OU for closed accounts (if it doesn't exist)
SUSPENDED_OU_ID=$(aws organizations list-organizational-units-for-parent \
  --parent-id "$ROOT_ID" \
  --query "OrganizationalUnits[?Name=='Suspended'].Id | [0]" --output text)

if [ -z "$SUSPENDED_OU_ID" ] || [ "$SUSPENDED_OU_ID" = "None" ]; then
  SUSPENDED_OU_ID=$(aws organizations create-organizational-unit \
    --parent-id "$ROOT_ID" \
    --name "Suspended" \
    --query 'OrganizationalUnit.Id' --output text)
  echo "Created 'Suspended' OU: $SUSPENDED_OU_ID"
fi

# Create 'Active' OU for accounts that could not be closed
ACTIVE_OU_ID=""

# Move accounts based on their status
ALL_OUS=$(aws organizations list-organizational-units-for-parent \
  --parent-id "$ROOT_ID" \
  --query "OrganizationalUnits[?Name!='Suspended' && Name!='Active'].[Id]" --output text)

for OU_ID in $ALL_OUS; do
  MEMBER_ACCOUNTS=$(aws organizations list-accounts-for-parent \
    --parent-id "$OU_ID" --query 'Accounts[].[Id,Status]' --output text)
  while IFS=$'\t' read -r ACC STATUS; do
    [ -z "$ACC" ] && continue
    if [ "$STATUS" = "SUSPENDED" ]; then
      aws organizations move-account --account-id "$ACC" \
        --source-parent-id "$OU_ID" --destination-parent-id "$SUSPENDED_OU_ID" || true
    elif [ "$STATUS" = "ACTIVE" ] && [ "$ACC" != "$MGMT_ID" ]; then
      if [ -z "$ACTIVE_OU_ID" ]; then
        ACTIVE_OU_ID=$(aws organizations create-organizational-unit \
          --parent-id "$ROOT_ID" \
          --name "Active" \
          --query 'OrganizationalUnit.Id' --output text)
        echo "Created 'Active' OU: $ACTIVE_OU_ID (some accounts could not be closed)"
      fi
      aws organizations move-account --account-id "$ACC" \
        --source-parent-id "$OU_ID" --destination-parent-id "$ACTIVE_OU_ID" || true
      echo "  WARNING: Account $ACC is still active. Moved to 'Active' OU."
    fi
  done <<< "$MEMBER_ACCOUNTS"
done

# Move accounts from root
ROOT_ACCOUNTS=$(aws organizations list-accounts-for-parent \
  --parent-id "$ROOT_ID" --query "Accounts[?Id!='$MGMT_ID'].[Id,Status]" --output text)

while IFS=$'\t' read -r ACC STATUS; do
  [ -z "$ACC" ] && continue
  if [ "$STATUS" = "SUSPENDED" ]; then
    aws organizations move-account --account-id "$ACC" \
      --source-parent-id "$ROOT_ID" --destination-parent-id "$SUSPENDED_OU_ID" || true
  elif [ "$STATUS" = "ACTIVE" ]; then
    if [ -z "$ACTIVE_OU_ID" ]; then
      ACTIVE_OU_ID=$(aws organizations create-organizational-unit \
        --parent-id "$ROOT_ID" \
        --name "Active" \
        --query 'OrganizationalUnit.Id' --output text)
      echo "Created 'Active' OU: $ACTIVE_OU_ID (some accounts could not be closed)"
    fi
    aws organizations move-account --account-id "$ACC" \
      --source-parent-id "$ROOT_ID" --destination-parent-id "$ACTIVE_OU_ID" || true
    echo "  WARNING: Account $ACC is still active. Moved to 'Active' OU."
  fi
done <<< "$ROOT_ACCOUNTS"

echo "Accounts moved to cleanup OUs."

echo ""
echo "=== STEP 5: DELETING IDENTITY CENTER INSTANCE ==="
IC_INSTANCE_ARN=$(aws sso-admin list-instances \
  --region "$REGION" \
  --query 'Instances[0].InstanceArn' --output text 2>/dev/null || true)

if [ -n "$IC_INSTANCE_ARN" ] && [ "$IC_INSTANCE_ARN" != "None" ]; then
  aws sso-admin delete-instance \
    --instance-arn "$IC_INSTANCE_ARN" \
    --region "$REGION"
  echo "Identity Center instance deleted."
else
  echo "No Identity Center instance found. Skipping."
fi

echo ""
echo "=== STEP 6: CLEANING UP CONTROL TOWER RESIDUAL RESOURCES ==="
aws logs delete-log-group \
  --log-group-name "aws-controltower/CloudTrailLogs" \
  --region "$REGION" 2>/dev/null || true
echo "Residual resources cleaned."

echo ""
echo "=== STEP 7: DISABLING RESOURCE CONTROL POLICIES ==="
# RCPs were enabled explicitly by this project's create.sh — disable them here.
# SCPs were enabled by Control Tower and will be disabled when CT is removed.
ROOT_ID_DEL=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
RCP_STATUS=$(aws organizations describe-organization \
  --query "Organization.AvailablePolicyTypes[?Type=='RESOURCE_CONTROL_POLICY'].Status" \
  --output text 2>/dev/null || echo "")

if [ "$RCP_STATUS" = "ENABLED" ]; then
  aws organizations disable-policy-type \
    --root-id "$ROOT_ID_DEL" \
    --policy-type RESOURCE_CONTROL_POLICY \
    --region "$REGION" \
    > /dev/null 2>&1 || true
  echo "Resource Control Policies disabled."
else
  echo "Resource Control Policies not enabled, skipping."
fi

echo ""
echo "=== STEP 8: DELETING REMAINING CLOUDFORMATION STACKS ==="
delete_stack_if_exists "${PROJECT_PREFIX_LOWER}-accounts"
delete_stack_if_exists "${PROJECT_PREFIX_LOWER}-ous"
delete_stack_if_exists "${PROJECT_PREFIX_LOWER}-iam-roles"
echo "CloudFormation stacks deleted."

echo ""
echo "=== DONE ==="
echo "All resources have been deleted successfully."
