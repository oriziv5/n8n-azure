#!/bin/bash
echo "[$(date)] Starting prerequisites check script..."

# List of required Azure providers
REQUIRED_PROVIDERS=(
    "Microsoft.App"
    "Microsoft.OperationalInsights"
    "Microsoft.DBforPostgreSQL"
    "Microsoft.KeyVault"
    "Microsoft.ContainerRegistry"
)

# Function to check and register a provider
check_and_register_provider() {
    local provider=$1
    echo "[$(date)] Checking provider: $provider"
    
    state=$(az provider show --namespace "$provider" --query "registrationState" -o tsv)
    
    if [ "$state" == "Registered" ]; then
        echo "[$(date)] Provider $provider is already registered."
    else
        echo "[$(date)] Provider $provider is in state '$state'. Registering..."
        az provider register --namespace "$provider"
        
        # Wait for registration to complete
        echo "[$(date)] Waiting for registration to complete..."
        while [ "$state" != "Registered" ]; do
            sleep 5
            state=$(az provider show --namespace "$provider" --query "registrationState" -o tsv)
            echo "[$(date)] Current state: $state"
        done
        echo "[$(date)] Provider $provider successfully registered."
    fi
}

# Check if logged in to Azure
echo "[$(date)] Checking Azure login status..."
az account show > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Error: You are not logged in to Azure. Please run 'az login' first."
    exit 1
fi
echo "[$(date)] Azure login verified."

# Loop through providers
for provider in "${REQUIRED_PROVIDERS[@]}"; do
    check_and_register_provider "$provider"
done

echo "[$(date)] All prerequisites checked and registered successfully!"
