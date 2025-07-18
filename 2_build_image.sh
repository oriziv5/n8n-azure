#!/bin/bash
echo "[$(date)] Starting Azure Container Registry build script..."

# Required Configuration Variables
ACR_NAME="mypersonalacr"  # Change to your Azure Container Registry name
IMAGE_NAME="n8n-azure-linux-main-test"  # Change to your desired image name
RESOURCE_GROUP="n8n-rg-northeurope-linux"  # Change to your resource group name
LOCATION="northeurope"  # Change to your desired Azure region
DOCKERFILE_PATH="Dockerfile.azurelinux"  # Change to your Dockerfile path (default: Dockerfile)

# Validate required variables
echo "[$(date)] Validating required variables..."
[[ -z "${ACR_NAME}" ]] && { echo "Error: ACR_NAME is not set"; exit 1; }
[[ -z "${IMAGE_NAME}" ]] && { echo "Error: IMAGE_NAME is not set"; exit 1; }
[[ -z "${RESOURCE_GROUP}" ]] && { echo "Error: RESOURCE_GROUP is not set"; exit 1; }
[[ -z "${LOCATION}" ]] && { echo "Error: LOCATION is not set"; exit 1; }
[[ -z "${DOCKERFILE_PATH}" ]] && { echo "Error: DOCKERFILE_PATH is not set"; exit 1; }
echo "[$(date)] Variable validation completed."

# Check if Dockerfile exists
echo "[$(date)] Checking if Dockerfile exists at '${DOCKERFILE_PATH}'..."
if [[ ! -f "${DOCKERFILE_PATH}" ]]; then
  echo "Error: Dockerfile not found at '${DOCKERFILE_PATH}'"
  exit 1
fi
echo "[$(date)] Dockerfile found at '${DOCKERFILE_PATH}'."

# Create resource group if it doesn't exist
echo "[$(date)] Checking if resource group '${RESOURCE_GROUP}' exists..."
if az group show --name "${RESOURCE_GROUP}" --output none 2>/dev/null; then
  echo "[$(date)] Resource group '${RESOURCE_GROUP}' already exists."
else
  echo "[$(date)] Creating resource group '${RESOURCE_GROUP}'..."
  az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"
  echo "[$(date)] Resource group creation completed."
fi

# Check if Azure Container Registry exists, create if it doesn't
echo "[$(date)] Checking if Azure Container Registry '${ACR_NAME}' exists..."

# Try to show the ACR and capture both output and error
ACR_CHECK_RESULT=$(az acr show --name "${ACR_NAME}" --output none 2>&1)
ACR_CHECK_EXIT_CODE=$?

if [[ ${ACR_CHECK_EXIT_CODE} -eq 0 ]]; then
  echo "[$(date)] ✅ Azure Container Registry '${ACR_NAME}' already exists. Using existing registry."
elif [[ "${ACR_CHECK_RESULT}" == *"could not be found"* ]] || [[ "${ACR_CHECK_RESULT}" == *"ResourceNotFound"* ]]; then
  echo "[$(date)] Azure Container Registry '${ACR_NAME}' does not exist. Creating new registry..."
  
  # Check if the ACR name is available globally (only when creating new)
  echo "[$(date)] Checking availability of ACR name '${ACR_NAME}'..."
  NAME_AVAILABLE=$(az acr check-name --name "${ACR_NAME}" --query "nameAvailable" --output tsv 2>/dev/null)
  
  if [[ "${NAME_AVAILABLE}" == "true" ]]; then
    echo "[$(date)] ACR name '${ACR_NAME}' is available. Creating Azure Container Registry..."
    az acr create \
      --name "${ACR_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --location "${LOCATION}" \
      --sku Basic \
      --admin-enabled true
    
    if [[ $? -eq 0 ]]; then
      echo "[$(date)] ✅ Azure Container Registry creation completed successfully."
    else
      echo "❌ Error: Failed to create Azure Container Registry"
      exit 1
    fi
  else
    echo "❌ Error: ACR name '${ACR_NAME}' is already taken globally."
    echo "The DNS name '${ACR_NAME}.azurecr.io' is already in use."
    echo "Please choose a different ACR_NAME in the script configuration."
    
    # Suggest alternative names
    echo "[$(date)] Suggested alternative names:"
    for i in {1..5}; do
      SUGGESTED_NAME="${ACR_NAME}${i}"
      SUGGESTED_AVAILABLE=$(az acr check-name --name "${SUGGESTED_NAME}" --query "nameAvailable" --output tsv 2>/dev/null)
      if [[ "${SUGGESTED_AVAILABLE}" == "true" ]]; then
        echo "  ✅ ${SUGGESTED_NAME} (available)"
      else
        echo "  ❌ ${SUGGESTED_NAME} (taken)"
      fi
    done
    
    # Generate a unique name with timestamp
    TIMESTAMP=$(date +%Y%m%d%H%M)
    UNIQUE_NAME="${ACR_NAME}${TIMESTAMP}"
    UNIQUE_AVAILABLE=$(az acr check-name --name "${UNIQUE_NAME}" --query "nameAvailable" --output tsv 2>/dev/null)
    if [[ "${UNIQUE_AVAILABLE}" == "true" ]]; then
      echo "  ✅ ${UNIQUE_NAME} (available with timestamp)"
    fi
    
    exit 1
  fi
else
  echo "❌ Error: Failed to check ACR existence. Error details:"
  echo "${ACR_CHECK_RESULT}"
  echo "This could be due to permission issues or network connectivity."
  exit 1
fi

# Login to Azure Container Registry
echo "[$(date)] Logging into Azure Container Registry '${ACR_NAME}'..."
az acr login --name "${ACR_NAME}"
if [[ $? -eq 0 ]]; then
  echo "[$(date)] Successfully logged into ACR."
else
  echo "Error: Failed to login to Azure Container Registry"
  exit 1
fi

# Build the Docker image and push it to Azure Container Registry
echo "[$(date)] Building and pushing Docker image '${IMAGE_NAME}:latest' to ACR using '${DOCKERFILE_PATH}'..."
az acr build \
  --registry "${ACR_NAME}" \
  --image "${IMAGE_NAME}:latest" \
  --file "${DOCKERFILE_PATH}" \
  .

if [[ $? -eq 0 ]]; then
  echo "[$(date)] Docker image build and push completed successfully."
else
  echo "Error: Failed to build and push Docker image"
  exit 1
fi

# Verify the image was pushed successfully
echo "[$(date)] Verifying image '${IMAGE_NAME}:latest' in registry..."
IMAGE_EXISTS=$(az acr repository show \
  --name "${ACR_NAME}" \
  --image "${IMAGE_NAME}:latest" \
  --query "name" \
  --output tsv 2>/dev/null)

if [[ -n "${IMAGE_EXISTS}" ]]; then
  echo "[$(date)] ✅ Image verification successful: '${IMAGE_NAME}:latest' found in registry."
  
  # Show image details
  echo "[$(date)] Image details:"
  az acr repository show \
    --name "${ACR_NAME}" \
    --image "${IMAGE_NAME}:latest" \
    --output table
    
  # Show repository tags
  echo "[$(date)] Available tags for ${IMAGE_NAME}:"
  az acr repository show-tags \
    --name "${ACR_NAME}" \
    --repository "${IMAGE_NAME}" \
    --output table
else
  echo "❌ Error: Image verification failed - '${IMAGE_NAME}:latest' not found in registry"
  exit 1
fi

echo "[$(date)] Script execution completed successfully!"
echo "[$(date)] Image '${ACR_NAME}.azurecr.io/${IMAGE_NAME}:latest' is ready for deployment."
