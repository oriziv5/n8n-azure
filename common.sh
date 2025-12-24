#!/bin/bash

# ==============================================================================
# Common Configuration Variables for n8n on Azure
# ==============================================================================

# --- General Azure Configuration ---
# The Azure region where resources will be created
export LOCATION="northeurope"
# The name of the resource group
export RESOURCE_GROUP="n8n-rg-northeurope-linux"

# --- Container App Environment Configuration ---
# The name of the Container App Environment
export CONTAINER_APP_ENV_NAME="n8n-containerapp-env"
# The name of the Container App itself
export CONTAINER_APP_NAME="my-n8n-app-linux"

# --- Azure Container Registry (ACR) Configuration ---
# The name of your Azure Container Registry (must be globally unique)
export ACR_NAME="n8nacr"
# The name of the image to build and deploy
export IMAGE_NAME="n8n-azure-linux-main"
# Path to the Dockerfile to use for building the image
export DOCKERFILE_PATH="Dockerfile.azurelinux"

# --- Database Configuration ---
# The name of the PostgreSQL server (must be globally unique)
export DB_SERVER_NAME="mypostgress-n8n-db-server2"
# The admin username for the database
export DB_ADMIN_USER="n8n_admin"
# The name of the database to create
export DB_NAME="n8n"

# --- Key Vault Configuration ---
# The name of the Key Vault (must be globally unique)
export KEYVAULT_NAME="n8n-kv"

# --- n8n Application Configuration ---
# The domain name for your n8n instance
export N8N_DOMAIN="your-n8n-domain.com"
# The initial admin username for n8n
export N8N_USERNAME="admin"

# ==============================================================================
# Helper Functions
# ==============================================================================

# Function for timestamped logging
log_message() {
    echo "[$(date)] $1"
}
