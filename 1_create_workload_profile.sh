#!/bin/bash
echo "[$(date)] Starting workload profile creation script..."

# Load common configuration
if [[ -f "common.sh" ]]; then
    source ./common.sh
else
    echo "Error: common.sh not found."
    exit 1
fi

# Validate required variables
echo "[$(date)] Validating required variables..."
[[ -z "${RESOURCE_GROUP}" ]] && { echo "Error: RESOURCE_GROUP is not set"; exit 1; }
[[ -z "${LOCATION}" ]] && { echo "Error: LOCATION is not set"; exit 1; }
[[ -z "${CONTAINER_APP_ENV_NAME}" ]] && { echo "Error: CONTAINER_APP_ENV_NAME is not set"; exit 1; }
echo "[$(date)] Variable validation completed."

# Create resource group if it doesn't exist
echo "[$(date)] Creating resource group '${RESOURCE_GROUP}' if it doesn't exist..."
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"
echo "[$(date)] Resource group creation completed."

# Create container app environment
echo "[$(date)] Creating container app environment '${CONTAINER_APP_ENV_NAME}'..."
az containerapp env create \
  --name "${CONTAINER_APP_ENV_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${LOCATION}"
echo "[$(date)] Container app environment creation completed."

# Add workload profile to the environment
echo "[$(date)] Adding workload profile to environment '${CONTAINER_APP_ENV_NAME}'..."
az containerapp env workload-profile add \
  --name "${CONTAINER_APP_ENV_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --workload-profile-name "Consumption" \
  --workload-profile-type "Consumption" \
  --min-nodes 0 \
  --max-nodes 10
echo "[$(date)] Workload profile addition completed."

# Check if the workload profile was created successfully
echo "[$(date)] Verifying workload profile creation..."
az containerapp env show \
    --name "${CONTAINER_APP_ENV_NAME}" \
    --resource-group "${RESOURCE_GROUP}"
echo "[$(date)] Verification completed."
