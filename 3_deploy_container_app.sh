#!/bin/bash
# Enable debug mode if DEBUG=1 is set
[[ "${DEBUG}" == "1" ]] && set -x

echo "[$(date)] Starting n8n Container App deployment script..."

# Load common configuration
if [[ -f "common.sh" ]]; then
    source ./common.sh
else
    echo "Error: common.sh not found."
    exit 1
fi

# Generated Configuration Variables
ADMIN_PASSWORD=$(openssl rand -base64 32)  # Generate secure password
N8N_ENCRYPTION_KEY=$(openssl rand -base64 32)  # Generate secure key
DB_PASSWORD="${ADMIN_PASSWORD}" # Use generated password for database

# Calculate DB_HOST based on server name
DB_HOST="${DB_SERVER_NAME}.postgres.database.azure.com"

# Validate required variables
echo "[$(date)] Validating required variables..."
[[ -z "${RESOURCE_GROUP}" ]] && { echo "Error: RESOURCE_GROUP is not set"; exit 1; }
[[ -z "${CONTAINER_APP_NAME}" ]] && { echo "Error: CONTAINER_APP_NAME is not set"; exit 1; }
[[ -z "${N8N_ENCRYPTION_KEY}" ]] && { echo "Error: N8N_ENCRYPTION_KEY is not set"; exit 1; }
[[ -z "${DB_SERVER_NAME}" ]] && { echo "Error: DB_SERVER_NAME is not set"; exit 1; }
[[ -z "${DB_HOST}" ]] && { echo "Error: DB_HOST is not set"; exit 1; }
[[ -z "${DB_NAME}" ]] && { echo "Error: DB_NAME is not set"; exit 1; }
[[ -z "${DB_ADMIN_USER}" ]] && { echo "Error: DB_ADMIN_USER is not set"; exit 1; }
[[ -z "${DB_PASSWORD}" ]] && { echo "Error: DB_PASSWORD is not set"; exit 1; }
[[ -z "${N8N_DOMAIN}" ]] && { echo "Error: N8N_DOMAIN is not set"; exit 1; }
[[ -z "${KEYVAULT_NAME}" ]] && { echo "Error: KEYVAULT_NAME is not set"; exit 1; }
[[ -z "${IMAGE_NAME}" ]] && { echo "Error: IMAGE_NAME is not set"; exit 1; }
[[ -z "${CONTAINER_APP_ENV_NAME}" ]] && { echo "Error: CONTAINER_APP_ENV_NAME is not set"; exit 1; }
echo "[$(date)] Variable validation completed."

# Function to check if RBAC role assignment already exists
check_rbac_assignment_exists() {
    local principal_id="$1"
    local role="$2"
    local scope="$3"
    
    log_message "Checking if role '$role' is already assigned to principal '$principal_id'"
    
    local existing_assignment=$(az role assignment list \
        --assignee "$principal_id" \
        --role "$role" \
        --scope "$scope" \
        --query "[0].id" \
        --output tsv 2>/dev/null)
    
    if [[ -n "$existing_assignment" && "$existing_assignment" != "null" ]]; then
        log_message "✅ Role '$role' is already assigned"
        return 0
    else
        log_message "⚠️  Role '$role' is not assigned yet"
        return 1
    fi
}

# Function to assign RBAC role with retry (only if not already assigned)
assign_rbac_role() {
    local principal_id="$1"
    local role="$2"
    local scope="$3"
    local max_attempts=5
    local attempt=1
    
    # First check if the role is already assigned
    if check_rbac_assignment_exists "$principal_id" "$role" "$scope"; then
        log_message "✅ Role '$role' already assigned, skipping assignment"
        return 0
    fi
    
    log_message "Assigning role '$role' to principal '$principal_id' on scope '$scope'"
    
    while [ $attempt -le $max_attempts ]; do
        log_message "RBAC assignment attempt $attempt/$max_attempts"
        
        if az role assignment create \
            --assignee "$principal_id" \
            --role "$role" \
            --scope "$scope" >/dev/null 2>&1; then
            log_message "✓ Successfully assigned role '$role'"
            return 0
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            log_message "✗ Failed to assign role '$role' after $max_attempts attempts"
            return 1
        fi
        
        log_message "Attempt $attempt failed, retrying in 10 seconds..."
        sleep 10
        ((attempt++))
    done
}

# Function to get current user object ID
get_current_user_object_id() {
    local user_id
    user_id=$(az ad signed-in-user show --query id -o tsv 2>/dev/null)
    if [ -z "$user_id" ]; then
        log_message "✗ Could not get current user object ID"
        return 1
    fi
    echo "$user_id"
}

# Function to create secrets in Key Vault with retry
create_keyvault_secret() {
    local keyvault_name="$1"
    local secret_name="$2"
    local secret_value="$3"
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log_message "Creating secret '$secret_name' attempt $attempt/$max_attempts"
        
        if az keyvault secret set \
            --vault-name "$keyvault_name" \
            --name "$secret_name" \
            --value "$secret_value" >/dev/null 2>&1; then
            log_message "✓ Successfully created secret '$secret_name'"
            return 0
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            log_message "✗ Failed to create secret '$secret_name' after $max_attempts attempts"
            return 1
        fi
        
        log_message "Attempt $attempt failed, retrying in 15 seconds..."
        sleep 15
        ((attempt++))
    done
}

# Function to check if a secret exists in Key Vault
check_secret_exists() {
    local keyvault_name="$1"
    local secret_name="$2"
    
    log_message "Checking if secret '$secret_name' exists in Key Vault '$keyvault_name'"
    
    local secret_info=$(az keyvault secret show \
        --vault-name "$keyvault_name" \
        --name "$secret_name" \
        --query "id" \
        --output tsv 2>/dev/null)
    
    if [[ -n "$secret_info" && "$secret_info" != "null" ]]; then
        log_message "✅ Secret '$secret_name' already exists"
        return 0
    else
        log_message "⚠️  Secret '$secret_name' does not exist"
        return 1
    fi
}

# Function to create secret only if it doesn't exist
create_secret_if_not_exists() {
    local keyvault_name="$1"
    local secret_name="$2"
    local secret_value="$3"
    
    if check_secret_exists "$keyvault_name" "$secret_name"; then
        log_message "✅ Secret '$secret_name' already exists, skipping creation"
        return 0
    else
        log_message "Creating new secret '$secret_name'"
        create_keyvault_secret "$keyvault_name" "$secret_name" "$secret_value"
        return $?
    fi
}

# Function to check if a resource exists
check_resource_exists() {
    local resource_type=$1
    local resource_name=$2
    local resource_group=$3
    local additional_args=${4:-""}
    
    echo "[$(date)] Checking if ${resource_type} '${resource_name}' exists..."
    case $resource_type in
        "postgres-server")
            az postgres flexible-server show --name "${resource_name}" --resource-group "${resource_group}" --output none 2>/dev/null
            ;;
        "keyvault")
            az keyvault show --name "${resource_name}" --output none 2>/dev/null
            ;;
        "containerapp")
            az containerapp show --name "${resource_name}" --resource-group "${resource_group}" --output none 2>/dev/null
            ;;
        "containerapp-env")
            az containerapp env show --name "${resource_name}" --resource-group "${resource_group}" --output none 2>/dev/null
            ;;
        "acr")
            az acr show --name "${resource_name}" --output none 2>/dev/null
            ;;
        *)
            echo "Unknown resource type: ${resource_type}"
            return 1
            ;;
    esac
}

# Function to validate Azure resource naming conventions
validate_azure_name() {
    local resource_type=$1
    local name=$2
    
    case $resource_type in
        "postgres-server")
            # PostgreSQL server names: 3-63 chars, lowercase letters, numbers, hyphens only, start/end with alphanumeric
            if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]]; then
                echo "❌ Invalid PostgreSQL server name: '$name'"
                echo "   Must be 3-63 characters, lowercase letters/numbers/hyphens only, start/end with alphanumeric"
                return 1
            fi
            ;;
        "keyvault")
            # Key Vault names: 3-24 chars, alphanumeric and hyphens only, start with letter, end with letter/digit
            if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$ ]]; then
                echo "❌ Invalid Key Vault name: '$name'"
                echo "   Must be 3-24 characters, alphanumeric/hyphens only, start with letter, end with letter/digit"
                return 1
            fi
            ;;
        "containerapp")
            # Container App names: 2-32 chars, lowercase letters, numbers, hyphens only
            if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$ ]]; then
                echo "❌ Invalid Container App name: '$name'"
                echo "   Must be 2-32 characters, lowercase letters/numbers/hyphens only"
                return 1
            fi
            ;;
        "acr")
            # ACR names: 5-50 chars, alphanumeric only
            if [[ ! "$name" =~ ^[a-zA-Z0-9]{5,50}$ ]]; then
                echo "❌ Invalid ACR name: '$name'"
                echo "   Must be 5-50 characters, alphanumeric only"
                return 1
            fi
            ;;
        *)
            echo "Unknown resource type for validation: ${resource_type}"
            return 1
            ;;
    esac
    return 0
}

# Function to check PostgreSQL server name availability (simplified version)
check_postgres_name_availability() {
    local server_name=$1
    
    echo "[$(date)] Checking PostgreSQL server name availability..."
    
    # Check in current subscription across all resource groups
    local existing_servers=$(az postgres flexible-server list \
        --query "[?name=='${server_name}'].{name:name, resourceGroup:resourceGroup, location:location}" \
        --output tsv 2>/dev/null)
    
    if [[ -n "${existing_servers}" ]]; then
        echo "[$(date)] Found existing PostgreSQL server(s) with name '${server_name}' in your subscription:"
        echo "${existing_servers}"
        echo "false"  # Name is NOT available (already exists)
        return 0
    fi
    
    echo "[$(date)] PostgreSQL server name '${server_name}' not found in your subscription"
    echo "true"   # Name appears available in your subscription
    return 0
}

# Validate resource names before proceeding
echo "[$(date)] Validating Azure resource names..."
validate_azure_name "postgres-server" "${DB_SERVER_NAME}" || exit 1
validate_azure_name "keyvault" "${KEYVAULT_NAME}" || exit 1
validate_azure_name "containerapp" "${CONTAINER_APP_NAME}" || exit 1
validate_azure_name "acr" "${ACR_NAME}" || exit 1
echo "[$(date)] ✅ All resource names are valid."

# 1. Check if Container App Environment exists
if check_resource_exists "containerapp-env" "${CONTAINER_APP_ENV_NAME}" "${RESOURCE_GROUP}"; then
    echo "[$(date)] ✅ Container App Environment '${CONTAINER_APP_ENV_NAME}' already exists."
else
    echo "❌ Error: Container App Environment '${CONTAINER_APP_ENV_NAME}' does not exist."
    echo "Please run script 1_create_workload_profile.sh first to create the environment."
    exit 1
fi

# 2. Check if ACR exists and verify image
if check_resource_exists "acr" "${ACR_NAME}" ""; then
    echo "[$(date)] ✅ Azure Container Registry '${ACR_NAME}' exists."
    
    # Verify the image exists in ACR
    echo "[$(date)] Verifying image '${IMAGE_NAME}:latest' exists in ACR..."
    IMAGE_EXISTS=$(az acr repository show \
        --name "${ACR_NAME}" \
        --image "${IMAGE_NAME}:latest" \
        --query "name" \
        --output tsv 2>/dev/null)
    
    if [[ -n "${IMAGE_EXISTS}" ]]; then
        echo "[$(date)] ✅ Image '${IMAGE_NAME}:latest' found in registry."
    else
        echo "❌ Error: Image '${IMAGE_NAME}:latest' not found in ACR."
        echo "Please run script 2_build_image.sh first to build and push the image."
        exit 1
    fi
else
    echo "❌ Error: Azure Container Registry '${ACR_NAME}' does not exist."
    echo "Please run script 2_build_image.sh first to create the ACR and build the image."
    exit 1
fi

# 3. Create PostgreSQL Flexible Server if it doesn't exist
echo "[$(date)] === PostgreSQL Flexible Server Setup ==="

# First, check if the server already exists in our resource group
echo "[$(date)] Checking if PostgreSQL server '${DB_SERVER_NAME}' exists in resource group '${RESOURCE_GROUP}'..."
if check_resource_exists "postgres-server" "${DB_SERVER_NAME}" "${RESOURCE_GROUP}"; then
    echo "[$(date)] ✅ PostgreSQL Flexible Server '${DB_SERVER_NAME}' already exists in resource group. Skipping creation."
else
    echo "[$(date)] PostgreSQL server not found in resource group. Proceeding with creation process..."
    
    # Check global name availability before attempting creation
    echo "[$(date)] Checking global availability of PostgreSQL server name '${DB_SERVER_NAME}'..."
    
    # Method 1: Check in current subscription first
    echo "[$(date)] Step 1: Checking current subscription for existing servers..."
    EXISTING_IN_SUBSCRIPTION=$(az postgres flexible-server list \
        --query "[?name=='${DB_SERVER_NAME}'].{name:name, resourceGroup:resourceGroup, location:location}" \
        --output tsv 2>/dev/null)
    
    if [[ -n "${EXISTING_IN_SUBSCRIPTION}" ]]; then
        echo "❌ Error: PostgreSQL server '${DB_SERVER_NAME}' already exists in your subscription!"
        echo "Existing server details:"
        echo "${EXISTING_IN_SUBSCRIPTION}"
        echo ""
        echo "💡 Please choose a different DB_SERVER_NAME or use the existing server."
        
        # Generate alternative suggestions
        echo "[$(date)] Suggested alternative names:"
        TIMESTAMP=$(date +%Y%m%d%H%M%S)
        echo "   • ${DB_SERVER_NAME}-new"
        echo "   • ${DB_SERVER_NAME}-${TIMESTAMP}"
        echo "   • ${DB_SERVER_NAME}-$(whoami)"
        echo "   • $(echo ${DB_SERVER_NAME} | sed 's/-db-server//')-v2-db-server"
        
        exit 1
    fi
    
    # Method 2: Try global availability check
    echo "[$(date)] Step 2: Checking global name availability..."
    GLOBAL_AVAILABILITY=""
    GLOBAL_CHECK_OUTPUT=$(az postgres flexible-server check-name-availability \
        --name "${DB_SERVER_NAME}" \
        --type "Microsoft.DBforPostgreSQL/flexibleServers" \
        --output json 2>/dev/null)
    
    GLOBAL_CHECK_EXIT_CODE=$?
    
    if [[ ${GLOBAL_CHECK_EXIT_CODE} -eq 0 ]] && [[ -n "${GLOBAL_CHECK_OUTPUT}" ]]; then
        GLOBAL_AVAILABILITY=$(echo "${GLOBAL_CHECK_OUTPUT}" | grep -o '"nameAvailable":[^,]*' | cut -d':' -f2 | tr -d ' "')
        
        if [[ "${GLOBAL_AVAILABILITY}" == "false" ]]; then
            echo "❌ Error: PostgreSQL server name '${DB_SERVER_NAME}' is globally unavailable!"
            echo "This name is already taken by another Azure user/subscription worldwide."
            echo ""
            echo "💡 PostgreSQL server names must be globally unique across all Azure subscriptions."
            echo ""
            echo "Suggested globally unique alternatives:"
            TIMESTAMP=$(date +%Y%m%d%H%M%S)
            UNIQUE_SUFFIX=$(openssl rand -hex 4)
            echo "   • ${DB_SERVER_NAME}-${TIMESTAMP}"
            echo "   • ${DB_SERVER_NAME}-${UNIQUE_SUFFIX}"
            echo "   • $(whoami)-${DB_SERVER_NAME}"
            echo "   • ${DB_SERVER_NAME}-$(echo $RANDOM | md5sum | head -c 6)"
            
            exit 1
        elif [[ "${GLOBAL_AVAILABILITY}" == "true" ]]; then
            echo "[$(date)] ✅ Global availability check passed. Name appears to be available worldwide."
        fi
    else
        echo "[$(date)] ⚠️  Global availability check failed or unavailable. Will proceed with creation attempt."
        echo "[$(date)] Note: If name is globally taken, creation will fail with clear error message."
    fi
    
    # Method 3: Proceed with server creation
    echo "[$(date)] Step 3: Creating PostgreSQL Flexible Server with minimum cost configuration..."
    echo "[$(date)] Configuration: Standard_B1ms (Burstable), 32GB storage, PostgreSQL 14"
    
    CREATE_OUTPUT=$(az postgres flexible-server create \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${DB_SERVER_NAME}" \
        --location "${LOCATION}" \
        --admin-user "${DB_ADMIN_USER}" \
        --admin-password "${DB_PASSWORD}" \
        --sku-name Standard_B1ms \
        --tier Burstable \
        --storage-size 32 \
        --version 14 \
        --backup-retention 7 \
        --geo-redundant-backup Disabled \
        --high-availability Disabled \
        --public-access 0.0.0.0 \
        --yes 2>&1)
    
    CREATE_EXIT_CODE=$?
    
    if [[ ${CREATE_EXIT_CODE} -eq 0 ]]; then
        echo "[$(date)] ✅ PostgreSQL Flexible Server created successfully!"
        echo "[$(date)] Server details:"
        echo "   • Name: ${DB_SERVER_NAME}"
        echo "   • SKU: Standard_B1ms (Burstable tier)"
        echo "   • Storage: 32GB"
        echo "   • Version: PostgreSQL 14"
        echo "   • Backup retention: 7 days"
        echo "   • High availability: Disabled (cost-optimized)"
        echo "   • Public access: Enabled (0.0.0.0 - configure firewall rules as needed)"
    else
        echo "❌ Error: Failed to create PostgreSQL Flexible Server!"
        echo ""
        echo "Error details:"
        echo "${CREATE_OUTPUT}"
        echo ""
        
        # Analyze the error and provide specific guidance
        if echo "${CREATE_OUTPUT}" | grep -q -i "name.*not.*available\|already.*exists\|conflict"; then
            echo "🔍 Analysis: This appears to be a naming conflict error."
            echo "💡 The server name '${DB_SERVER_NAME}' is already taken globally."
            echo ""
            echo "Suggested solutions:"
            TIMESTAMP=$(date +%Y%m%d%H%M%S)
            UNIQUE_SUFFIX=$(openssl rand -hex 4)
            echo "   1. Use a more unique name:"
            echo "      • ${DB_SERVER_NAME}-${TIMESTAMP}"
            echo "      • ${DB_SERVER_NAME}-${UNIQUE_SUFFIX}"
            echo "      • $(whoami)-${DB_SERVER_NAME}"
            echo ""
            echo "   2. Update the DB_SERVER_NAME variable in the script"
            echo "   3. Re-run this script"
        elif echo "${CREATE_OUTPUT}" | grep -q -i "quota\|limit"; then
            echo "🔍 Analysis: This appears to be a quota/limit error."
            echo "💡 You may have reached your subscription limits for PostgreSQL servers."
            echo ""
            echo "Suggested solutions:"
            echo "   1. Check your Azure subscription quota"
            echo "   2. Delete unused PostgreSQL servers"
            echo "   3. Contact Azure support to increase quota"
        elif echo "${CREATE_OUTPUT}" | grep -q -i "permission\|authorized\|access"; then
            echo "🔍 Analysis: This appears to be a permissions error."
            echo "💡 You may not have sufficient permissions in this subscription/resource group."
            echo ""
            echo "Suggested solutions:"
            echo "   1. Ensure you have 'Contributor' role on the resource group"
            echo "   2. Ensure you have 'PostgreSQL Flexible Server Contributor' role"
            echo "   3. Contact your Azure administrator"
        else
            echo "🔍 Analysis: Unexpected error occurred."
            echo "💡 Please review the error details above and try again."
        fi
        
        exit 1
    fi
fi

# 4. Create database if it doesn't exist
echo "[$(date)] Creating database '${DB_NAME}' if it doesn't exist..."
az postgres flexible-server db create \
    --resource-group "${RESOURCE_GROUP}" \
    --server-name "${DB_SERVER_NAME}" \
    --location "${LOCATION}" \
    --database-name "${DB_NAME}" 2>/dev/null || echo "[$(date)] Database may already exist, continuing..."

# 5. Create Key Vault if it doesn't exist
if check_resource_exists "keyvault" "${KEYVAULT_NAME}" ""; then
    echo "[$(date)] ✅ Key Vault '${KEYVAULT_NAME}' already exists. Skipping creation."
else
    echo "[$(date)] Creating Key Vault '${KEYVAULT_NAME}'..."
    az keyvault create \
        --name "${KEYVAULT_NAME}" \
        --resource-group "${RESOURCE_GROUP}" \
        --location "${LOCATION}" \
        --sku standard \
        --enable-rbac-authorization true
    
    if [[ $? -eq 0 ]]; then
        echo "[$(date)] ✅ Key Vault creation completed successfully."
    else
        echo "❌ Error: Failed to create Key Vault"
        exit 1
    fi
fi

# 6. Grant current user Key Vault Secrets Officer role for secret management
log_message "Setting up Key Vault RBAC permissions for current user..."
KEYVAULT_RESOURCE_ID=$(az keyvault show --name "${KEYVAULT_NAME}" --query "id" --output tsv)

CURRENT_USER_ID=$(get_current_user_object_id)
if [[ -n "${CURRENT_USER_ID}" ]]; then
    log_message "Current user ID retrieved: ${CURRENT_USER_ID}"
    
    # Use the new RBAC function with retry logic
    if assign_rbac_role "${CURRENT_USER_ID}" "Key Vault Secrets Officer" "${KEYVAULT_RESOURCE_ID}"; then
        log_message "✅ Key Vault Secrets Officer role assigned successfully"
    else
        log_message "❌ Failed to assign Key Vault Secrets Officer role"
        exit 1
    fi
    
    # Wait for RBAC to propagate
    log_message "Waiting for RBAC permissions to propagate..."
    sleep 15
else
    log_message "⚠️  Warning: Could not get current user ID. You may need to manually grant Key Vault permissions."
    exit 1
fi

# 7. Store sensitive information in Key Vault
log_message "Storing sensitive information in Key Vault..."

# Set secrets using the new function with retry logic
create_keyvault_secret "${KEYVAULT_NAME}" "N8N-Encryption-Key" "${N8N_ENCRYPTION_KEY}" || exit 1
create_keyvault_secret "${KEYVAULT_NAME}" "N8N-DB-Password" "${DB_PASSWORD}" || exit 1
create_keyvault_secret "${KEYVAULT_NAME}" "N8N-Admin-Password" "${ADMIN_PASSWORD}" || exit 1

log_message "✅ All secrets stored in Key Vault successfully."

# 8. Handle Container App creation or update
CONTAINER_APP_EXISTS=false
if check_resource_exists "containerapp" "${CONTAINER_APP_NAME}" "${RESOURCE_GROUP}"; then
    echo "[$(date)] ✅ Container App '${CONTAINER_APP_NAME}' already exists."
    CONTAINER_APP_EXISTS=true
else
    echo "[$(date)] Creating Container App '${CONTAINER_APP_NAME}' with managed identity authentication..."
    
    # Step 1: Create Container App with a public image first (to avoid authentication issues)
    log_message "Creating Container App with temporary public image..."
    az containerapp create \
        --name "${CONTAINER_APP_NAME}" \
        --resource-group "${RESOURCE_GROUP}" \
        --environment "${CONTAINER_APP_ENV_NAME}" \
        --image "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest" \
        --cpu 2.0 \
        --memory 4Gi \
        --ingress external \
        --target-port 80 \
        --min-replicas 1 \
        --max-replicas 3 \
        --system-assigned \
        --output none
    
    if [[ $? -eq 0 ]]; then
        log_message "✅ Container App created successfully with temporary image"
        
        # Step 2: Get the managed identity principal ID with retry logic
        log_message "Retrieving managed identity principal ID..."
        PRINCIPAL_ID=""
        for attempt in {1..10}; do
            PRINCIPAL_ID=$(az containerapp show \
                --name "${CONTAINER_APP_NAME}" \
                --resource-group "${RESOURCE_GROUP}" \
                --query "identity.principalId" \
                --output tsv 2>/dev/null)
            
            if [[ -n "${PRINCIPAL_ID}" ]] && [[ "${PRINCIPAL_ID}" != "null" ]]; then
                log_message "✅ Container App principal ID retrieved: ${PRINCIPAL_ID}"
                break
            else
                log_message "⚠️  Managed identity not ready yet (attempt ${attempt}/10)"
                if [[ ${attempt} -lt 10 ]]; then
                    sleep 10
                fi
            fi
        done
        
        if [[ -z "${PRINCIPAL_ID}" ]] || [[ "${PRINCIPAL_ID}" == "null" ]]; then
            log_message "❌ Error: Failed to retrieve managed identity principal ID"
            exit 1
        fi
        
        # Step 3: Get ACR information and verify connectivity
        log_message "Retrieving ACR information..."
        ACR_RESOURCE_ID=$(az acr show --name "${ACR_NAME}" --query "id" --output tsv)
        ACR_LOGIN_SERVER=$(az acr show --name "${ACR_NAME}" --query "loginServer" --output tsv)
        ACR_LOCATION=$(az acr show --name "${ACR_NAME}" --query "location" --output tsv)
        
        log_message "ACR Details:"
        log_message "  • Registry: ${ACR_LOGIN_SERVER}"
        log_message "  • Location: ${ACR_LOCATION}"
        log_message "  • Resource ID: ${ACR_RESOURCE_ID}"
        
        # Verify the image exists in ACR
        log_message "Verifying image exists in ACR..."
        if ! az acr repository show --name "${ACR_NAME}" --repository "${IMAGE_NAME}" --output none 2>/dev/null; then
            log_message "❌ Error: Image '${IMAGE_NAME}' not found in ACR '${ACR_NAME}'"
            log_message "💡 Please run script 2_build_image.sh first to build and push the image"
            exit 1
        fi
        log_message "✅ Image verified in ACR"
        
        # Step 4: Grant ACR pull access to Container App managed identity
        log_message "Granting AcrPull role to Container App managed identity..."
        
        if assign_rbac_role "${PRINCIPAL_ID}" "AcrPull" "${ACR_RESOURCE_ID}"; then
            log_message "✅ AcrPull role assigned successfully"
            
            # Step 5: Configure Container App registry authentication explicitly
            log_message "Configuring Container App registry authentication..."
            
            # First, configure the registry with managed identity
            if az containerapp registry set \
                --name "${CONTAINER_APP_NAME}" \
                --resource-group "${RESOURCE_GROUP}" \
                --server "${ACR_LOGIN_SERVER}" \
                --identity "system" \
                --output none 2>/dev/null; then
                log_message "✅ Registry authentication configured successfully"
            else
                log_message "⚠️  Registry authentication configuration failed, will retry after RBAC propagation"
            fi
            
            # Step 6: Enhanced RBAC propagation wait with verification
            log_message "Waiting for RBAC permissions to propagate..."
            log_message "Note: ACR authentication via managed identity may take up to 3 minutes to propagate"
            
            # Progressive wait with verification
            for wait_time in 30 45 60 45; do
                sleep ${wait_time}
                
                # Test ACR access using managed identity
                log_message "Testing ACR access with managed identity..."
                
                # Try to configure registry again (this tests the connection)
                if az containerapp registry set \
                    --name "${CONTAINER_APP_NAME}" \
                    --resource-group "${RESOURCE_GROUP}" \
                    --server "${ACR_LOGIN_SERVER}" \
                    --identity "system" \
                    --output none 2>/dev/null; then
                    log_message "✅ Registry authentication test successful"
                    break
                else
                    log_message "⚠️  Registry authentication not ready yet, continuing to wait..."
                fi
            done
            
            # Step 7: Update Container App with the actual image
            log_message "Updating Container App with n8n image from ACR..."
            
            # Method 1: Try container update with registry configuration
            UPDATE_SUCCESS=false
            
            # Attempt 1: Update with explicit registry configuration
            log_message "Attempt 1: Updating with explicit registry configuration..."
            if az containerapp update \
                --name "${CONTAINER_APP_NAME}" \
                --resource-group "${RESOURCE_GROUP}" \
                --image "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:latest" \
                --output none 2>/dev/null; then
                UPDATE_SUCCESS=true
                log_message "✅ Container App updated successfully (Method 1)"
            else
                log_message "⚠️  Method 1 failed, trying alternative approach..."
                
                # Attempt 2: Re-configure registry then update
                log_message "Attempt 2: Re-configuring registry authentication..."
                az containerapp registry set \
                    --name "${CONTAINER_APP_NAME}" \
                    --resource-group "${RESOURCE_GROUP}" \
                    --server "${ACR_LOGIN_SERVER}" \
                    --identity "system" \
                    --output none 2>/dev/null
                
                sleep 30
                
                if az containerapp update \
                    --name "${CONTAINER_APP_NAME}" \
                    --resource-group "${RESOURCE_GROUP}" \
                    --image "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:latest" \
                    --output none 2>/dev/null; then
                    UPDATE_SUCCESS=true
                    log_message "✅ Container App updated successfully (Method 2)"
                else
                    log_message "⚠️  Method 2 failed, trying final approach..."
                    
                    # Attempt 3: Use admin credentials as fallback (temporary)
                    log_message "Attempt 3: Using admin credentials as fallback..."
                    
                    # Enable admin user temporarily
                    az acr update --name "${ACR_NAME}" --admin-enabled true --output none
                    
                    # Get admin credentials
                    ACR_USERNAME=$(az acr credential show --name "${ACR_NAME}" --query "username" --output tsv)
                    ACR_PASSWORD=$(az acr credential show --name "${ACR_NAME}" --query "passwords[0].value" --output tsv)
                    
                    # Configure with admin credentials
                    if az containerapp registry set \
                        --name "${CONTAINER_APP_NAME}" \
                        --resource-group "${RESOURCE_GROUP}" \
                        --server "${ACR_LOGIN_SERVER}" \
                        --username "${ACR_USERNAME}" \
                        --password "${ACR_PASSWORD}" \
                        --output none; then
                        
                        if az containerapp update \
                            --name "${CONTAINER_APP_NAME}" \
                            --resource-group "${RESOURCE_GROUP}" \
                            --image "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:latest" \
                            --output none; then
                            UPDATE_SUCCESS=true
                            log_message "✅ Container App updated successfully (Method 3 - Admin Credentials)"
                            log_message "⚠️  Note: Admin credentials used as fallback - consider switching back to managed identity"
                        fi
                    fi
                fi
            fi
            
            # Update ingress configuration for n8n (port 5678)
            log_message "Updating ingress configuration for n8n (port 5678)..."
            az containerapp ingress update \
                --name "${CONTAINER_APP_NAME}" \
                --resource-group "${RESOURCE_GROUP}" \
                --target-port 5678 \
                --output none
            
            INGRESS_UPDATE_RESULT=$?
            
            if [[ "$UPDATE_SUCCESS" == "true" && $INGRESS_UPDATE_RESULT -eq 0 ]]; then
                log_message "✅ Container App updated with n8n image successfully"
            else
                log_message "❌ Failed to update Container App"
                
                # Provide detailed troubleshooting information
                log_message "🔍 Troubleshooting Information:"
                log_message "  • Container App: ${CONTAINER_APP_NAME}"
                log_message "  • Resource Group: ${RESOURCE_GROUP}"
                log_message "  • ACR: ${ACR_LOGIN_SERVER}"
                log_message "  • Image: ${IMAGE_NAME}:latest"
                log_message "  • Principal ID: ${PRINCIPAL_ID}"
                
                # Check current Container App status
                log_message "Checking Container App status..."
                CURRENT_IMAGE=$(az containerapp show \
                    --name "${CONTAINER_APP_NAME}" \
                    --resource-group "${RESOURCE_GROUP}" \
                    --query "properties.template.containers[0].image" \
                    --output tsv)
                log_message "  • Current Image: ${CURRENT_IMAGE}"
                
                # Check registry configuration
                log_message "Checking registry configuration..."
                REGISTRY_CONFIG=$(az containerapp show \
                    --name "${CONTAINER_APP_NAME}" \
                    --resource-group "${RESOURCE_GROUP}" \
                    --query "properties.configuration.registries" \
                    --output table)
                log_message "  • Registry Config: ${REGISTRY_CONFIG}"
                
                # Suggest manual steps
                echo ""
                echo "🛠️  Manual Troubleshooting Steps:"
                echo "   1. Check ACR connectivity:"
                echo "      az acr login --name ${ACR_NAME}"
                echo "      docker pull ${ACR_LOGIN_SERVER}/${IMAGE_NAME}:latest"
                echo ""
                echo "   2. Verify RBAC assignment:"
                echo "      az role assignment list --assignee ${PRINCIPAL_ID} --scope ${ACR_RESOURCE_ID}"
                echo ""
                echo "   3. Test managed identity ACR access:"
                echo "      az containerapp registry set --name ${CONTAINER_APP_NAME} --resource-group ${RESOURCE_GROUP} --server ${ACR_LOGIN_SERVER} --identity system"
                echo ""
                echo "   4. Alternative: Use admin credentials (not recommended for production):"
                echo "      az acr update --name ${ACR_NAME} --admin-enabled true"
                echo "      # Then configure with admin credentials"
                echo ""
                
                if [[ $INGRESS_UPDATE_RESULT -ne 0 ]]; then
                    log_message "❌ Ingress update also failed"
                fi
                
                exit 1
            fi
        else
            log_message "❌ Failed to assign AcrPull role"
            exit 1
        fi
    else
        log_message "❌ Error: Failed to create Container App"
        exit 1
    fi
fi

# 9. Get Container App managed identity principal ID (for existing apps or verification)
if [[ "$CONTAINER_APP_EXISTS" = true ]]; then
    echo "[$(date)] Retrieving Container App managed identity for existing app..."
    
    # First, ensure system-assigned managed identity is enabled
    log_message "Checking if system-assigned managed identity is enabled..."
    IDENTITY_TYPE=$(az containerapp show \
        --name "${CONTAINER_APP_NAME}" \
        --resource-group "${RESOURCE_GROUP}" \
        --query "identity.type" \
        --output tsv 2>/dev/null)
    
    if [[ "${IDENTITY_TYPE}" != "SystemAssigned" ]]; then
        log_message "⚠️  System-assigned managed identity not enabled. Enabling now..."
        az containerapp identity assign \
            --name "${CONTAINER_APP_NAME}" \
            --resource-group "${RESOURCE_GROUP}" \
            --system-assigned \
            --output none
        
        if [[ $? -eq 0 ]]; then
            log_message "✅ System-assigned managed identity enabled successfully"
        else
            log_message "❌ Failed to enable system-assigned managed identity"
            exit 1
        fi
    else
        log_message "✅ System-assigned managed identity already enabled"
    fi
    
    get_principal_id_with_retry() {
        local max_attempts=10
        local attempt=1
        
        while [[ ${attempt} -le ${max_attempts} ]]; do
            echo "[$(date)] Attempt ${attempt}/${max_attempts}: Getting managed identity principal ID..."
            
            PRINCIPAL_ID=$(az containerapp show \
                --name "${CONTAINER_APP_NAME}" \
                --resource-group "${RESOURCE_GROUP}" \
                --query "identity.principalId" \
                --output tsv 2>/dev/null)
            
            if [[ -n "${PRINCIPAL_ID}" ]] && [[ "${PRINCIPAL_ID}" != "null" ]] && [[ "${PRINCIPAL_ID}" != "" ]]; then
                echo "[$(date)] ✅ Container App principal ID retrieved: ${PRINCIPAL_ID}"
                return 0
            else
                echo "[$(date)] ⚠️  Managed identity not ready yet (attempt ${attempt}/${max_attempts})"
                if [[ ${attempt} -lt ${max_attempts} ]]; then
                    echo "[$(date)] Waiting 15 seconds for managed identity to propagate..."
                    sleep 15
                fi
            fi
            
            ((attempt++))
        done
        
        echo "❌ Error: Failed to retrieve managed identity principal ID after ${max_attempts} attempts"
        return 1
    }
    
    get_principal_id_with_retry || exit 1
else
    echo "[$(date)] ✅ Managed identity already configured for new Container App"
fi

# 10. Verify ACR pull access for existing Container Apps
if [[ "$CONTAINER_APP_EXISTS" = true ]]; then
    log_message "Verifying ACR access for existing Container App..."
    
    # Get ACR information for existing apps
    ACR_RESOURCE_ID=$(az acr show --name "${ACR_NAME}" --query "id" --output tsv)
    ACR_LOGIN_SERVER=$(az acr show --name "${ACR_NAME}" --query "loginServer" --output tsv)
    ACR_LOCATION=$(az acr show --name "${ACR_NAME}" --query "location" --output tsv)
    
    log_message "ACR Details for existing Container App:"
    log_message "  • Registry: ${ACR_LOGIN_SERVER}"
    log_message "  • Location: ${ACR_LOCATION}"
    log_message "  • Resource ID: ${ACR_RESOURCE_ID}"
    
    # Verify the image exists in ACR
    log_message "Verifying image exists in ACR..."
    if ! az acr repository show --name "${ACR_NAME}" --repository "${IMAGE_NAME}" --output none 2>/dev/null; then
        log_message "❌ Error: Image '${IMAGE_NAME}' not found in ACR '${ACR_NAME}'"
        log_message "💡 Please run script 2_build_image.sh first to build and push the image"
        exit 1
    fi
    log_message "✅ Image verified in ACR"
    
    if check_rbac_assignment_exists "${PRINCIPAL_ID}" "AcrPull" "${ACR_RESOURCE_ID}"; then
        log_message "✅ AcrPull role already properly assigned"
        
        # Configure registry authentication explicitly before updating image
        log_message "Configuring registry authentication for existing Container App..."
        if az containerapp registry set \
            --name "${CONTAINER_APP_NAME}" \
            --resource-group "${RESOURCE_GROUP}" \
            --server "${ACR_LOGIN_SERVER}" \
            --identity "system" \
            --output none 2>/dev/null; then
            log_message "✅ Registry authentication configured successfully"
        else
            log_message "⚠️  Registry authentication configuration failed, will retry"
            sleep 30
            
            # Retry registry configuration
            if az containerapp registry set \
                --name "${CONTAINER_APP_NAME}" \
                --resource-group "${RESOURCE_GROUP}" \
                --server "${ACR_LOGIN_SERVER}" \
                --identity "system" \
                --output none 2>/dev/null; then
                log_message "✅ Registry authentication configured successfully on retry"
            else
                log_message "❌ Failed to configure registry authentication"
                exit 1
            fi
        fi
        
        # Update Container App image to ensure it's using the latest version
        log_message "Updating Container App image to latest version..."
        az containerapp update \
            --name "${CONTAINER_APP_NAME}" \
            --resource-group "${RESOURCE_GROUP}" \
            --image "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:latest" \
            --output none
        
        IMAGE_UPDATE_RESULT=$?
        
        # Update ingress configuration for n8n (port 5678)
        log_message "Updating ingress configuration for n8n (port 5678)..."
        az containerapp ingress update \
            --name "${CONTAINER_APP_NAME}" \
            --resource-group "${RESOURCE_GROUP}" \
            --target-port 5678 \
            --output none
        
        INGRESS_UPDATE_RESULT=$?
        
        if [[ $IMAGE_UPDATE_RESULT -eq 0 && $INGRESS_UPDATE_RESULT -eq 0 ]]; then
            log_message "✅ Container App image updated successfully"
        else
            if [[ $IMAGE_UPDATE_RESULT -ne 0 ]]; then
                log_message "❌ Failed to update Container App image - ACR authentication issue"
                log_message "🔧 Attempting fallback with admin credentials..."
                
                # Enable admin credentials as fallback
                az acr update --name "${ACR_NAME}" --admin-enabled true --output none
                
                # Get admin credentials
                ACR_USERNAME=$(az acr credential show --name "${ACR_NAME}" --query "username" --output tsv)
                ACR_PASSWORD=$(az acr credential show --name "${ACR_NAME}" --query "passwords[0].value" --output tsv)
                
                # Configure with admin credentials
                if az containerapp registry set \
                    --name "${CONTAINER_APP_NAME}" \
                    --resource-group "${RESOURCE_GROUP}" \
                    --server "${ACR_LOGIN_SERVER}" \
                    --username "${ACR_USERNAME}" \
                    --password "${ACR_PASSWORD}" \
                    --output none; then
                    
                    # Try updating image again with admin credentials
                    if az containerapp update \
                        --name "${CONTAINER_APP_NAME}" \
                        --resource-group "${RESOURCE_GROUP}" \
                        --image "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:latest" \
                        --output none; then
                        log_message "✅ Container App updated successfully with admin credentials"
                        log_message "⚠️  Note: Admin credentials used as fallback"
                    else
                        log_message "❌ Failed to update Container App even with admin credentials"
                        exit 1
                    fi
                else
                    log_message "❌ Failed to configure admin credentials"
                    exit 1
                fi
            fi
            if [[ $INGRESS_UPDATE_RESULT -ne 0 ]]; then
                log_message "❌ Failed to update ingress configuration"
            fi
        fi
    else
        log_message "⚠️  AcrPull role not found, assigning now..."
        if assign_rbac_role "${PRINCIPAL_ID}" "AcrPull" "${ACR_RESOURCE_ID}"; then
            log_message "✅ AcrPull role assigned successfully"
            
            # Wait for RBAC to propagate
            log_message "Waiting for RBAC permissions to propagate..."
            sleep 60
            
            # Configure registry authentication explicitly
            log_message "Configuring registry authentication..."
            if az containerapp registry set \
                --name "${CONTAINER_APP_NAME}" \
                --resource-group "${RESOURCE_GROUP}" \
                --server "${ACR_LOGIN_SERVER}" \
                --identity "system" \
                --output none; then
                log_message "✅ Registry authentication configured successfully"
            else
                log_message "⚠️  Registry authentication configuration failed"
            fi
            
            # Update Container App with the ACR image
            log_message "Updating Container App with n8n image from ACR..."
            az containerapp update \
                --name "${CONTAINER_APP_NAME}" \
                --resource-group "${RESOURCE_GROUP}" \
                --image "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:latest" \
                --output none
            
            IMAGE_UPDATE_RESULT=$?
            
            # Update ingress configuration for n8n (port 5678)
            log_message "Updating ingress configuration for n8n (port 5678)..."
            az containerapp ingress update \
                --name "${CONTAINER_APP_NAME}" \
                --resource-group "${RESOURCE_GROUP}" \
                --target-port 5678 \
                --output none
            
            INGRESS_UPDATE_RESULT=$?
            
            if [[ $IMAGE_UPDATE_RESULT -eq 0 && $INGRESS_UPDATE_RESULT -eq 0 ]]; then
                log_message "✅ Container App updated with n8n image successfully"
            else
                if [[ $IMAGE_UPDATE_RESULT -ne 0 ]]; then
                    log_message "❌ Failed to update Container App image - ACR authentication issue"
                    log_message "🔧 Attempting fallback with admin credentials..."
                    
                    # Enable admin credentials as fallback
                    az acr update --name "${ACR_NAME}" --admin-enabled true --output none
                    
                    # Get admin credentials
                    ACR_USERNAME=$(az acr credential show --name "${ACR_NAME}" --query "username" --output tsv)
                    ACR_PASSWORD=$(az acr credential show --name "${ACR_NAME}" --query "passwords[0].value" --output tsv)
                    
                    # Configure with admin credentials
                    if az containerapp registry set \
                        --name "${CONTAINER_APP_NAME}" \
                        --resource-group "${RESOURCE_GROUP}" \
                        --server "${ACR_LOGIN_SERVER}" \
                        --username "${ACR_USERNAME}" \
                        --password "${ACR_PASSWORD}" \
                        --output none; then
                        
                        # Try updating image again with admin credentials
                        if az containerapp update \
                            --name "${CONTAINER_APP_NAME}" \
                            --resource-group "${RESOURCE_GROUP}" \
                            --image "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:latest" \
                            --output none; then
                            log_message "✅ Container App updated successfully with admin credentials"
                            log_message "⚠️  Note: Admin credentials used as fallback"
                        else
                            log_message "❌ Failed to update Container App even with admin credentials"
                            exit 1
                        fi
                    else
                        log_message "❌ Failed to configure admin credentials"
                        exit 1
                    fi
                fi
                if [[ $INGRESS_UPDATE_RESULT -ne 0 ]]; then
                    log_message "❌ Failed to update ingress configuration"
                fi
            fi
        else
            log_message "❌ Failed to assign AcrPull role"
            exit 1
        fi
    fi
else
    log_message "✅ ACR access already configured for new Container App during creation"
fi

# 11. Grant Key Vault access to Container App managed identity (only for new apps)
if [[ "$CONTAINER_APP_EXISTS" = false ]]; then
    log_message "Granting Key Vault Secrets User role to Container App managed identity..."
    if assign_rbac_role "${PRINCIPAL_ID}" "Key Vault Secrets User" "${KEYVAULT_RESOURCE_ID}"; then
        log_message "✅ Key Vault Secrets User role assigned successfully"
    else
        log_message "❌ Failed to assign Key Vault Secrets User role"
        exit 1
    fi
    
    # Wait for RBAC to fully propagate for new apps
    log_message "Waiting for RBAC permissions to fully propagate..."
    sleep 30
else
    log_message "Container App already exists. Verifying existing Key Vault role assignment..."
    
    if check_rbac_assignment_exists "${PRINCIPAL_ID}" "Key Vault Secrets User" "${KEYVAULT_RESOURCE_ID}"; then
        log_message "✅ Key Vault Secrets User role already properly assigned"
    else
        log_message "⚠️  Key Vault Secrets User role not found, assigning now..."
        if assign_rbac_role "${PRINCIPAL_ID}" "Key Vault Secrets User" "${KEYVAULT_RESOURCE_ID}"; then
            log_message "✅ Key Vault Secrets User role assigned successfully"
            # Wait for RBAC to propagate
            log_message "Waiting for RBAC permissions to propagate..."
            sleep 30
        else
            log_message "❌ Failed to assign Key Vault Secrets User role"
            exit 1
        fi
    fi
fi

# 12. Configure Container App secrets (Key Vault references) - only for new apps
if [[ "$CONTAINER_APP_EXISTS" = false ]]; then
    log_message "Configuring Container App secrets with Key Vault references..."

    configure_secrets_with_retry() {
        local max_attempts=5
        local attempt=1
        
        while [[ ${attempt} -le ${max_attempts} ]]; do
            log_message "Attempt ${attempt}/${max_attempts}: Configuring Key Vault secret references..."
            
            if az containerapp secret set \
                --name "${CONTAINER_APP_NAME}" \
                --resource-group "${RESOURCE_GROUP}" \
                --secrets \
                    n8n-encryption-key="keyvaultref:https://${KEYVAULT_NAME}.vault.azure.net/secrets/N8N-Encryption-Key,identityref:system" \
                    n8n-db-password="keyvaultref:https://${KEYVAULT_NAME}.vault.azure.net/secrets/N8N-DB-Password,identityref:system" \
                    n8n-admin-password="keyvaultref:https://${KEYVAULT_NAME}.vault.azure.net/secrets/N8N-Admin-Password,identityref:system" \
                --output none 2>/dev/null; then
                log_message "✅ Container App secrets configured successfully."
                return 0
            else
                log_message "⚠️  Failed to configure secrets (attempt ${attempt}/${max_attempts})"
                if [[ ${attempt} -lt ${max_attempts} ]]; then
                    log_message "This is usually due to RBAC propagation delays. Waiting 30 seconds..."
                    sleep 30
                fi
            fi
            
            ((attempt++))
        done
        
        log_message "❌ Error: Failed to configure Container App secrets after ${max_attempts} attempts"
        echo ""
        echo "🔍 Troubleshooting steps:"
        echo "1. Verify the managed identity has 'Key Vault Secrets User' role on Key Vault"
        echo "2. Check that all secrets exist in Key Vault:"
        echo "   - N8N-Encryption-Key"
        echo "   - N8N-DB-Password" 
        echo "   - N8N-Admin-Password"
        echo "3. Wait a few more minutes for RBAC to propagate, then retry manually:"
        echo "   az containerapp secret set --name '${CONTAINER_APP_NAME}' --resource-group '${RESOURCE_GROUP}' --secrets n8n-encryption-key='keyvaultref:https://${KEYVAULT_NAME}.vault.azure.net/secrets/N8N-Encryption-Key,identityref:system'"
        return 1
    }

    configure_secrets_with_retry || exit 1
else
    log_message "Container App already exists. Skipping secret configuration (secrets should already be configured)."
    log_message "If you need to reconfigure secrets, run this manually:"
    echo "   az containerapp secret set --name '${CONTAINER_APP_NAME}' --resource-group '${RESOURCE_GROUP}' --secrets n8n-encryption-key='keyvaultref:https://${KEYVAULT_NAME}.vault.azure.net/secrets/N8N-Encryption-Key,identityref:system'"
fi


# 14. Get Container App URL
log_message "Retrieving Container App URL..."
CONTAINER_APP_URL=$(az containerapp show \
    --name "${CONTAINER_APP_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query "properties.configuration.ingress.fqdn" \
    --output tsv)

# 13. Update Container App with environment variables (always runs)
log_message "Updating Container App with environment variables..."
log_message "Note: Environment variables are updated on every run to ensure latest configuration."
az containerapp update \
    --name "${CONTAINER_APP_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --set-env-vars \
        N8N_ENCRYPTION_KEY="secretref:n8n-encryption-key" \
        DB_TYPE=postgresdb \
        DB_POSTGRESDB_HOST="${DB_HOST}" \
        DB_POSTGRESDB_PORT=5432 \
        DB_POSTGRESDB_DATABASE="${DB_NAME}" \
        DB_POSTGRESDB_USER="${DB_ADMIN_USER}" \
        DB_POSTGRESDB_PASSWORD="secretref:n8n-db-password" \
        GENERIC_TIMEZONE=Asia/Jerusalem \
        N8N_BASIC_AUTH_USER="${N8N_USERNAME}" \
        N8N_BASIC_AUTH_PASSWORD="secretref:n8n-admin-password" \
        N8N_EDITOR_BASE_URL="https://${CONTAINER_APP_URL}/" \
        WEBHOOK_URL="https://${CONTAINER_APP_URL}/"

if [[ $? -eq 0 ]]; then
    log_message "✅ Container App environment variables updated successfully."
else
    log_message "❌ Error: Failed to update Container App environment variables"
    exit 1
fi



# 15. Display deployment summary
echo ""
echo "🎉 ==============================================="
echo "   n8n Container App Deployment Completed!"
echo "==============================================="
echo ""
echo "📋 Deployment Summary:"
echo "   • Container App Name: ${CONTAINER_APP_NAME}"
echo "   • Resource Group: ${RESOURCE_GROUP}"
echo "   • Database Server: ${DB_SERVER_NAME}"
echo "   • Database Name: ${DB_NAME}"
echo "   • Key Vault: ${KEYVAULT_NAME}"
echo "   • Container App URL: https://${CONTAINER_APP_URL}"
echo ""
if [[ "$CONTAINER_APP_EXISTS" = false ]]; then
    echo "🆕 New Deployment Actions Taken:"
    echo "   • Created new Container App with system-assigned managed identity"
    echo "   • Configured Key Vault secret references"
    echo "   • Assigned AcrPull role for container registry access"
    echo "   • Assigned Key Vault Secrets User role"
else
    echo "🔄 Existing App Update Actions Taken:"
    echo "   • Updated environment variables with latest configuration"
    echo "   • Verified RBAC role assignments (assigned if missing)"
    echo "   • Skipped secret configuration (already exists)"
    echo "   • Maintained existing Container App configuration"
fi
echo ""
echo "🔐 Security Information:"
echo "   • All secrets are stored in Azure Key Vault"
echo "   • System-assigned managed identity is enabled"
echo "   • ACR access granted via managed identity"
echo "   • Key Vault access granted via RBAC"
echo ""
echo "🌐 Access Information:"
echo "   • n8n URL: https://${CONTAINER_APP_URL}"
echo "   • Username: ${N8N_USERNAME}"
echo "   • Password: Stored in Key Vault (N8N-Admin-Password)"
echo ""
echo "🔍 Next Steps:"
echo "   1. Configure your domain (${N8N_DOMAIN}) to point to: ${CONTAINER_APP_URL}"
echo "   2. Update SSL certificate if needed"
echo "   3. Access n8n at: https://${CONTAINER_APP_URL}"
echo ""
log_message "Script execution completed successfully!"
