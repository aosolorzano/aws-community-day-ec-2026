#!/bin/bash
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CFN_DIR="$SCRIPTS_DIR/../cloudformation"

PROJECT_PREFIX_LOWER=$(echo "$PROJECT_PREFIX" | tr '[:upper:]' '[:lower:]')

for VARIABLE_NAME in NETWORK_SSO_EMAIL SHARED_SERVICES_SSO_EMAIL DEV_SSO_EMAIL PROD_SSO_EMAIL; do
  VARIABLE_VALUE="${!VARIABLE_NAME}"
  if [ -z "$VARIABLE_VALUE" ]; then
    echo "ERROR: Required configuration '$VARIABLE_NAME' is empty."
    echo "Copy config/example.env to config/local.env and complete all values."
    exit 1
  fi
done

echo ""
echo "=== STEP 1: RESOLVING IDENTITY CENTER INSTANCE ==="
source "$SCRIPTS_DIR/../common/resolve-instance.sh"

echo ""
echo "=== STEP 2: ENABLING IDENTITY-ENHANCED SESSIONS ==="
# Configures ABAC attributes injected into every SSO session context.
# With Entra ID as external IdP, only SAML assertion attributes (${path:...})
# are valid as Source values. The identitystore:UserId prefix is only supported
# when using the IAM Identity Center internal directory as identity source.
# Idempotent: creates the configuration if it does not exist, updates it if it does.
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
echo "=== STEP 3: DEPLOYING PERMISSION SETS ==="
aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-identity-permission-sets" \
  --template-file "$CFN_DIR/1-permission-sets.yaml" \
  --parameter-overrides \
    InstanceArn="$INSTANCE_ARN" \
    ProjectPrefix="$PROJECT_PREFIX" \
    ProjectPrefixLower="$PROJECT_PREFIX_LOWER" \
  --region "$REGION"
echo "Permission Sets deployed successfully."

echo ""
echo "=== STEP 4: DEPLOYING GROUPS ==="
aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-identity-groups" \
  --template-file "$CFN_DIR/2-groups.yaml" \
  --parameter-overrides \
    IdentityStoreId="$IDENTITY_STORE_ID" \
    ProjectPrefix="$PROJECT_PREFIX" \
    ProjectPrefixLower="$PROJECT_PREFIX_LOWER" \
  --region "$REGION"
echo "Groups deployed successfully."

echo ""
echo "=== STEP 5: DEPLOYING ACCOUNT ASSIGNMENTS ==="
aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-identity-assignments" \
  --template-file "$CFN_DIR/3-assignments.yaml" \
  --parameter-overrides \
    InstanceArn="$INSTANCE_ARN" \
    ProjectPrefixLower="$PROJECT_PREFIX_LOWER" \
  --region "$REGION"
echo "Account assignments deployed successfully."

echo ""
echo "=== STEP 6: RESOLVING USER IDs ==="
resolve_user_id() {
  local EMAIL="$1"
  aws identitystore list-users \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --filters "AttributePath=UserName,AttributeValue=$EMAIL" \
    --region "$REGION" \
    --query 'Users[0].UserId' \
    --output text
}

INFRA_USER_ID=$(resolve_user_id "$NETWORK_SSO_EMAIL")
PLATFORM_USER_ID=$(resolve_user_id "$SHARED_SERVICES_SSO_EMAIL")
DEVELOPER_USER_ID=$(resolve_user_id "$DEV_SSO_EMAIL")
OPERATIONS_USER_ID=$(resolve_user_id "$PROD_SSO_EMAIL")

for ROLE_ID in \
  "infrastructure administrator:$INFRA_USER_ID" \
  "platform administrator:$PLATFORM_USER_ID" \
  "developer:$DEVELOPER_USER_ID" \
  "operations engineer:$OPERATIONS_USER_ID"; do
  ROLE="${ROLE_ID%%:*}"
  ID="${ROLE_ID##*:}"
  if [ -z "$ID" ] || [ "$ID" = "None" ]; then
    echo "ERROR: The $ROLE user was not found in the Identity Store."
    echo "Verify the corresponding SSO email in config/local.env."
    exit 1
  fi
done
echo "User IDs resolved successfully."

echo ""
echo "=== STEP 7: RESOLVING GROUP IDs ==="
resolve_group_id() {
  local GROUP_NAME="$1"
  aws cloudformation describe-stacks \
    --stack-name "${PROJECT_PREFIX_LOWER}-identity-groups" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='${GROUP_NAME}GroupId'].OutputValue" \
    --output text
}

INFRA_ADMINS_GROUP_ID=$(resolve_group_id "InfrastructureAdmins")
PLATFORM_ADMINS_GROUP_ID=$(resolve_group_id "PlatformAdmins")
DEVELOPERS_GROUP_ID=$(resolve_group_id "Developers")
OPERATIONS_GROUP_ID=$(resolve_group_id "Operations")
echo "Group IDs resolved successfully."


echo ""
echo "=== STEP 8: ASSIGNING USERS TO GROUPS ==="

add_member() {
  local GROUP_ID="$1"
  local USER_ID="$2"
  local LABEL="$3"

  # Check if membership already exists to make this step idempotent
  EXISTING=$(aws identitystore list-group-memberships \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --group-id "$GROUP_ID" \
    --region "$REGION" \
    --query "GroupMemberships[?MemberId.UserId=='$USER_ID'].MembershipId" \
    --output text)

  if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
    echo "  $LABEL — already a member, skipping."
  else
    aws identitystore create-group-membership \
      --identity-store-id "$IDENTITY_STORE_ID" \
      --group-id "$GROUP_ID" \
      --member-id "UserId=$USER_ID" \
      --region "$REGION" \
      > /dev/null 2>&1
    echo "  $LABEL — member added."
  fi
}

add_member "$INFRA_ADMINS_GROUP_ID"    "$INFRA_USER_ID"          "${PROJECT_PREFIX}-Infrastructure-Admins"
add_member "$PLATFORM_ADMINS_GROUP_ID" "$PLATFORM_USER_ID"       "${PROJECT_PREFIX}-Platform-Admins"
add_member "$DEVELOPERS_GROUP_ID"      "$DEVELOPER_USER_ID"      "${PROJECT_PREFIX}-Developers"
add_member "$OPERATIONS_GROUP_ID"      "$OPERATIONS_USER_ID"     "${PROJECT_PREFIX}-Operations"

echo ""
echo "=== DONE. Identity domain fully deployed. ==="
echo ""
echo "  Next steps:"
echo "  - Configure AWS CLI profiles for each user (see identity/README.md)."
echo "  - Run access verification tests to confirm permissions are correct."
