#!/usr/bin/env bash
# cleanup-backstage-capi.sh - Removes resources created by the setup-backstage-capi.sh script
# Created by: GitHub Copilot for jaredthivener
# Creation Date: 2025-04-05

set -o errexit
set -o nounset
set -o pipefail

# =============================================================================
#                             CONFIGURATION
# =============================================================================

# Azure configuration - must match setup script
AZURE_SUBSCRIPTION_ID="f645938d-2368-4a99-b589-ea72e5544719"
AZURE_LOCATION="eastus"
RESOURCE_GROUP_NAME="rg-mgmt-aks-${AZURE_LOCATION}"
MGMT_CLUSTER_NAME="mgmt-capi-cluster"

# GitHub configuration - must match setup script
GITHUB_USER="jaredthivener"

# Backstage configuration - must match setup script
BACKSTAGE_DIR="$(pwd)/backstage"  # Instead of "${HOME}/backstage"

# Logging configuration
LOG_FILE="$(pwd)/cleanup-backstage-capi-$(date +%Y%m%d-%H%M%S).log"
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

# Confirm action with user
confirm_action() {
    local prompt="$1"
    local default="$2"
    
    if [[ "$default" == "Y" ]]; then
        prompt="${prompt} [Y/n]"
    else
        prompt="${prompt} [y/N]"
    fi
    
    read -p "$prompt " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    elif [[ $REPLY =~ ^[Nn]$ ]]; then
        return 1
    elif [[ -z $REPLY ]]; then
        if [[ "$default" == "Y" ]]; then
            return 0
        else
            return 1
        fi
    else
        log "WARN" "Invalid input. Please enter Y or N."
        confirm_action "$prompt" "$default"
    fi
}

# Remove all child clusters created by CAPI
remove_capi_clusters() {
    # If we're going to delete the whole management cluster anyway,
    # we can skip this step entirely
    if confirm_action "Will you be deleting the entire AKS management cluster?" "Y"; then
        log "INFO" "Skipping CAPI clusters cleanup since the entire AKS cluster will be deleted."
        return 0
    fi
    
    log "INFO" "Checking for CAPI-managed clusters..."
    
    # Get AKS credentials if not already set
    if ! kubectl get nodes &>/dev/null; then
        log "INFO" "Getting credentials for AKS cluster..."
        az aks get-credentials --resource-group "${RESOURCE_GROUP_NAME}" --name "${MGMT_CLUSTER_NAME}" --overwrite-existing || {
            log "ERROR" "Failed to get AKS credentials. Skipping CAPI cluster cleanup."
            return 1
        }
    fi
    
    # Check if any clusters exist
    if ! kubectl get clusters --all-namespaces &>/dev/null; then
        log "INFO" "No CAPI-managed clusters found."
        return 0
    fi
    
    # List all clusters for user awareness
    log "INFO" "Found the following CAPI-managed clusters:"
    kubectl get clusters --all-namespaces
    
    # Confirm deletion
    if ! confirm_action "Do you want to delete all CAPI-managed clusters?" "Y"; then
        log "INFO" "Skipping CAPI cluster deletion."
        return 0
    fi
    
    # Delete all clusters - this will cascade and delete child resources
    log "INFO" "Deleting all CAPI-managed clusters..."
    kubectl get clusters --all-namespaces -o json | jq -r '.items[] | [.metadata.namespace, .metadata.name] | @tsv' | while read -r namespace name; do
        log "INFO" "Deleting cluster ${name} in namespace ${namespace}..."
        kubectl delete cluster -n "${namespace}" "${name}" || {
            log "WARN" "Failed to delete cluster ${name}. Continuing with other clusters."
        }
    done
    
    return 0
}

# Remove FluxCD from management cluster
remove_flux() {
    # If we're going to delete the whole management cluster anyway,
    # we can skip this step entirely
    if confirm_action "Will you be deleting the entire AKS management cluster?" "Y"; then
        log "INFO" "Skipping FluxCD cleanup since the entire AKS cluster will be deleted."
        return 0
    fi
    
    log "INFO" "Checking if FluxCD is installed..."
    if ! kubectl get namespace flux-system &>/dev/null; then
        log "INFO" "FluxCD not found. Skipping."
        return 0
    fi
    
    # Confirm deletion
    if ! confirm_action "Do you want to uninstall FluxCD from the management cluster?" "Y"; then
        log "INFO" "Skipping FluxCD uninstallation."
        return 0
    fi
    
    log "INFO" "Uninstalling FluxCD..."
    kubectl delete namespace flux-system || {
        log "WARN" "Failed to delete flux-system namespace. Some resources may need manual cleanup."
    }
    
    log "INFO" "FluxCD removed successfully."
    return 0
}

# Remove Cluster API from management cluster
remove_capi() {
    # If we're going to delete the whole management cluster anyway,
    # we can skip this step entirely
    if confirm_action "Will you be deleting the entire AKS management cluster?" "Y"; then
        log "INFO" "Skipping Cluster API cleanup since the entire AKS cluster will be deleted."
        return 0
    fi
    
    log "INFO" "Checking if Cluster API is installed..."
    if ! kubectl get namespace capi-system &>/dev/null && ! kubectl get namespace capz-system &>/dev/null; then
        log "INFO" "Cluster API not found. Skipping."
        return 0
    fi
    
    # Confirm deletion
    if ! confirm_action "Do you want to uninstall Cluster API from the management cluster?" "Y"; then
        log "INFO" "Skipping Cluster API uninstallation."
        return 0
    fi
    
    log "INFO" "Uninstalling Cluster API..."
    if command -v clusterctl &>/dev/null; then
        clusterctl delete --all || {
            log "WARN" "Failed to uninstall Cluster API with clusterctl. Attempting manual cleanup."
            kubectl delete namespace capi-system capz-system || {
                log "WARN" "Failed to delete CAPI namespaces. Some resources may need manual cleanup."
            }
        }
    else
        log "WARN" "clusterctl not found. Attempting manual cleanup."
        kubectl delete namespace capi-system capz-system || {
            log "WARN" "Failed to delete CAPI namespaces. Some resources may need manual cleanup."
        }
    fi
    
    log "INFO" "Cluster API removed successfully."
    return 0
}

# Delete AKS management cluster
delete_management_cluster() {
    log "INFO" "Checking if AKS cluster ${MGMT_CLUSTER_NAME} exists..."
    if ! az aks show --resource-group "${RESOURCE_GROUP_NAME}" --name "${MGMT_CLUSTER_NAME}" &>/dev/null; then
        log "INFO" "AKS cluster ${MGMT_CLUSTER_NAME} not found. Skipping."
        return 0
    fi
    
    # Confirm deletion
    if ! confirm_action "Do you want to delete the AKS management cluster?" "Y"; then
        log "INFO" "Skipping AKS management cluster deletion."
        return 0
    fi
    
    log "INFO" "Deleting AKS cluster ${MGMT_CLUSTER_NAME}..."
    az aks delete --resource-group "${RESOURCE_GROUP_NAME}" --name "${MGMT_CLUSTER_NAME}" --yes || {
        log "ERROR" "Failed to delete AKS cluster."
        return 1
    }
    
    log "INFO" "AKS cluster deleted successfully."
    return 0
}

# Delete Azure resource group
delete_resource_group() {
    log "INFO" "Checking if resource group ${RESOURCE_GROUP_NAME} exists..."
    if ! az group show --name "${RESOURCE_GROUP_NAME}" &>/dev/null; then
        log "INFO" "Resource group ${RESOURCE_GROUP_NAME} not found. Skipping."
        return 0
    fi
    
    # Confirm deletion
    if ! confirm_action "Do you want to delete the resource group ${RESOURCE_GROUP_NAME}?" "Y"; then
        log "INFO" "Skipping resource group deletion."
        return 0
    fi
    
    log "INFO" "Deleting resource group ${RESOURCE_GROUP_NAME}..."
    az group delete --name "${RESOURCE_GROUP_NAME}" --yes || {
        log "ERROR" "Failed to delete resource group."
        return 1
    }
    
    log "INFO" "Resource group deleted successfully."
    return 0
}

# Delete service principals
cleanup_service_principals() {
    log "INFO" "Checking for ClusterAPI service principals..."
    
    # Use filter to find service principals that start with "ClusterAPI"
    local sp_data
    sp_data=$(az ad app list --filter "startswith(displayName,'ClusterAPI')" --query "[].{DisplayName:displayName, AppId:appId}" -o json)
    
    # Check if we found any service principals
    if [[ -z "$sp_data" || $(echo "$sp_data" | jq length) -eq 0 ]]; then
        log "INFO" "No ClusterAPI service principals found. Skipping service principal cleanup."
        return 0
    fi
    
    log "INFO" "Found the following service principals that may be related to ClusterAPI:"
    echo "$sp_data" | jq -r '.[] | "- \(.DisplayName) (AppID: \(.AppId))"'
    
    # Confirm deletion
    if ! confirm_action "Do you want to delete these service principals?" "Y"; then
        log "INFO" "Skipping service principal deletion."
        return 0
    fi
    
    # Store app IDs in an array to avoid subshell issues
    readarray -t app_ids < <(echo "$sp_data" | jq -r '.[].AppId')
    
    for app_id in "${app_ids[@]}"; do
        display_name=$(echo "$sp_data" | jq -r ".[] | select(.AppId == \"$app_id\") | .DisplayName")
        log "INFO" "Deleting service principal ${display_name} (AppID: ${app_id})..."
        
        # First try to delete the enterprise app (service principal)
        log "DEBUG" "Attempting to delete service principal..."
        if az ad sp delete --id "$app_id" 2>/dev/null; then
            log "INFO" "Service principal deleted successfully."
        else
            log "WARN" "Failed to delete service principal directly. Trying to delete the app registration..."
            
            # If SP deletion fails, try deleting the app registration
            if az ad app delete --id "$app_id" 2>/dev/null; then
                log "INFO" "App registration deleted successfully."
            else
                # Try with the newer Azure CLI syntax which might use object ID instead
                log "WARN" "Standard deletion failed. Trying alternative approach..."
                
                # Get the object ID of the app
                object_id=$(az ad app show --id "$app_id" --query id -o tsv 2>/dev/null)
                if [[ -n "$object_id" ]]; then
                    if az ad app delete --id "$object_id" 2>/dev/null; then
                        log "INFO" "App registration deleted successfully using object ID."
                    else
                        log "ERROR" "Failed to delete service principal. You may need to delete it manually."
                        log "ERROR" "   - App ID: $app_id"
                        log "ERROR" "   - Display Name: $display_name"
                    fi
                else
                    log "ERROR" "Failed to get object ID for app $app_id. Manual cleanup required."
                fi
            fi
        fi
    done
    
    # Verify deletion
    log "INFO" "Verifying service principal deletion..."
    sleep 5 # Give Azure some time to process the deletions
    
    sp_data=$(az ad app list --filter "startswith(displayName,'ClusterAPI')" --query "[].{DisplayName:displayName, AppId:appId}" -o json)
    if [[ $(echo "$sp_data" | jq length) -gt 0 ]]; then
        log "WARN" "Some ClusterAPI service principals still exist and could not be deleted automatically:"
        echo "$sp_data" | jq -r '.[] | "- \(.DisplayName) (AppID: \(.AppId))"'
        log "WARN" "Please delete these manually from the Azure portal with these commands:"
        echo "$sp_data" | jq -r '.[] | "az ad app delete --id \(.AppId)"'
    else
        log "INFO" "All ClusterAPI service principals have been successfully deleted."
    fi
    
    return 0
}

# Remove Backstage installation
remove_backstage() {
    if [[ ! -d "${BACKSTAGE_DIR}" ]]; then
        log "INFO" "Backstage directory ${BACKSTAGE_DIR} not found. Skipping."
        return 0
    fi
    
    # Confirm deletion
    if ! confirm_action "Do you want to delete the Backstage installation at ${BACKSTAGE_DIR}?" "Y"; then
        log "INFO" "Skipping Backstage removal."
        return 0
    fi
    
    log "INFO" "Removing Backstage directory..."
    rm -rf "${BACKSTAGE_DIR}" || {
        log "ERROR" "Failed to delete Backstage directory."
        return 1
    }
    
    log "INFO" "Backstage removed successfully."
    return 0
}

# =============================================================================
#                             MAIN SCRIPT
# =============================================================================

main() {
    # Print script banner
    log "INFO" "===================================================================="
    log "INFO" "    Backstage + Cluster API Cleanup"
    log "INFO" "    Created for: ${GITHUB_USER}"
    log "INFO" "    Date: $(date +%Y-%m-%d)"
    log "INFO" "===================================================================="
    
    # Ask for global confirmation
    if ! confirm_action "This script will remove resources created by setup-backstage-capi.sh. Continue?" "N"; then
        log "INFO" "Cleanup canceled by user."
        exit 0
    fi
    
    # Connect to Azure
    log "INFO" "Connecting to Azure..."
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
    
    # Step 1: Connect to AKS and delete any CAPI managed clusters
    log "INFO" "
    ╭──────────────────────────────────────────────────────╮
    │                                                      │
    │   ███████╗████████╗███████╗██████╗        ██╗        │
    │   ██╔════╝╚══██╔══╝██╔════╝██╔══██╗      ███║        │
    │   ███████╗   ██║   █████╗  ██████╔╝█████╗╚██║        │
    │   ╚════██║   ██║   ██╔══╝  ██╔═══╝ ╚════╝ ██║        │
    │   ███████║   ██║   ███████╗██║            ██║        │
    │   ╚══════╝   ╚═╝   ╚══════╝╚═╝            ╚═╝        │
    │     CONNECTING TO AKS & FINDING CHILD CLUSTERS       │
    │                                                      │
    ╰──────────────────────────────────────────────────────╯"
    
    # Try to get AKS credentials first
    if ! az aks show --resource-group "${RESOURCE_GROUP_NAME}" --name "${MGMT_CLUSTER_NAME}" &>/dev/null; then
        log "INFO" "AKS cluster ${MGMT_CLUSTER_NAME} not found. Skipping CAPI cleanup."
    else
        log "INFO" "Getting credentials for AKS cluster..."
        az aks get-credentials --resource-group "${RESOURCE_GROUP_NAME}" --name "${MGMT_CLUSTER_NAME}" --overwrite-existing || {
            log "ERROR" "Failed to get AKS credentials. Skipping CAPI cluster cleanup."
        }
        
        # Check if we can access the cluster
        if kubectl get nodes &>/dev/null; then
            log "INFO" "
    ╭──────────────────────────────────────────────────────╮
    │                                                      │
    │    ██████╗  █████╗ ██████╗ ██╗                       │
    │   ██╔════╝ ██╔══██╗██╔══██╗██║                       │
    │   ██║      ███████║██████╔╝██║                       │
    │   ██║      ██╔══██║██╔═══╝ ██║                       │
    │   ╚██████╗ ██║  ██║██║     ██║                       │
    │    ╚═════╝ ╚═╝  ╚═╝╚═╝     ╚═╝                       │
    │     REMOVING CAPI-MANAGED CLUSTERS                   │
    │                                                      │
    ╰──────────────────────────────────────────────────────╯"
            # Check if Cluster API is installed
            if kubectl get clusters --all-namespaces &>/dev/null; then
                # List all clusters for user awareness
                log "INFO" "Found the following CAPI-managed clusters:"
                kubectl get clusters --all-namespaces
                
                # Confirm deletion
                if confirm_action "Do you want to delete all CAPI-managed child clusters?" "Y"; then
                    # Delete all clusters - this will cascade and delete child resources
                    log "INFO" "Deleting all CAPI-managed clusters..."
                    kubectl get clusters --all-namespaces -o json | jq -r '.items[] | [.metadata.namespace, .metadata.name] | @tsv' | while read -r namespace name; do
                        log "INFO" "Deleting cluster ${name} in namespace ${namespace}..."
                        kubectl delete cluster -n "${namespace}" "${name}" || {
                            log "WARN" "Failed to delete cluster ${name}. Continuing with other clusters."
                        }
                    done
                    
                    # Wait for cluster deletions to complete
                    log "INFO" "Waiting for cluster deletions to complete..."
                    sleep 30
                else
                    log "INFO" "Skipping CAPI cluster deletion."
                fi
            else
                log "INFO" "No CAPI-managed clusters found."
            fi
        else
            log "WARN" "Cannot access Kubernetes API. Skipping CAPI cluster cleanup."
        fi
    fi
    
    # Step 2: Delete the entire resource group
    log "INFO" "
    ╭──────────────────────────────────────────────────────╮
    │                                                      │
    │   ███████╗████████╗███████╗██████╗        ██████╗    │
    │   ██╔════╝╚══██╔══╝██╔════╝██╔══██╗      ╚════██╗    │
    │   ███████╗   ██║   █████╗  ██████╔╝█████╗ █████╔╝    │
    │   ╚════██║   ██║   ██╔══╝  ██╔═══╝ ╚════╝██╔═══╝     │
    │   ███████║   ██║   ███████╗██║          ███████╗     │
    │   ╚══════╝   ╚═╝   ╚══════╝╚═╝          ╚══════╝     │
    │       PURGING RESOURCE GROUP & AKS CLUSTER           │
    │                                                      │
    ╰──────────────────────────────────────────────────────╯"
    
    if az group show --name "${RESOURCE_GROUP_NAME}" &>/dev/null; then
        log "INFO" "Resource group ${RESOURCE_GROUP_NAME} found."
        if confirm_action "Do you want to delete the entire resource group? This will remove ALL resources including AKS." "Y"; then
            log "INFO" "Deleting resource group ${RESOURCE_GROUP_NAME}..."
            az group delete --name "${RESOURCE_GROUP_NAME}" --yes --no-wait || {
                log "ERROR" "Failed to delete resource group."
            }
            log "INFO" "Resource group deleted successfully."
        else
            log "INFO" "Skipping resource group deletion."
        fi
    else
        log "INFO" "Resource group ${RESOURCE_GROUP_NAME} not found. Skipping."
    fi
    
    # Step 3: Clean up service principals
    log "INFO" "
    ╭──────────────────────────────────────────────────────╮
    │                                                      │
    │   ███████╗████████╗███████╗██████╗        ███████╗   │
    │   ██╔════╝╚══██╔══╝██╔════╝██╔══██╗      ██╔══██╗    │
    │   ███████╗   ██║   █████╗  ██████╔╝█████╗███████╗    │
    │   ╚════██║   ██║   ██╔══╝  ██╔═══╝ ╚════╝╚════██║    │
    │   ███████║   ██║   ███████╗██║          ███████║     │
    │   ╚══════╝   ╚═╝   ╚══════╝╚═╝          ╚══════╝     │
    │      CLEANING UP SERVICE PRINCIPALS                  │
    │                                                      │
    ╰──────────────────────────────────────────────────────╯"
    cleanup_service_principals
    
    # Step 4: Remove Backstage installation
    log "INFO" "
    ╭──────────────────────────────────────────────────────╮
    │                                                      │
    │   ███████╗████████╗███████╗██████╗       ██╗  ██╗    │
    │   ██╔════╝╚══██╔══╝██╔════╝██╔══██╗      ██║  ██║    │
    │   ███████╗   ██║   █████╗  ██████╔╝█████╗███████║    │
    │   ╚════██║   ██║   ██╔══╝  ██╔═══╝ ╚════╝╚════██║    │
    │   ███████║   ██║   ███████╗██║           ╚════██╝    │
    │   ╚══════╝   ╚═╝   ╚══════╝╚═╝               ╚═╝     │
    │       REMOVING BACKSTAGE INSTALLATION                │
    │                                                      │
    ╰──────────────────────────────────────────────────────╯"
    remove_backstage
    
    log "INFO" "
    ╭──────────────────────────────────────────────────────╮
    │                                                      │
    │    ██████╗██╗     ███████╗ █████╗ ███╗   ██╗         │
    │   ██╔════╝██║     ██╔════╝██╔══██╗████╗  ██║         │
    │   ██║     ██║     █████╗  ███████║██╔██╗ ██║         │
    │   ██║     ██║     ██╔══╝  ██╔══██║██║╚██╗██║         │
    │   ╚██████╗███████╗███████╗██║  ██║██║ ╚████║         │
    │    ╚═════╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝         │
    │                                                      │
    │       CLEANUP COMPLETED SUCCESSFULLY!                │
    │                                                      │
    ╰──────────────────────────────────────────────────────╯"
}

# Execute main function
main