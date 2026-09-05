#!/bin/bash
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CFN_DIR="$SCRIPTS_DIR/../cloudformation"

# =============================================================================
# Script  : identity/scripts/update.sh
# Purpose : Re-deploy Identity Center stacks to apply changes to Permission
#           Sets, groups, or account assignments. Idempotent — safe to run
#           multiple times. Does not modify group memberships.
#
# Use this script when:
#   - A Permission Set policy has been updated (e.g. new services added to
#     DeveloperAccess).
#   - A new group or account assignment has been added to the templates.
#   - You need to re-sync the deployed state with the template definitions.
#
# Note: Group memberships (user-to-group) are managed in create.sh and are
# not modified by this script. To add or remove a user from a group,
# update create.sh and run it — membership creation is idempotent.
# =============================================================================

echo ""
echo "=== STEP 1: RESOLVING IDENTITY CENTER INSTANCE ==="
source "$SCRIPTS_DIR/../common/resolve-instance.sh"

PROJECT_PREFIX_LOWER=$(echo "$PROJECT_PREFIX" | tr '[:upper:]' '[:lower:]')

echo ""
echo "=== STEP 2: ENABLING IDENTITY-ENHANCED SESSIONS ==="
# Idempotent — creates if not exists, updates if already configured.
# With Entra ID as external IdP, only ${path:...} SAML attributes are valid.
ABAC_STATUS=$(aws sso-admin describe-instance-access-control-attribute-configuration \
  --instance-arn "$INSTANCE_ARN" \
  --region "$REGION" \
  --query 'InstanceAccessControlAttributeConfiguration.Status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

ABAC_CONFIG='{
  "AccessControlAttributes": [
    {
      "Key": "email",
      "Value": {
        "Source": ["${path:emails[primary eq true].value}"]
      }
    }
  ]
}'

if [ "$ABAC_STATUS" = "NOT_FOUND" ] || [ -z "$ABAC_STATUS" ]; then
  aws sso-admin create-instance-access-control-attribute-configuration \
    --instance-arn "$INSTANCE_ARN" \
    --instance-access-control-attribute-configuration "$ABAC_CONFIG" \
    --region "$REGION"
  echo "Identity-enhanced sessions enabled."
else
  aws sso-admin update-instance-access-control-attribute-configuration \
    --instance-arn "$INSTANCE_ARN" \
    --instance-access-control-attribute-configuration "$ABAC_CONFIG" \
    --region "$REGION"
  echo "Identity-enhanced sessions updated."
fi

echo ""
echo "=== STEP 3: UPDATING PERMISSION SETS ==="
aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-identity-permission-sets" \
  --template-file "$CFN_DIR/1-permission-sets.yaml" \
  --parameter-overrides \
    InstanceArn="$INSTANCE_ARN" \
    ProjectPrefix="$PROJECT_PREFIX" \
    ProjectPrefixLower="$PROJECT_PREFIX_LOWER" \
  --region "$REGION" \
  --no-fail-on-empty-changeset
echo "Permission Sets updated successfully."

echo ""
echo "=== STEP 4: UPDATING GROUPS ==="
aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-identity-groups" \
  --template-file "$CFN_DIR/2-groups.yaml" \
  --parameter-overrides \
    IdentityStoreId="$IDENTITY_STORE_ID" \
    ProjectPrefix="$PROJECT_PREFIX" \
    ProjectPrefixLower="$PROJECT_PREFIX_LOWER" \
  --region "$REGION" \
  --no-fail-on-empty-changeset
echo "Groups updated successfully."

echo ""
echo "=== STEP 5: UPDATING ACCOUNT ASSIGNMENTS ==="
aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-identity-assignments" \
  --template-file "$CFN_DIR/3-assignments.yaml" \
  --parameter-overrides \
    InstanceArn="$INSTANCE_ARN" \
    ProjectPrefixLower="$PROJECT_PREFIX_LOWER" \
  --region "$REGION" \
  --no-fail-on-empty-changeset
echo "Account assignments updated successfully."

echo ""
echo "=== DONE. Identity domain updated successfully. ==="
