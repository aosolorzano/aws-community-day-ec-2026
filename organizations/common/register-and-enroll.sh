#!/bin/bash
#
# Common script for registering OUs and enrolling accounts in Control Tower.
# Called by create.sh and update.sh
#
# Required environment variables: REGION, AWS_PROFILE
#
set -e

# Look at https://docs.aws.amazon.com/controltower/latest/userguide/table-of-baselines.html
BASELINE_VERSION="5.0"

echo ""
echo "--- Registering OUs in Control Tower ---"

ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)

# Get AWSControlTowerBaseline ARN
BASELINE_ARN=$(aws controltower list-baselines \
  --region "$REGION" \
  --query 'baselines[?name==`AWSControlTowerBaseline`].arn' \
  --output text)

# Get Identity Center Enabled Baseline ARN
IC_BASELINE_ARN=$(aws controltower list-baselines \
  --region "$REGION" \
  --query 'baselines[?name==`IdentityCenterBaseline`].arn' \
  --output text)

IC_ENABLED_BASELINE_ARN=$(aws controltower list-enabled-baselines \
  --region "$REGION" \
  --query "enabledBaselines[?baselineIdentifier==\`$IC_BASELINE_ARN\`].arn" \
  --output text)

echo "Baseline ARN: $BASELINE_ARN"
echo "Baseline Version: $BASELINE_VERSION"
echo "Identity Center Enabled Baseline ARN: $IC_ENABLED_BASELINE_ARN"

BASELINE_PARAMS="[{\"key\":\"IdentityCenterEnabledBaselineArn\",\"value\":\"$IC_ENABLED_BASELINE_ARN\"}]"

# Get all OUs under root (excluding Security, Suspended, and Active)
OU_LIST=$(aws organizations list-organizational-units-for-parent \
  --parent-id "$ROOT_ID" \
  --query "OrganizationalUnits[?Name!='Security' && Name!='Suspended' && Name!='Active'].[Id,Name,Arn]" --output text)

# Get already registered OUs
REGISTERED_OUS=$(aws controltower list-enabled-baselines \
  --region "$REGION" \
  --query 'enabledBaselines[].targetIdentifier' --output text 2>/dev/null || true)

while IFS=$'\t' read -r OU_ID OU_NAME OU_ARN; do
  [ -z "$OU_ID" ] && continue
  if echo "$REGISTERED_OUS" | grep -q "$OU_ARN"; then
    echo "OU '$OU_NAME' ($OU_ID) - Already registered. Skipping."
  else
    echo "OU '$OU_NAME' ($OU_ID) - Enrolling in Control Tower..."
    OPERATION_ID=$(aws controltower enable-baseline \
      --baseline-identifier "$BASELINE_ARN" \
      --baseline-version "$BASELINE_VERSION" \
      --target-identifier "$OU_ARN" \
      --parameters "$BASELINE_PARAMS" \
      --region "$REGION" \
      --query 'operationIdentifier' --output text 2>/dev/null || true)

    if [ -n "$OPERATION_ID" ] && [ "$OPERATION_ID" != "None" ]; then
      while true; do
        OP_STATUS=$(aws controltower get-baseline-operation \
          --operation-identifier "$OPERATION_ID" \
          --region "$REGION" \
          --query 'baselineOperation.status' --output text 2>/dev/null || echo "UNKNOWN")
        if [ "$OP_STATUS" = "SUCCEEDED" ]; then
          echo "  OU '$OU_NAME' enrolled successfully."
          break
        elif [ "$OP_STATUS" = "FAILED" ]; then
          echo "  WARNING: Could not enroll OU '$OU_NAME'. Please verify with your administrator."
          break
        fi
        sleep 15
      done
    else
      echo "  WARNING: Could not enroll OU '$OU_NAME'. Please verify with your administrator."
    fi
  fi
done <<< "$OU_LIST"

echo "OU registration complete."
