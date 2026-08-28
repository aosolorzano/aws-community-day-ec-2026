#!/bin/bash
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# =============================================================================
# Script  : identity/scripts/enable-scim.sh
# Purpose : Enable automatic provisioning (SCIM) in Identity Center.
#           SCIM synchronizes users and groups from an external identity
#           provider (e.g. Microsoft Entra ID) to Identity Center automatically.
#
# Prerequisites:
#   - Microsoft Entra ID P1 or P2 license (not included in Office 365
#     Business Standard or Entra ID Free). Without this license, Entra ID
#     cannot send SCIM requests to Identity Center — enabling the endpoint
#     here will have no effect.
#   - After enabling, a SCIM endpoint URL and access token will be generated.
#     These must be configured manually in the Entra ID enterprise application
#     (AWS IAM Identity Center) under Provisioning settings.
# =============================================================================

echo ""
echo "  SCIM (System for Cross-domain Identity Management) enables automatic"
echo "  synchronization of users and groups from your identity provider to"
echo "  IAM Identity Center. When active, any user or group created, updated,"
echo "  or deleted in Entra ID is reflected in Identity Center automatically."
echo ""
echo "  IMPORTANT: This feature requires a Microsoft Entra ID P1 or P2 license."
echo "  It is NOT available with Office 365 Business Standard or Entra ID Free."
echo "  Enabling the SCIM endpoint without a valid license will have no effect."
echo ""
echo "  After enabling, you must:"
echo "    1. Copy the generated SCIM endpoint URL and access token."
echo "    2. Configure them in Entra ID under:"
echo "       Enterprise Applications → AWS IAM Identity Center → Provisioning."
echo ""
read -r -p "  Do you want to enable SCIM? [y/N]: " CONFIRM
echo ""

if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "  SCIM activation cancelled."
  exit 0
fi

echo "=== RESOLVING IDENTITY CENTER INSTANCE ==="
source "$SCRIPTS_DIR/../common/resolve-instance.sh"

echo ""
echo "=== ENABLING SCIM PROVISIONING ==="
SCIM_RESPONSE=$(aws sso-admin create-access-token \
  --instance-arn "$INSTANCE_ARN" \
  --region "$REGION" 2>/dev/null || echo "UNSUPPORTED")

if [ "$SCIM_RESPONSE" = "UNSUPPORTED" ]; then
  # SCIM is enabled via the Identity Center console or the
  # PUT /instances/{instanceArn}/scim endpoint (not yet in AWS CLI).
  # Instruct the user to complete this step manually.
  echo ""
  echo "  The AWS CLI does not currently support enabling SCIM provisioning"
  echo "  directly. Complete the following steps in the AWS console:"
  echo ""
  echo "    1. Open IAM Identity Center → Settings → Automatic provisioning."
  echo "    2. Click 'Enable' to generate the SCIM endpoint and access token."
  echo "    3. Copy the SCIM endpoint URL and the access token."
  echo "    4. In Entra ID, open:"
  echo "         Enterprise Applications → AWS IAM Identity Center → Provisioning"
  echo "    5. Set Provisioning Mode to 'Automatic'."
  echo "    6. Paste the SCIM endpoint URL into 'Tenant URL'."
  echo "    7. Paste the access token into 'Secret Token'."
  echo "    8. Click 'Test Connection', then 'Save'."
  echo ""
  echo "  Once configured, Entra ID will begin synchronizing users and groups"
  echo "  to Identity Center automatically."
else
  echo "SCIM provisioning enabled."
  echo ""
  echo "  Copy the following values and configure them in Entra ID:"
  echo "  $SCIM_RESPONSE"
fi
