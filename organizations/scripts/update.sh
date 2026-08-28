#!/bin/bash
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CFN_DIR="$SCRIPTS_DIR/../cloudformation"

PROJECT_PREFIX_LOWER=$(echo "$PROJECT_PREFIX" | tr '[:upper:]' '[:lower:]')

echo ""
echo "=== STEP 1: UPDATING OUs ==="
ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)

# Validate account quota
CURRENT_ACCOUNTS=$(aws organizations list-accounts --query 'length(Accounts[])' --output text)
echo "Current accounts in the organization: $CURRENT_ACCOUNTS"

aws cloudformation deploy \
  --stack-name acme-ous \
  --template-file "$CFN_DIR/2-ous.yaml" \
  --parameter-overrides \
    RootId="$ROOT_ID" \
    ProjectPrefix="$PROJECT_PREFIX" \
    ProjectPrefixLower="$PROJECT_PREFIX_LOWER" \
  --region "$REGION" \
  --no-fail-on-empty-changeset
echo "OUs updated successfully."

echo ""
echo "=== STEP 2: GRANTING ACCESS TO SERVICE CATALOG PORTFOLIO ==="
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
echo "=== STEP 3: REGISTERING OUs IN CONTROL TOWER ==="
source "$SCRIPTS_DIR/../common/register-and-enroll.sh"

echo ""
echo "=== STEP 4: CREATING/UPDATING ACCOUNTS VIA ACCOUNT FACTORY ==="
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
  --stack-name acme-accounts \
  --template-file "$CFN_DIR/3-accounts.yaml" \
  --parameter-overrides \
    AccountFactoryProductId="$PRODUCT_ID" \
    AccountFactoryArtifactId="$ARTIFACT_ID" \
  --region "$REGION" \
  --no-fail-on-empty-changeset
echo "Accounts updated successfully."

echo ""
echo "=== STEP 5: APPLYING GUARDRAILS ==="
aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-org-guardrails" \
  --template-file "$CFN_DIR/4-guardrails.yaml" \
  --parameter-overrides Region="$REGION" \
  --region "$REGION" \
  --no-fail-on-empty-changeset
echo "Guardrails applied successfully."

echo ""
echo "=== STEP 6: APPLYING SERVICE CONTROL POLICIES ==="
aws cloudformation deploy \
  --stack-name "${PROJECT_PREFIX_LOWER}-org-scps" \
  --template-file "$CFN_DIR/5-scps.yaml" \
  --parameter-overrides \
    RootId="$ROOT_ID" \
    ProjectPrefix="$PROJECT_PREFIX" \
    ProjectPrefixLower="$PROJECT_PREFIX_LOWER" \
  --region "$REGION" \
  --no-fail-on-empty-changeset
echo "Service Control Policies applied successfully."

echo ""
echo "=== STEP 7: APPLYING RESOURCE CONTROL POLICIES ==="
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
  --region "$REGION" \
  --no-fail-on-empty-changeset
echo "Resource Control Policies applied successfully."

echo ""
echo "=== DONE. Organization structure updated. ==="
