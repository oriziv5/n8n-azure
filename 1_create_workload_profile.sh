#!/bin/bash
echo "[$(date)] Starting workload profile creation script..."

# Required Configuration Variables
RESOURCE_GROUP="n8n-rg-northeurope-linux"
LOCATION="northeurope"  # Change to your desired Azure region
WORKLOAD_PROFILE_NAME="n8n-workload-profile"

# Validate required variables
echo "[$(date)] Validating required variables..."
[[ -z "${RESOURCE_GROUP}" ]] && { echo "Error: RESOURCE_GROUP is not set"; exit 1; }
[[ -z "${LOCATION}" ]] && { echo "Error: LOCATION is not set"; exit 1; }
[[ -z "${WORKLOAD_PROFILE_NAME}" ]] && { echo "Error: WORKLOAD_PROFILE_NAME is not set"; exit 1; }
echo "[$(date)] Variable validation completed."

# Create resource group if it doesn't exist
echo "[$(date)] Creating resource group '${RESOURCE_GROUP}' if it doesn't exist..."
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"
echo "[$(date)] Resource group creation completed."

# Create container app environment
echo "[$(date)] Creating container app environment '${WORKLOAD_PROFILE_NAME}'..."
az containerapp env create \
  --name "${WORKLOAD_PROFILE_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${LOCATION}"
echo "[$(date)] Container app environment creation completed."

# Add workload profile to the environment
echo "[$(date)] Adding workload profile to environment '${WORKLOAD_PROFILE_NAME}'..."
az containerapp env workload-profile add \
  --name "${WORKLOAD_PROFILE_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --workload-profile-name "Consumption" \
  --workload-profile-type "Consumption" \
  --min-nodes 0 \
  --max-nodes 10
echo "[$(date)] Workload profile addition completed."

# Check if the workload profile was created successfully
echo "[$(date)] Verifying workload profile creation..."
az containerapp env show \
    --name "${WORKLOAD_PROFILE_NAME}" \
    --resource-group "${RESOURCE_GROUP}"
echo "[$(date)] Verification completed."
