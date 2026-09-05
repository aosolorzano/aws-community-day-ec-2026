#!/bin/bash

# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config/local.env}"

# Deployment-specific values live outside version control. The example file is
# safe to publish; config/local.env is intentionally ignored by Git.
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  set -a
  source "$CONFIG_FILE"
  set +a
fi
# Script  : common/validate.sh
# Purpose : Shared validations — sourced by all domain start.sh scripts.
#
# Usage   : source "$(dirname "$0")/../common/validate.sh"
#
# Behavior:
#   - If AWS_PROFILE and REGION are already exported (called from main menu),
#     they are used as-is without prompting the user again.
#   - If not set (script run directly), the user is prompted for both values.
#   - After capturing AWS_PROFILE, validates that the profile exists in both
#     ~/.aws/config and ~/.aws/credentials (required for the Management account
#     operator who uses IAM access keys, not SSO).
# =============================================================================

# -----------------------------------------------------------------------------
# Helper: verify that a profile exists in the local AWS CLI configuration.
# Called after AWS_PROFILE is set, either from the environment or from prompt.
# -----------------------------------------------------------------------------
_verify_aws_profile() {
  local PROFILE="$1"

  # In ~/.aws/config, profiles are declared as [profile name] except for
  # the default profile which is declared as [default].
  if [ "$PROFILE" = "default" ]; then
    local CONFIG_PATTERN="\[default\]"
  else
    local CONFIG_PATTERN="\[profile ${PROFILE}\]"
  fi

  if [ ! -f "$HOME/.aws/config" ] || ! grep -qE "$CONFIG_PATTERN" "$HOME/.aws/config"; then
    echo ""
    echo "  ERROR: Profile '$PROFILE' is not configured in ~/.aws/config."
    echo "  Add the profile and try again."
    echo ""
    exit 1
  fi

  # In ~/.aws/credentials, profiles are declared as [name] (no 'profile' prefix).
  local CREDENTIALS_PATTERN="\[${PROFILE}\]"

  if [ ! -f "$HOME/.aws/credentials" ] || ! grep -qE "$CREDENTIALS_PATTERN" "$HOME/.aws/credentials"; then
    echo ""
    echo "  ERROR: Profile '$PROFILE' has no credentials in ~/.aws/credentials."
    echo "  Run 'aws configure --profile $PROFILE' and try again."
    echo ""
    exit 1
  fi
}

if [ -z "$AWS_PROFILE" ]; then
  read -r -p "  AWS profile name       : " AWS_PROFILE
  export AWS_PROFILE
fi

_verify_aws_profile "$AWS_PROFILE"

if [ -z "$REGION" ]; then
  read -r -p "  AWS region [us-east-1] : " REGION
  REGION="${REGION:-us-east-1}"
  export REGION
fi

if [ -z "$PROJECT_PREFIX" ]; then
  PROJECT_PREFIX="Acme"
fi
export PROJECT_PREFIX
