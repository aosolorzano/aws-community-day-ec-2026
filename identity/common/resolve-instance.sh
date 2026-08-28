#!/bin/bash

# =============================================================================
# Script  : identity/common/resolve-instance.sh
# Purpose : Resolve and validate the Identity Center instance ARN and
#           Identity Store ID. Sourced by all operational scripts in the
#           Identity domain.
#
# Usage   : source "$SCRIPTS_DIR/../common/resolve-instance.sh"
#
# Exports : INSTANCE_ARN, IDENTITY_STORE_ID
# =============================================================================

INSTANCE_ARN=$(aws sso-admin list-instances \
  --region "$REGION" \
  --query 'Instances[0].InstanceArn' \
  --output text)

IDENTITY_STORE_ID=$(aws sso-admin list-instances \
  --region "$REGION" \
  --query 'Instances[0].IdentityStoreId' \
  --output text)

if [ -z "$INSTANCE_ARN" ] || [ "$INSTANCE_ARN" = "None" ]; then
  echo "ERROR: No Identity Center instance found in region $REGION."
  echo "Identity Center is a global service — verify the region is correct."
  exit 1
fi

if [ -z "$IDENTITY_STORE_ID" ] || [ "$IDENTITY_STORE_ID" = "None" ]; then
  echo "ERROR: Could not resolve Identity Store ID from instance $INSTANCE_ARN."
  exit 1
fi

echo "Instance ARN:      $INSTANCE_ARN"
echo "Identity Store ID: $IDENTITY_STORE_ID"
