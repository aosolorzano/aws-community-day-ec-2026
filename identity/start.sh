#!/bin/bash
set -e

# =============================================================================
# Domain  : Identity
# Purpose : Identity Center, Permission Sets, Group-Based Access
# =============================================================================

DOMAIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$DOMAIN_DIR/scripts"
COMMON_DIR="$DOMAIN_DIR/../common"

source "$COMMON_DIR/validate.sh"

while true; do
  clear
  echo ""
  echo "========================================================================"
  echo "  AWS Identity Center"
  echo "========================================================================"
  echo ""
  echo "  1) Create      - Deploy all domain resources"
  echo "  2) Update      - Re-deploy and apply changes"
  echo "  3) Delete      - Remove all domain resources"
  echo "  4) SCIM Guide  - Manual provisioning setup for Entra ID"
  echo ""
  echo "  q) Quit"
  echo ""
  echo "------------------------------------------------------------------------"

  read -r -p "  Select an option: " OPERATION

  echo ""

  case $OPERATION in
    1)
      bash "$SCRIPTS_DIR/create.sh"
      ;;
    2)
      bash "$SCRIPTS_DIR/update.sh"
      ;;
    3)
      bash "$SCRIPTS_DIR/delete.sh"
      ;;
    4)
      bash "$SCRIPTS_DIR/enable-scim.sh"
      ;;
    q)
      exit 0
      ;;
    *)
      echo "  ERROR: Invalid option. Please select 1, 2, 3, 4, or q."
      sleep 2
      continue
      ;;
  esac

  echo ""
  echo "------------------------------------------------------------------------"
  read -r -s -n 1 -p "  Press any key to continue..." _
  echo ""
done
