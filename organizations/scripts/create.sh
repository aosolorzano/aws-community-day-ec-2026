#!/bin/bash
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CFN_DIR="$SCRIPTS_DIR/../cloudformation"

PROJECT_PREFIX_LOWER=$(echo "$PROJECT_PREFIX" | tr '[:upper:]' '[:lower:]')

require_config() {
  local VARIABLE_NAME="$1"
  local VARIABLE_VALUE="${!VARIABLE_NAME}"
  if [ -z "$VARIABLE_VALUE" ]; then
    echo "ERROR: Required configuration '$VARIABLE_NAME' is empty."
    echo "Copy config/example.env to config/local.env and complete all values."
    exit 1
  fi
}

for VARIABLE_NAME in \
  AUDIT_ACCOUNT_EMAIL LOG_ARCHIVE_ACCOUNT_EMAIL \
  NETWORK_ACCOUNT_EMAIL NETWORK_SSO_EMAIL NETWORK_SSO_FIRST_NAME NETWORK_SSO_LAST_NAME \
  SHARED_SERVICES_ACCOUNT_EMAIL SHARED_SERVICES_SSO_EMAIL SHARED_SERVICES_SSO_FIRST_NAME SHARED_SERVICES_SSO_LAST_NAME \
  DEV_ACCOUNT_EMAIL DEV_SSO_EMAIL DEV_SSO_FIRST_NAME DEV_SSO_LAST_NAME \
  PROD_ACCOUNT_EMAIL PROD_SSO_EMAIL PROD_SSO_FIRST_NAME PROD_SSO_LAST_NAME; do
  require_config "$VARIABLE_NAME"
done

# Look at https://docs.aws.amazon.com/controltower/latest/userguide/release-notes.html
LZ_VERSION="4.0"

echo ""
echo "=== STEP 1: VALIDATING ORGANIZATION ==="
EXISTING_ORG=$(aws organizations describe-organization 2>/dev/null || true)
if [ -z "$EXISTING_ORG" ]; then
  echo "ERROR: No AWS Organization found."
  echo ""
  echo "Before running this script, you must:"
  echo "  1. Create an organization: aws organizations create-organization --feature-set ALL"
  echo "  2. Request a quota increase for 'Maximum number of accounts' to at least 15:"
  echo "     AWS Console -> Service Quotas -> AWS Organizations"
  echo "  3. Wait for the quota increase to be approved."
  exit 1
fi
echo "Organization found."

ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
echo "Organization root resolved."

# Create Suspended OU if it doesn't exist (managed outside CFN)
SUSPENDED_OU_ID=$(aws organizations list-organizational-units-for-parent \
  --parent-id "$ROOT_ID" \
  --query "OrganizationalUnits[?Name=='Suspended'].Id | [0]" --output text)
if [ -z "$SUSPENDED_OU_ID" ] || [ "$SUSPENDED_OU_ID" = "None" ]; then
  aws organizations create-organizational-unit \
    --parent-id "$ROOT_ID" \
    --name "Suspended" \
    --no-cli-pager > /dev/null 2>&1 || true
  echo "Suspended OU created."
fi

echo ""
echo "=== STEP 2: CREATING IAM ROLES ==="
aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-iam-roles" \
  --template-file "$CFN_DIR/1-iam-roles.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION"
echo "IAM roles created successfully."

echo ""
echo "=== STEP 3: CREATING OUs ==="
aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-ous" \
  --template-file "$CFN_DIR/2-ous.yaml" \
  --parameter-overrides \
    RootId="$ROOT_ID" \
    ProjectPrefixLower="$PROJECT_PREFIX_LOWER" \
    AuditEmail="$AUDIT_ACCOUNT_EMAIL" \
    LogArchiveEmail="$LOG_ARCHIVE_ACCOUNT_EMAIL" \
  --region "$REGION"
echo "OUs created successfully."

echo ""
echo "=== STEP 4: CREATING SECURITY ACCOUNTS ==="
AUDIT_ID=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_PREFIX_LOWER}-ous" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`AuditAccountId`].OutputValue' --output text)

LOG_ARCHIVE_ID=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_PREFIX_LOWER}-ous" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`LogArchiveAccountId`].OutputValue' --output text)

echo "Audit Account ID:       $AUDIT_ID"
echo "Log Archive Account ID: $LOG_ARCHIVE_ID"
echo "Security accounts created successfully."

echo ""
echo "=== STEP 5: CREATING LANDING ZONE ==="
aws iam create-service-linked-role \
  --aws-service-name sso.amazonaws.com \
  > /dev/null 2>&1 || true

# Check if Landing Zone already exists
EXISTING_LZ=$(aws controltower list-landing-zones \
  --region "$REGION" \
  --query 'landingZones[0].arn' --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_LZ" ] && [ "$EXISTING_LZ" != "None" ]; then
  echo "Landing Zone already exists. Skipping creation."
else
  cat <<EOF >/tmp/landing-zone-manifest.json
{
  "governedRegions": ["$REGION"],
  "accessManagement": {
    "enabled": true
  },
  "centralizedLogging": {
    "accountId": "$LOG_ARCHIVE_ID",
    "enabled": true,
    "configurations": {
      "loggingBucket": {
        "retentionDays": 60
      },
      "accessLoggingBucket": {
        "retentionDays": 60
      }
    }
  },
  "securityRoles": {
    "accountId": "$AUDIT_ID",
    "enabled": true
  },
  "config": {
    "accountId": "$AUDIT_ID",
    "enabled": true,
    "configurations": {
      "loggingBucket": {
        "retentionDays": 60
      },
      "accessLoggingBucket": {
        "retentionDays": 60
      }
    }
  },
  "backup": {
    "enabled": false
  }
}
EOF

  OPERATION_ID=$(aws controltower create-landing-zone \
    --manifest file:///tmp/landing-zone-manifest.json \
    --landing-zone-version "$LZ_VERSION" \
    --remediation-types "INHERITANCE_DRIFT" \
    --region "$REGION" \
    --query 'operationIdentifier' --output text)

  echo "Landing Zone creation started (version $LZ_VERSION). Operation ID: $OPERATION_ID"
  echo "This may take 30-60 minutes..."

  while true; do
    STATUS=$(aws controltower get-landing-zone-operation \
      --operation-identifier "$OPERATION_ID" \
      --region "$REGION" \
      --query 'operationDetails.status' --output text)
    echo "$(date '+%H:%M:%S') - Status: $STATUS"
    if [ "$STATUS" = "SUCCEEDED" ]; then
      echo "Landing Zone created successfully!"
      break
    elif [ "$STATUS" = "FAILED" ]; then
      echo "ERROR: Landing Zone creation failed."
      rm -f /tmp/landing-zone-manifest.json
      exit 1
    fi
    sleep 30
  done

  rm -f /tmp/landing-zone-manifest.json
fi

echo ""
echo "=== STEP 6: GRANTING ACCESS TO SERVICE CATALOG PORTFOLIO ==="
PORTFOLIO_ID=$(aws servicecatalog list-portfolios \
  --region "$REGION" \
  --query "PortfolioDetails[?DisplayName=='AWS Control Tower Account Factory Portfolio'].Id" \
  --output text)

CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)

aws servicecatalog associate-principal-with-portfolio \
  --portfolio-id "$PORTFOLIO_ID" \
  --principal-arn "$CALLER_ARN" \
  --principal-type IAM \
  --region "$REGION" 2>/dev/null || true
echo "Service Catalog portfolio access granted."

echo ""
echo "=== STEP 7: REGISTERING OUs IN CONTROL TOWER ==="
source "$SCRIPTS_DIR/../common/register-and-enroll.sh"

echo ""
echo "=== STEP 8: CREATING ACCOUNTS VIA ACCOUNT FACTORY ==="
echo "This may take 30-60 minutes (accounts are created sequentially)..."

PRODUCT_ID=$(aws servicecatalog search-products \
  --region "$REGION" \
  --query "ProductViewSummaries[?Name=='AWS Control Tower Account Factory'].ProductId" \
  --output text)

ARTIFACT_ID=$(aws servicecatalog list-provisioning-artifacts \
  --product-id "$PRODUCT_ID" \
  --region "$REGION" \
  --query "ProvisioningArtifactDetails[?Active==\`true\`].Id" \
  --output text)

aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-accounts" \
  --template-file "$CFN_DIR/3-accounts.yaml" \
  --parameter-overrides \
    AccountFactoryProductId="$PRODUCT_ID" \
    AccountFactoryArtifactId="$ARTIFACT_ID" \
    ProjectPrefixLower="$PROJECT_PREFIX_LOWER" \
    NetworkAccountEmail="$NETWORK_ACCOUNT_EMAIL" \
    NetworkUserEmail="$NETWORK_SSO_EMAIL" \
    NetworkUserFirstName="$NETWORK_SSO_FIRST_NAME" \
    NetworkUserLastName="$NETWORK_SSO_LAST_NAME" \
    SharedServicesAccountEmail="$SHARED_SERVICES_ACCOUNT_EMAIL" \
    SharedServicesUserEmail="$SHARED_SERVICES_SSO_EMAIL" \
    SharedServicesUserFirstName="$SHARED_SERVICES_SSO_FIRST_NAME" \
    SharedServicesUserLastName="$SHARED_SERVICES_SSO_LAST_NAME" \
    DevAccountEmail="$DEV_ACCOUNT_EMAIL" \
    DevUserEmail="$DEV_SSO_EMAIL" \
    DevUserFirstName="$DEV_SSO_FIRST_NAME" \
    DevUserLastName="$DEV_SSO_LAST_NAME" \
    ProdAccountEmail="$PROD_ACCOUNT_EMAIL" \
    ProdUserEmail="$PROD_SSO_EMAIL" \
    ProdUserFirstName="$PROD_SSO_FIRST_NAME" \
    ProdUserLastName="$PROD_SSO_LAST_NAME" \
  --region "$REGION"
echo "All accounts created and enrolled successfully."

echo ""
echo "=== STEP 9: APPLYING GUARDRAILS ==="
aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-org-guardrails" \
  --template-file "$CFN_DIR/4-guardrails.yaml" \
  --parameter-overrides \
    Region="$REGION" \
    ProjectPrefixLower="$PROJECT_PREFIX_LOWER" \
  --region "$REGION"
echo "Guardrails applied successfully."

echo ""
echo "=== STEP 10: APPLYING SERVICE CONTROL POLICIES ==="
aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-org-scps" \
  --template-file "$CFN_DIR/5-scps.yaml" \
  --parameter-overrides \
    ProjectPrefix="$PROJECT_PREFIX" \
    ProjectPrefixLower="$PROJECT_PREFIX_LOWER" \
  --region "$REGION"
echo "Service Control Policies applied successfully."

echo ""
echo "=== STEP 11: APPLYING RESOURCE CONTROL POLICIES ==="
MANAGEMENT_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
ORG_ID=$(aws organizations describe-organization --query 'Organization.Id' --output text)

# Enable RCPs at the root level if not already enabled
RCP_STATUS=$(aws organizations describe-organization \
  --query "Organization.AvailablePolicyTypes[?Type=='RESOURCE_CONTROL_POLICY'].Status" \
  --output text)

if [ "$RCP_STATUS" != "ENABLED" ]; then
  echo "Enabling Resource Control Policies..."
  aws organizations enable-policy-type \
    --root-id "$ROOT_ID" \
    --policy-type RESOURCE_CONTROL_POLICY \
    --region "$REGION" \
    > /dev/null 2>&1 || true
  echo "Resource Control Policies enabled."
else
  echo "Resource Control Policies already enabled."
fi

aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-org-rcps" \
  --template-file "$CFN_DIR/6-rcps.yaml" \
  --parameter-overrides \
    OrganizationId="$ORG_ID" \
    ManagementAccountId="$MANAGEMENT_ACCOUNT_ID" \
    ProjectPrefix="$PROJECT_PREFIX" \
    ProjectPrefixLower="$PROJECT_PREFIX_LOWER" \
  --region "$REGION"
echo "Resource Control Policies applied successfully."

echo ""
echo "=== DONE. Organization fully deployed and governed. ==="
