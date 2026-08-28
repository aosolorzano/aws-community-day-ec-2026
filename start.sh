#!/bin/bash
set -e

# =============================================================================
# Project : AWS Infrastructure
# Purpose : Main entry point — select a domain to manage
# =============================================================================

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

# -----------------------------------------------------------------------------
# Initial setup — prompt for AWS credentials context
# -----------------------------------------------------------------------------
clear
echo ""
echo "========================================================================"
echo "  AWS Infrastructure"
echo "========================================================================"
echo ""
read -r -p "  AWS profile    [default]  : " AWS_PROFILE
AWS_PROFILE="${AWS_PROFILE:-default}"
export AWS_PROFILE

read -r -p "  AWS region     [us-east-1]: " REGION
REGION="${REGION:-us-east-1}"
export REGION

# Internal project prefix — drives all resource naming conventions.
PROJECT_PREFIX="Acme"
export PROJECT_PREFIX

# Verify the profile exists before entering the menu loop
source "$ROOT_DIR/common/validate.sh"

# -----------------------------------------------------------------------------
# Main menu loop
# -----------------------------------------------------------------------------
while true; do
  clear
  echo ""
  echo "========================================================================"
  echo "  AWS Infrastructure"
  echo "========================================================================"
  echo ""
  echo "  Domains:"
  echo ""
  echo "  1) Organizations  - Multi-account governance and structure"
  echo "  2) Identity       - Access control and user management"
  echo ""
  echo "  q) Quit"
  echo ""
  echo "------------------------------------------------------------------------"

  read -r -p "  Select an option: " DOMAIN

  echo ""

  case $DOMAIN in
    1)
      AWS_PROFILE="$AWS_PROFILE" REGION="$REGION" PROJECT_PREFIX="$PROJECT_PREFIX" bash "$ROOT_DIR/organizations/start.sh"
      ;;
    2)
      AWS_PROFILE="$AWS_PROFILE" REGION="$REGION" PROJECT_PREFIX="$PROJECT_PREFIX" bash "$ROOT_DIR/identity/start.sh"
      ;;
    q)
      clear
      echo ""
      echo "  Goodbye!"
      echo ""
      exit 0
      ;;
    *)
      echo "  ERROR: Invalid option. Please select 1, 2, or q."
      sleep 2
      ;;
  esac
done
