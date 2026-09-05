#!/bin/bash
set -e

# =============================================================================
# Script  : identity/scripts/enable-scim.sh
# Purpose : Explain the manual provisioning (SCIM) setup in Identity Center.
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
read -r -p "  Do you want to display the SCIM setup guide? [y/N]: " CONFIRM
echo ""

if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "  SCIM setup guide cancelled."
  exit 0
fi

echo ""
echo "=== SCIM SETUP GUIDE ==="
echo ""
echo "  SCIM provisioning is configured manually because the setup generates"
echo "  a sensitive access token that must never be printed or committed."
echo ""
echo "  1. Open IAM Identity Center → Settings → Automatic provisioning."
echo "  2. Click 'Enable' to generate the SCIM endpoint and access token."
echo "  3. Store both values in an approved secrets manager."
echo "  4. In Entra ID, open:"
echo "       Enterprise Applications → AWS IAM Identity Center → Provisioning"
echo "  5. Set Provisioning Mode to 'Automatic'."
echo "  6. Paste the SCIM endpoint URL into 'Tenant URL'."
echo "  7. Paste the access token into 'Secret Token'."
echo "  8. Test the connection, save, and enable provisioning."
echo ""
echo "  Never add the SCIM endpoint or access token to this repository."
