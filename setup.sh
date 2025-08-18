#!/usr/bin/env bash
# setup-backstage-capi.sh - Automates the setup of AKS with Cluster API for self-service AKS provisioning
# Created by: Jared Thivener
# Creation Date: 2025-04-05

set -euo pipefail

# =============================================================================
#                             CONFIGURATION
# =============================================================================

# Azure configuration
AZURE_SUBSCRIPTION_ID="f645938d-2368-4a99-b589-ea72e5544719"
AZURE_LOCATION="eastus"
RESOURCE_GROUP_NAME="rg-mgmt-aks-${AZURE_LOCATION}"
MGMT_CLUSTER_NAME="mgmt-capi-cluster"
K8S_VERSION="1.32.3"

# AAD Admin Group ID - if left empty, will use current user
AAD_ADMIN_GROUP_ID=""

# GitHub configuration
GITHUB_ORG="jaredthivener"
GITHUB_REPO="azure-cluster-api"
GITHUB_TOKEN="" # Replace this with a new GitHub personal access token that has the right permissions

# Then, in the script, check if it's set:
if [[ -z "${GITHUB_TOKEN}" ]]; then
  read -rsp "Enter your GitHub token: " GITHUB_TOKEN
  echo ""
  export GITHUB_TOKEN
fi

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
            --node-vm-size Standard_D2pds_v5 \
            --generate-ssh-keys \
            --enable-managed-identity \
            --enable-workload-identity \
            --enable-oidc-issuer \
            --network-plugin azure \
            --network-plugin-mode overlay \
            --network-dataplane cilium \
            --zones 1 2 3 \
            --kubernetes-version "${K8S_VERSION}" \
            --enable-addons monitoring \
            --enable-aad \
            --aad-admin-group-object-ids "${AAD_ADMIN_GROUP_ID:-$(az ad signed-in-user show --query id -o tsv)}" \
            --enable-azure-rbac \
            --enable-msi-auth-for-monitoring \
            --auto-upgrade-channel stable \
            --node-osdisk-size 64 \
            --node-osdisk-type Ephemeral \
            --max-pods 110 \
            --enable-cluster-autoscaler \
            --min-count 1 \
            --max-count 5 \
            --enable-vpa \
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
        # With Azure RBAC enabled, grant RBAC Cluster Admin so kubectl works without --admin context (lab convenience)
        az role assignment create \
            --assignee "$(az ad signed-in-user show --query id -o tsv)" \
            --role "Azure Kubernetes Service RBAC Cluster Admin" \
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
    if kubectl get namespace capi-system &>/dev/null; then
        log "INFO" "Cluster API appears to be already installed."
        return 0
    fi

    log "INFO" "Setting up prerequisites for Cluster API..."

    local sp_name
    sp_name="ClusterAPI-Creator-$(date +%Y%m%d)"
    log "INFO" "Creating service principal ${sp_name} for CAPI initialization..."
    local sp_output
    if ! sp_output=$(az ad sp create-for-rbac \
        --name "${sp_name}" \
        --role Contributor \
        --scopes "/subscriptions/${AZURE_SUBSCRIPTION_ID}" \
        --output json); then
        log "ERROR" "Failed to create service principal for CAPI."
        return 1
    fi

    local appId password tenantId
    appId=$(echo "$sp_output" | jq -r .appId)
    password=$(echo "$sp_output" | jq -r .password)
    tenantId=$(echo "$sp_output" | jq -r .tenant)

    export AZURE_SUBSCRIPTION_ID 
    export AZURE_CLIENT_ID="$appId"
    export AZURE_CLIENT_SECRET="$password"
    export AZURE_TENANT_ID="$tenantId"
    
    local secret_name="cluster-identity-secret"
    local identity_name="cluster-identity"
    local secret_namespace="default"

    log "INFO" "Creating Kubernetes secret for CAPI service principal..."
    kubectl create secret generic "$secret_name" \
        --from-literal=clientSecret="$AZURE_CLIENT_SECRET" \
        --namespace "$secret_namespace" \
        --dry-run=client -o yaml | kubectl apply -f - || {
        log "ERROR" "Failed to create or update Kubernetes secret for CAPI."
        return 1
    }

    log "INFO" "Installing Cluster API with Azure provider..."
    clusterctl init --infrastructure azure || {
        log "ERROR" "Failed to install Cluster API."
        return 1
    }

    log "INFO" "Waiting for Cluster API components to be ready..."
    kubectl wait --for=condition=ready --timeout=300s pod -l cluster.x-k8s.io/provider=cluster-api -n capi-system || log "WARN" "Timeout waiting for Cluster API pods."
    kubectl wait --for=condition=ready --timeout=300s pod -l cluster.x-k8s.io/provider=infrastructure-azure -n capz-system || log "WARN" "Timeout waiting for CAPZ pods."

    log "INFO" "Creating AzureClusterIdentity resource..."
    cat <<EOF | kubectl apply -f -
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureClusterIdentity
metadata:
  name: $identity_name
  namespace: $secret_namespace
spec:
  type: ServicePrincipal
  clientID: $appId
  clientSecret:
    name: $secret_name
    namespace: $secret_namespace
  tenantID: $tenantId
  allowedNamespaces:
    list:
      - $secret_namespace
EOF

    log "INFO" "Verifying AzureClusterIdentity creation..."
    kubectl get azureclusteridentity "$identity_name" || {
        log "ERROR" "Failed to create AzureClusterIdentity."
        return 1
    }

    log "INFO" "Verifying Cluster API installation..."
    kubectl get pods -n capz-system
    kubectl get pods -n capi-system

    log "INFO" "Cluster API installed successfully."
    return 0
}

# Set up FluxCD on the management cluster
setup_flux() {
    log "INFO" "Checking if FluxCD is already installed..."
    if kubectl get namespace flux-system &>/dev/null; then
        log "INFO" "FluxCD appears to be already installed."
        return 0
    fi

    log "INFO" "Checking FluxCD prerequisites..."
    export GITHUB_TOKEN
    flux check --pre || {
        log "ERROR" "FluxCD prerequisites not met."
        return 1
    }

    log "INFO" "Installing FluxCD with GitHub integration..."
    flux bootstrap github \
        --owner="$GITHUB_ORG" \
        --repository="$GITHUB_REPO" \
        --branch=main \
        --path=clusters \
        --personal --token-auth \
        --token="$GITHUB_TOKEN" || {
        log "ERROR" "Failed to bootstrap FluxCD."
        return 1
    }

    log "INFO" "Verifying FluxCD installation..."
    kubectl get pods -n flux-system

    return 0
}

# =============================================================================
#                             MAIN SCRIPT
# =============================================================================

main() {
    trap 'handle_error $LINENO' ERR
    
    # Print script banner
    log "INFO" "===================================================================="
    log "INFO" "    Cluster API for AKS Setup"
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
    
    # GITHUB_TOKEN already prompted above; ensure it's exported
    export GITHUB_TOKEN
    
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
    verify_tool "jq" "jq --version" "1.6" || exit 1

    # Optionally auto-select a supported AKS version if K8S_VERSION is set to "auto"
    if [[ "${K8S_VERSION}" == "auto" ]]; then
        log "INFO" "Discovering default supported AKS version in ${AZURE_LOCATION}..."
        local detected
        detected=$(az aks get-versions --location "${AZURE_LOCATION}" --query "orchestrators[?default].orchestratorVersion | [0]" -o tsv || true)
        if [[ -n "$detected" ]]; then
            K8S_VERSION="$detected"
            log "INFO" "Using detected AKS version: ${K8S_VERSION}"
        else
            log "WARN" "Could not detect default AKS version; continuing with configured K8S_VERSION=${K8S_VERSION}"
        fi
    fi
    
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
╭────────────────────────────────────────────────────────────────────────╮
│                                                                        │
│   ██████╗ ██████╗ ███╗   ███╗██████╗ ██║     ███████╗████████╗███████╗ │
│  ██╔════╝██╔═══██╗████╗ ████║██╔══██╗██║     ██╔════╝╚══██╔══╝██╔════╝ │
│  ██║     ██║   ██║██╔████╔██║██████╔╝██║     █████╗     ██║   █████╗   │
│  ██║     ██║   ██║██║╚██╔╝██║██╔═══╝ ██║     ██╔══╝     ██║   ██╔══╝   │
│  ╚██████╗╚██████╔╝██║ ╚═╝ ██║██║     ███████╗███████╗   ██║   ███████╗ │
│   ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚══════╝╚══════╝   ╚═╝   ╚══════╝ │
│                                                                        │
│                  SETUP COMPLETED SUCCESSFULLY!                         │
╰────────────────────────────────────────────────────────────────────────╯"
}

# Execute main function
main