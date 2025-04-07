#!/usr/bin/env bash
# setup-backstage-capi.sh - Automates the setup of Backstage with Cluster API for self-service AKS provisioning
# Created by: Jared Thivener
# Creation Date: 2025-04-05

set -o errexit
set -o nounset
set -o pipefail

# =============================================================================
#                             CONFIGURATION
# =============================================================================

# Azure configuration
AZURE_SUBSCRIPTION_ID="f645938d-2368-4a99-b589-ea72e5544719"
AZURE_LOCATION="eastus"
RESOURCE_GROUP_NAME="rg-mgmt-aks-${AZURE_LOCATION}"
MGMT_CLUSTER_NAME="mgmt-capi-cluster"
K8S_VERSION="1.31.7"
CNI_PLUGIN="cilium"

# AAD Admin Group ID - if left empty, will use current user
AAD_ADMIN_GROUP_ID=""

# GitHub configuration
GITHUB_ORG="jaredthivener"
GITHUB_REPO="backstage-on-aks"
GITHUB_TOKEN="" # Replace this with a new GitHub personal access token that has the right permissions
# For FluxCD, you need at least the following permissions:
# - repo (full access)
# - admin:repo_hook (read/write)
# GITHUB_USER="jaredthivener"

# Then, in the script, check if it's set:
if [[ -z "${GITHUB_TOKEN}" ]]; then
  read -rsp "Enter your GitHub token: " GITHUB_TOKEN
  echo ""
  export GITHUB_TOKEN
fi

# Backstage configuration
BACKSTAGE_DIR="$(pwd)/backstage"

# Logging configuration
LOG_FILE="$(pwd)/setup-backstage-capi-$(date +%Y%m%d-%H%M%S).log"
LOG_LEVEL="INFO"  # DEBUG, INFO, WARN, ERROR

# =============================================================================
#                             HELPER FUNCTIONS
# =============================================================================

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    # Only log if the current level is at or above the configured level
    case $LOG_LEVEL in
        DEBUG)
            ;;
        INFO)
            if [ "$level" = "DEBUG" ]; then return; fi
            ;;
        WARN)
            if [ "$level" = "DEBUG" ] || [ "$level" = "INFO" ]; then return; fi
            ;;
        ERROR)
            if [ "$level" = "DEBUG" ] || [ "$level" = "INFO" ] || [ "$level" = "WARN" ]; then return; fi
            ;;
    esac
    
    # Output to both log file and stdout
    echo -e "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Error handling function
handle_error() {
    local error_code=$?
    local line_number=$1
    log "ERROR" "Error on line $line_number: Command exited with status $error_code"
    exit $error_code
}

# Verify tool is installed and meets version requirements
verify_tool() {
    local tool="$1"
    local version_cmd="$2"
    local min_version="$3"
    local current_version
    
    log "DEBUG" "Checking for $tool..."
    
    if ! command -v "$tool" &> /dev/null; then
        log "ERROR" "$tool not found. Please install $tool first."
        return 1
    fi
    
    current_version=$(eval "$version_cmd" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    log "DEBUG" "Found $tool version $current_version"
    
    if [[ -z "$current_version" ]]; then
        log "WARN" "Could not determine $tool version. Continuing anyway."
        return 0
    fi
    
    # Corrected logic: if min_version is first (or equal), current version is >= min_version
    if [[ $(echo -e "$current_version\n$min_version" | sort -V | head -n1) == "$min_version" ]]; then
        log "INFO" "$tool version $current_version meets minimum requirement ($min_version)"
        return 0
    else
        log "ERROR" "$tool version $current_version is older than required version $min_version"
        return 1
    fi
}

# Check if a value is provided
check_value() {
    local var_name="$1"
    local var_value="$2"
    
    if [[ -z "$var_value" ]]; then
        log "ERROR" "$var_name is not set. Please update the script configuration."
        return 1
    fi
    return 0
}

# Create management AKS cluster
create_management_cluster() {
    local exists
    
    log "INFO" "Checking if resource group ${RESOURCE_GROUP_NAME} exists..."
    exists=$(az group exists --name "${RESOURCE_GROUP_NAME}")
    
    if [[ "$exists" == "false" ]]; then
        log "INFO" "Creating resource group ${RESOURCE_GROUP_NAME}..."
        az group create --name "${RESOURCE_GROUP_NAME}" --location "${AZURE_LOCATION}" || {
            log "ERROR" "Failed to create resource group."
            return 1
        }
    else
        log "INFO" "Resource group ${RESOURCE_GROUP_NAME} already exists."
    fi
    
    log "INFO" "Checking if AKS cluster ${MGMT_CLUSTER_NAME} exists..."
    if ! az aks show --resource-group "${RESOURCE_GROUP_NAME}" --name "${MGMT_CLUSTER_NAME}" &>/dev/null; then
        log "INFO" "Creating AKS management cluster ${MGMT_CLUSTER_NAME}..."
        az aks create \
            --resource-group "${RESOURCE_GROUP_NAME}" \
            --name "${MGMT_CLUSTER_NAME}" \
            --node-count 3 \
            --node-vm-size Standard_D2d_v4 \
            --ssh-access disabled \
            --enable-managed-identity \
            --enable-oidc-issuer \
            --network-plugin azure \
            --network-dataplane cilium \
            --network-policy ${CNI_PLUGIN} \
            --zones 1 2 3 \
            --kubernetes-version "${K8S_VERSION}" \
            --enable-addons monitoring \
            --enable-aad \
            --aad-admin-group-object-ids "${AAD_ADMIN_GROUP_ID:-$(az ad signed-in-user show --query id -o tsv)}" \
            --enable-azure-rbac \
            --enable-msi-auth-for-monitoring \
            --auto-upgrade-channel stable \
            --node-osdisk-size 75 \
            --node-osdisk-type Ephemeral \
            --max-pods 110 \
            --enable-cluster-autoscaler \
            --min-count 3 \
            --max-count 5 \
            --enable-defender \
            --os-sku AzureLinux \
            --tags environment=management purpose=clusterapi owner=jared || {
            log "ERROR" "Failed to create AKS cluster."
            return 1
        }
        log "INFO" "AKS management cluster created successfully."
    else
        log "INFO" "AKS cluster ${MGMT_CLUSTER_NAME} already exists."
    fi
    
    log "INFO" "Getting credentials for AKS cluster..."
    az aks get-credentials --resource-group "${RESOURCE_GROUP_NAME}" --name "${MGMT_CLUSTER_NAME}" --admin --overwrite-existing || {
        log "ERROR" "Failed to get AKS credentials."
        return 1
    }

    # Verify cluster access
    log "INFO" "Verifying cluster access..."
    kubectl get nodes -o wide || {
        # If regular access fails, try with admin credentials
        log "WARN" "Regular access failed, trying with admin credentials..."
        az role assignment create \
            --assignee "$(az ad signed-in-user show --query id -o tsv)" \
            --role "Azure Kubernetes Service Cluster Admin Role" \
            --scope "/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP_NAME}/providers/Microsoft.ContainerService/managedClusters/${MGMT_CLUSTER_NAME}" || {
            log "ERROR" "Failed to assign admin role. Please ensure you have sufficient permissions."
            return 1
        }
        
        # Try again with admin credentials
        az aks get-credentials --resource-group "${RESOURCE_GROUP_NAME}" --name "${MGMT_CLUSTER_NAME}" --admin --overwrite-existing
        kubectl get nodes -o wide || {
            log "ERROR" "Failed to access AKS cluster even with admin role."
            return 1
        }
    }
    
    return 0
}

# Install Cluster API with Azure provider
install_cluster_api() {
    log "INFO" "Checking if Cluster API is already installed..."
    if ! kubectl get namespace capi-system &>/dev/null; then
        log "INFO" "Setting up prerequisites for Cluster API..."
        
        # Use the service principal already created for ClusterAPI
        local sp_name
        sp_name="ClusterAPI-Creator-$(date +%Y%m%d)"
        local sp_output
        local appId
        local password
        local tenantId
        
        log "INFO" "Creating service principal ${sp_name} for CAPI initialization..."
        sp_output=$(az ad sp create-for-rbac \
            --name "${sp_name}" \
            --role Contributor \
            --scopes "/subscriptions/${AZURE_SUBSCRIPTION_ID}" \
            --output json)
        
        if [[ -z "$sp_output" ]]; then
            log "ERROR" "Failed to create service principal for CAPI."
            return 1
        fi
        
        # Extract values from SP creation output
        appId=$(echo "$sp_output" | grep '"appId"' | sed 's/.*"appId": "\([^"]*\)".*/\1/')
        password=$(echo "$sp_output" | grep '"password"' | sed 's/.*"password": "\([^"]*\)".*/\1/')
        tenantId=$(echo "$sp_output" | grep '"tenant"' | sed 's/.*"tenant": "\([^"]*\)".*/\1/')
        
        # Export required environment variables
        export AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"
        export AZURE_TENANT_ID="${tenantId}"
        export AZURE_CLIENT_ID="${appId}"
        export AZURE_CLIENT_ID_USER_ASSIGNED_IDENTITY="${appId}" # for compatibility with CAPZ v1.16 templates
        export AZURE_CLIENT_SECRET="${password}"
        
        # Settings needed for AzureClusterIdentity used by the AzureCluster
        export AZURE_CLUSTER_IDENTITY_SECRET_NAME="cluster-identity-secret"
        export CLUSTER_IDENTITY_NAME="cluster-identity"
        export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="default"
        
        # Create a secret to include the password of the Service Principal identity created in Azure
        log "INFO" "Creating Kubernetes secret for CAPI service principal..."
        kubectl create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" \
            --from-literal=clientSecret="${AZURE_CLIENT_SECRET}" \
            --namespace "${AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE}" || {
            log "ERROR" "Failed to create Kubernetes secret for CAPI."
            return 1
        }
        
        log "INFO" "Installing Cluster API with Azure provider..."
        clusterctl init --infrastructure azure || {
            log "ERROR" "Failed to install Cluster API."
            return 1
        }
        
        log "INFO" "Waiting for Cluster API components to be ready..."
        kubectl wait --for=condition=ready --timeout=300s pod -l cluster.x-k8s.io/provider=cluster-api -n capi-system || {
            log "WARN" "Timeout waiting for Cluster API pods. Continuing anyway."
        }
        kubectl wait --for=condition=ready --timeout=300s pod -l cluster.x-k8s.io/provider=infrastructure-azure -n capz-system || {
            log "WARN" "Timeout waiting for CAPZ pods. Continuing anyway."
        }
    else
        log "INFO" "Cluster API appears to be already installed."
    fi
    
    # Verify installation
    log "INFO" "Verifying Cluster API installation..."
    kubectl get pods -n capz-system
    kubectl get pods -n capi-system
    
    return 0
}

# Set up FluxCD on the management cluster
setup_flux() {
    log "INFO" "Checking if FluxCD is already installed..."
    if ! kubectl get namespace flux-system &>/dev/null; then
        log "INFO" "Checking FluxCD prerequisites..."
        
        # Export GitHub token to environment variable
        export GITHUB_TOKEN="${GITHUB_TOKEN}"
        
        flux check --pre || {
            log "ERROR" "FluxCD prerequisites not met."
            return 1
        }
        
        log "INFO" "Installing FluxCD with GitHub integration..."
        flux bootstrap github \
            --owner="${GITHUB_ORG}" \
            --repository="${GITHUB_REPO}" \
            --branch=main \
            --path=clusters \
            --personal --token-auth \
            --token="${GITHUB_TOKEN}" || {
            log "ERROR" "Failed to bootstrap FluxCD."
            return 1
        }
    else
        log "INFO" "FluxCD appears to be already installed."
    fi
    
    # Verify FluxCD installation
    log "INFO" "Verifying FluxCD installation..."
    kubectl get pods -n flux-system
    
    return 0
}

# Create service principal for Cluster API
create_service_principal() {
    local sp_name
    sp_name="ClusterAPI-Creator-$(date +%Y%m%d)"
    local sp_output
    local appId
    local password
    local tenant
    
    log "INFO" "Creating service principal ${sp_name}..."
    sp_output=$(az ad sp create-for-rbac \
        --name "${sp_name}" \
        --role Contributor \
        --scopes "/subscriptions/${AZURE_SUBSCRIPTION_ID}" \
        --output json)
    
    if [[ -z "$sp_output" ]]; then
        log "ERROR" "Failed to create service principal."
        return 1
    fi
    
    # Extract values from SP creation output (macOS compatible)
    appId=$(echo "$sp_output" | grep '"appId"' | sed 's/.*"appId": "\([^"]*\)".*/\1/')
    password=$(echo "$sp_output" | grep '"password"' | sed 's/.*"password": "\([^"]*\)".*/\1/')
    tenant=$(echo "$sp_output" | grep '"tenant"' | sed 's/.*"tenant": "\([^"]*\)".*/\1/')
    
    log "INFO" "Service principal created with appId: ${appId}"
    
    # Create Kubernetes secret with SP credentials
    log "INFO" "Creating Kubernetes secret for service principal..."
    kubectl create secret generic azure-cluster-identity \
        --namespace default \
        --from-literal=clientSecret="${password}" \
        --dry-run=client -o yaml | kubectl apply -f - || {
        log "ERROR" "Failed to create Kubernetes secret."
        return 1
    }
    
    # Check the CAPZ version to determine the correct format
    local capz_version
    capz_version=$(kubectl get deployment -n capz-system capz-controller-manager -o=jsonpath='{.spec.template.spec.containers[0].image}' | grep -o "[0-9]*\.[0-9]*\.[0-9]*" || echo "unknown")
    log "INFO" "Detected CAPZ version: ${capz_version}"
    
    # Create AzureClusterIdentity resource with updated format
    log "INFO" "Creating AzureClusterIdentity resource..."
    
    # For newer CAPZ versions that don't use the 'key' field
    cat <<EOF | kubectl apply -f -
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureClusterIdentity
metadata:
  name: cluster-identity
  namespace: default
spec:
  type: ServicePrincipal
  clientID: ${appId}
  clientSecret:
    name: azure-cluster-identity
    namespace: default
  tenantID: ${tenant}
  allowedNamespaces:
    list:
      - default
EOF
    
    # Verify identity creation
    log "INFO" "Verifying AzureClusterIdentity creation..."
    kubectl get azureclusteridentity cluster-identity || {
        log "ERROR" "Failed to create AzureClusterIdentity."
        return 1
    }
    
    return 0
}

# Install and configure Backstage
setup_backstage() {
    log "INFO" "Setting up Backstage..."
    
    # Check if Backstage directory already exists
    if [[ -d "${BACKSTAGE_DIR}" ]]; then
        log "INFO" "Backstage directory already exists at ${BACKSTAGE_DIR}."
        log "INFO" "Using existing Backstage installation."
        return 0
    fi
    
    # Create Backstage app with default values (non-interactive)
    log "INFO" "Creating new Backstage app..."
    echo "backstage" | npx @backstage/create-app@latest --path "${BACKSTAGE_DIR}" || {
        log "ERROR" "Failed to create Backstage app."
        return 1
    }
    
    # Navigate to Backstage directory
    cd "${BACKSTAGE_DIR}" || {
        log "ERROR" "Failed to navigate to Backstage directory."
        return 1
    }
    
    # Set GitHub token in the environment for Backstage
    export GITHUB_TOKEN="${GITHUB_TOKEN}"
    
    # Create a simple app-config.local.yaml with just the GitHub token
    log "INFO" "Creating basic app-config.local.yaml..."
    cat > "${BACKSTAGE_DIR}/app-config.local.yaml" << EOF
integrations:
  github:
    - host: github.com
      token: \${GITHUB_TOKEN}
EOF
    
    # Install dependencies
    log "INFO" "Installing Backstage dependencies..."
    yarn install || {
        log "ERROR" "Failed to install Backstage dependencies."
        return 1
    }
    
    log "INFO" "Backstage setup complete."
    log "INFO" "You can start Backstage by running: cd ${BACKSTAGE_DIR} && yarn dev"
    
    # Automatically start Backstage in the background
    log "INFO" "Starting Backstage automatically..."
    (cd "${BACKSTAGE_DIR}" && GITHUB_TOKEN="${GITHUB_TOKEN}" yarn dev &)
    
    # Wait for Backstage to start
    log "INFO" "Waiting for Backstage to start up (this may take a minute)..."
    sleep 15
    
    log "WARN" "Backstage may still be starting up. Please visit http://localhost:3000 in your browser."
    # Try to open browser anyway
    if command -v open &>/dev/null; then
        open "http://localhost:3000" &>/dev/null || true
    fi
    
    return 0
}

# Configure Backstage GitHub plugins
configure_backstage_github_plugins() {
    log "INFO" "Configuring Backstage GitHub plugins..."
    
    if [[ ! -d "${BACKSTAGE_DIR}" ]]; then
        log "ERROR" "Backstage directory not found at ${BACKSTAGE_DIR}. Please run setup_backstage first."
        return 1
    fi
    
    cd "${BACKSTAGE_DIR}" || {
        log "ERROR" "Failed to navigate to Backstage directory."
        return 1
    }
    
    # Install GitHub scaffolder and catalog backend plugins
    log "INFO" "Installing GitHub plugins..."
    yarn --cwd packages/backend add @backstage/plugin-scaffolder-backend-module-github || {
        log "ERROR" "Failed to install scaffolder GitHub plugin."
        return 1
    }
    
    yarn --cwd packages/backend add @backstage/plugin-catalog-backend-module-github || {
        log "ERROR" "Failed to install catalog GitHub plugin."
        return 1
    }
    
    # Update the backend index.ts file to include GitHub plugins
    log "INFO" "Updating backend configuration in packages/backend/src/index.ts..."
    
    # Backup the original file
    cp "${BACKSTAGE_DIR}/packages/backend/src/index.ts" "${BACKSTAGE_DIR}/packages/backend/src/index.ts.bak" || {
        log "ERROR" "Failed to create backup of index.ts file."
        return 1
    }
    
    # Check if plugins are already imported
    if grep -q "@backstage/plugin-scaffolder-backend-module-github" "${BACKSTAGE_DIR}/packages/backend/src/index.ts"; then
        log "INFO" "GitHub scaffolder plugin already configured."
    else
        # For macOS, the -i '' format is required for sed
        sed -i '' -e '/backend.add(import('\''@backstage\/plugin-scaffolder-backend'\''));/a\'$'\n''backend.add(import('\''@backstage/plugin-scaffolder-backend-module-github'\''));' "${BACKSTAGE_DIR}/packages/backend/src/index.ts" || {
            log "ERROR" "Failed to add GitHub scaffolder plugin to index.ts."
            # Restore backup if modification failed
            mv "${BACKSTAGE_DIR}/packages/backend/src/index.ts.bak" "${BACKSTAGE_DIR}/packages/backend/src/index.ts"
            return 1
        }
    fi
    
    if grep -q "@backstage/plugin-catalog-backend-module-github" "${BACKSTAGE_DIR}/packages/backend/src/index.ts"; then
        log "INFO" "GitHub catalog plugin already configured."
    else
        # For macOS, the -i '' format is required for sed
        sed -i '' -e '/backend.add(import('\''@backstage\/plugin-catalog-backend'\''));/a\'$'\n''backend.add(import('\''@backstage/plugin-catalog-backend-module-github'\''));' "${BACKSTAGE_DIR}/packages/backend/src/index.ts" || {
            log "ERROR" "Failed to add GitHub catalog plugin to index.ts."
            # Restore backup if modification failed
            mv "${BACKSTAGE_DIR}/packages/backend/src/index.ts.bak" "${BACKSTAGE_DIR}/packages/backend/src/index.ts"
            return 1
        }
    fi
    log "INFO" "Backend configuration updated successfully."
    log "INFO" "You can now add your GitHub actions to the Backstage catalog."
    log "INFO" "Please ensure you have the correct permissions for the GitHub repository."
    
    # Restart Backstage to apply changes
    log "INFO" "Restarting Backstage to apply plugin changes..."
    
    # Find and kill existing Backstage process
    pkill -f "node .*backstage.*" || true
    sleep 2
    
    # Start Backstage again
    log "INFO" "Starting Backstage with new plugins..."
    (cd "${BACKSTAGE_DIR}" && GITHUB_TOKEN="${GITHUB_TOKEN}" yarn dev &)
    
    # Wait for Backstage to start
    log "INFO" "Waiting for Backstage to start up with new plugins (this may take a minute)..."
    sleep 20
    
    log "INFO" "GitHub plugins installed successfully."
    log "INFO" "You can now check available GitHub actions at http://localhost:3000/create/actions"
    
    # Try to open browser
    if command -v open &>/dev/null; then
        open "http://localhost:3000/create/actions" &>/dev/null || true
    fi
    
    return 0
}

# =============================================================================
#                             MAIN SCRIPT
# =============================================================================

main() {
    trap 'handle_error $LINENO' ERR
    
    # Print script banner
    log "INFO" "===================================================================="
    log "INFO" "    Backstage + Cluster API Self-Service AKS Setup"
    log "INFO" "    Created by: Jared Thivener"
    log "INFO" "    Date: $(date +%Y-%m-%d)"
    log "INFO" "===================================================================="
    
    # Verify configuration values
    log "INFO" "Verifying configuration values..."
    check_value "AZURE_SUBSCRIPTION_ID" "$AZURE_SUBSCRIPTION_ID" || { 
        read -r -p "Enter your Azure Subscription ID: " AZURE_SUBSCRIPTION_ID
        check_value "AZURE_SUBSCRIPTION_ID" "$AZURE_SUBSCRIPTION_ID" || exit 1
    }
    
    check_value "GITHUB_ORG" "$GITHUB_ORG" || { 
        read -r -p "Enter your GitHub Organization/Username: " GITHUB_ORG
        check_value "GITHUB_ORG" "$GITHUB_ORG" || exit 1
    }
    
    check_value "GITHUB_TOKEN" "$GITHUB_TOKEN" || { 
        read -r -p "Enter your GitHub Personal Access Token: " GITHUB_TOKEN
        check_value "GITHUB_TOKEN" "$GITHUB_TOKEN" || exit 1
    }
    
    # Verify prerequisites are installed
    log "INFO" "
╭──────────────────────────────────────────────────────╮
│                                                      │
│   ████████╗ ██████╗  ██████╗ ██╗     ███████╗        │
│   ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██╔════╝        │
│      ██║   ██║   ██║██║   ██║██║     ███████╗        │
│      ██║   ██║   ██║██║   ██║██║     ╚════██║        │
│      ██║   ╚██████╔╝╚██████╔╝███████╗███████║        │
│      ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚══════╝        │
│                                                      │
│        Verify Prerequisites are installed...         │
│                                                      │
╰──────────────────────────────────────────────────────╯"
    verify_tool "az" "az --version" "2.50.0" || exit 1
    verify_tool "kubectl" "kubectl version --client" "1.25.0" || exit 1
    verify_tool "flux" "flux --version" "2.1.0" || exit 1
    verify_tool "clusterctl" "clusterctl version" "1.5.0" || exit 1
    verify_tool "helm" "helm version" "3.13.0" || exit 1
    verify_tool "node" "node --version" "18.0.0" || exit 1
    verify_tool "yarn" "yarn --version" "1.22.0" || exit 1
    
    # Azure login
    log "INFO" "Logging in to Azure..."
    az account show &>/dev/null || {
        az login || {
            log "ERROR" "Failed to log in to Azure."
            exit 1
        }
    }
    
    # Set subscription
    log "INFO" "Setting Azure subscription..."
    az account set --subscription "$AZURE_SUBSCRIPTION_ID" || {
        log "ERROR" "Failed to set Azure subscription."
        exit 1
    }
    
    # Setup steps
    log "INFO" "Starting setup process..."
    
    log "INFO" "
╭──────────────────────────────────────────────────────╮
│                                                      │
│             ██╗  ██╗ █████╗ ███████╗                 │
│             ██║ ██╔╝██╔══██╗██╔════╝                 │
│             █████╔╝ ╚█████╔╝███████╗                 │
│             ██╔═██╗ ██╔══██╗╚════██║                 │
│             ██║  ██╗╚█████╔╝███████║                 │
│             ╚═╝  ╚═╝ ╚════╝ ╚══════╝                 │
│                                                      │
│              MANAGEMENT CLUSTER SETUP                │
│                                                      │
╰──────────────────────────────────────────────────────╯"
    create_management_cluster || exit 1
    
    log "INFO" "
╭──────────────────────────────────────────────────────╮
│                                                      │
│          ██████╗ █████╗ ██████╗ ██╗                  │
│         ██╔════╝██╔══██╗██╔══██╗██║                  │
│         ██║     ███████║██████╔╝██║                  │
│         ██║     ██╔══██║██╔═══╝ ██║                  │
│         ╚██████╗██║  ██║██║     ██║                  │
│          ╚═════╝╚═╝  ╚═╝╚═╝     ╚═╝                  │
│         CLUSTER API INSTALLATION                     │
│                                                      │
╰──────────────────────────────────────────────────────╯"
    install_cluster_api || exit 1
    
    log "INFO" "
╭──────────────────────────────────────────────────────╮
│                                                      │
│      ███████╗██╗     ██╗   ██╗██╗  ██╗               │
│      ██╔════╝██║     ██║   ██║╚██╗██╔╝               │
│      █████╗  ██║     ██║   ██║ ╚███╔╝                │
│      ██╔══╝  ██║     ██║   ██║ ██╔██╗                │
│      ██║     ███████╗╚██████╔╝██╔╝ ██╗               │
│      ╚═╝     ╚══════╝ ╚═════╝ ╚═╝  ╚═╝               │
│            GITOPS SETUP WITH FLUX                    │
│                                                      │
╰──────────────────────────────────────────────────────╯"
    setup_flux || exit 1
    
    log "INFO" "
╭──────────────────────────────────────────────────────╮
│                                                      │
│       █████╗ ███████╗██╗   ██╗██████╗ ███████╗       │
│      ██╔══██╗╚══███╔╝██║   ██║██╔══██╗██╔════╝       │
│      ███████║  ███╔╝ ██║   ██║██████╔╝█████╗         │
│      ██╔══██║ ███╔╝  ██║   ██║██╔══██╗██╔══╝         │
│      ██║  ██║███████╗╚██████╔╝██║  ██║███████╗       │
│      ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝       │
│                                                      │
│        SERVICE PRINCIPAL CREATION                    │
│                                                      │
╰──────────────────────────────────────────────────────╯"
    create_service_principal || exit 1
    
    log "INFO" "
╭──────────────────────────────────────────────────────╮
│                                                      │
│    ██████╗  █████╗  ██████╗██╗  ██╗                  │
│    ██╔══██╗██╔══██╗██╔════╝██║ ██╔╝                  │
│    ██████╔╝███████║██║     █████╔╝                   │
│    ██╔══██╗██╔══██║██║     ██╔═██╗                   │
│    ██████╔╝██║  ██║╚██████╗██║  ██╗                  │
│    ╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝                  │
│                                                      │
│    ███████╗████████╗ █████╗  ██████╗ ███████╗        │
│    ██╔════╝╚══██╔══╝██╔══██╗██╔════╝ ██╔════╝        │
│    ███████╗   ██║   ███████║██║  ███╗█████╗          │
│    ╚════██║   ██║   ██╔══██║██║   ██║██╔══╝          │
│    ███████║   ██║   ██║  ██║╚██████╔╝███████╗        │
│    ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚══════╝        │
│                                                      │
│             BACKSTAGE INSTALLATION                   │
│                                                      │
╰──────────────────────────────────────────────────────╯"
    setup_backstage || exit 1
    
    log "INFO" "
╭──────────────────────────────────────────────────────╮
│                                                      │
│    ██████╗ ██╗████████╗██╗  ██╗██╗   ██╗██████╗      │
│   ██╔════╝ ██║╚══██╔══╝██║  ██║██║   ██║██╔══██╗     │
│   ██║  ███╗██║   ██║   ███████║██║   ██║██████╔╝     │
│   ██║   ██║██║   ██║   ██╔══██║██║   ██║██╔══██╗     │
│   ╚██████╔╝██║   ██║   ██║  ██║╚██████╔╝██████╔╝     │
│    ╚═════╝ ╚═╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝ ╚═════╝      │
│        PLUGIN CONFIGURATION FOR GITHUB               │
│                                                      │
╰──────────────────────────────────────────────────────╯"
    configure_backstage_github_plugins || exit 1
    
    log "INFO" "
╭────────────────────────────────────────────────────────────────────────╮
│                                                                        │
│   ██████╗ ██████╗ ███╗   ███╗██████╗ ██║     ███████╗████████╗███████╗ │
│  ██╔════╝██╔═══██╗████╗ ████║██╔══██╗██║     ██╔════╝╚══██╔══╝██╔════╝ │
│  ██║     ██║   ██║██╔████╔██║██████╔╝██║     █████╗     ██║   █████╗   │
│  ██║     ██║   ██║██║╚██╔╝██║██╔═══╝ ██║     ██╔══╝     ██║   ██╔══╝   │
│  ╚██████╗╚██████╔╝██║ ╚═╝ ██║██║     ███████╗███████╗   ██║   ███████╗ │
│   ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚══════╝╚══════╝   ╚═╝   ╚══════╝ │
│                                                                        │
│                                                                        │
│                                                                        │
│                  SETUP COMPLETED SUCCESSFULLY!                         │
│                                                                        │
│            Backstage has been automatically started                    │
│         and should be available at http://localhost:3000               │
│                                                                        │
╰────────────────────────────────────────────────────────────────────────╯"
}

# Execute main function
main