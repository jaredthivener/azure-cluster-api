#!/usr/bin/env bash
# setup-backstage-capi.sh - Automates the setup of Backstage with Cluster API for self-service AKS provisioning
# Created by: GitHub Copilot for jaredthivener
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

# GitHub configuration
GITHUB_ORG="jaredthivener"
GITHUB_REPO="backstage-on-aks"
GITHUB_TOKEN="" # Replace this with a new GitHub personal access token that has the right permissions
# For FluxCD, you need at least the following permissions:
# - repo (full access)
# - admin:repo_hook (read/write)
GITHUB_USER="jaredthivener"
# GITHUB_EMAIL="${GITHUB_USER}@gmail.com"

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
            --node-vm-size Standard_D4s_v5 \
            --ssh-access disabled \
            --enable-managed-identity \
            --enable-oidc-issuer \
            --network-plugin azure \
            --network-dataplane cilium \
            --network-policy ${CNI_PLUGIN} \
            --zones 1 2 3 \
            --kubernetes-version "${K8S_VERSION}" || {
            log "ERROR" "Failed to create AKS cluster."
            return 1
        }
        log "INFO" "AKS management cluster created successfully."
    else
        log "INFO" "AKS cluster ${MGMT_CLUSTER_NAME} already exists."
    fi
    
    log "INFO" "Getting credentials for AKS cluster..."
    az aks get-credentials --resource-group "${RESOURCE_GROUP_NAME}" --name "${MGMT_CLUSTER_NAME}" --overwrite-existing || {
        log "ERROR" "Failed to get AKS credentials."
        return 1
    }
    
    # Verify cluster access
    log "INFO" "Verifying cluster access..."
    kubectl get nodes -o wide || {
        log "ERROR" "Failed to access AKS cluster."
        return 1
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
        # Instead of prompting, automatically use the existing installation
        log "INFO" "Using existing Backstage installation."
        return 0
    fi
    
    # Create Backstage app with default values (non-interactive)
    log "INFO" "Creating new Backstage app..."
    # Use echo to automatically answer the prompt with "backstage" as the app name
    echo "backstage" | npx @backstage/create-app@latest --path "${BACKSTAGE_DIR}" || {
        log "ERROR" "Failed to create Backstage app."
        return 1
    }
    
    # Navigate to Backstage directory
    cd "${BACKSTAGE_DIR}" || {
        log "ERROR" "Failed to navigate to Backstage directory."
        return 1
    }
    
    # Install GitHub plugins - Fixed for newer Yarn versions
    log "INFO" "Installing GitHub plugins for Backstage..."
    # Change to packages/app directory and then install correct plugin names
    (cd packages/app && yarn add @backstage/plugin-github-actions @backstage/plugin-github-deployments @backstage/plugin-github-pull-requests-board) || {
        log "ERROR" "Failed to install GitHub plugins."
        return 1
    }
    
    # Update App.tsx to include GitHub plugins
    log "INFO" "Updating App.tsx to include GitHub plugins..."
    
    # First, check if the plugins are already imported
    if ! grep -q "GithubActionsPlugin" packages/app/src/App.tsx; then
        # Add import statements at the top of the file, after React import
        sed -i.bak '1,/^import React/s/^import React/import { GithubActionsPlugin } from '"'"'@backstage/plugin-github-actions'"'"';\
import { GithubDeploymentsPlugin } from '"'"'@backstage/plugin-github-deployments'"'"';\
import { PullRequestsPage } from '"'"'@backstage/plugin-github-pull-requests-board'"'"';\
import React/' packages/app/src/App.tsx
    fi

    # Then, let's add the plugins to the FlatRoutes section if they don't exist
    if ! grep -q "element={<GithubActionsPlugin" packages/app/src/App.tsx; then
        sed -i.bak '/<Route path="\/catalog" element={<CatalogIndexPage \/>/a \
        <Route path="/github-actions" element={<GithubActionsPlugin />} />\
        <Route path="/github-deployments" element={<GithubDeploymentsPlugin />} />\
        <Route path="/pull-requests" element={<PullRequestsPage />} />
        ' packages/app/src/App.tsx
    fi
    
    # Remove backup file
    rm -f packages/app/src/App.tsx.bak
    
    # Update app-config.yaml with GitHub integration - without duplicating sections
    log "INFO" "Configuring GitHub integration..."

    # Update the GitHub integration section to consistently use environment variables
    if ! grep -q "integrations:" app-config.yaml; then
        # No integrations section exists, add the entire block
        cat <<EOF >> app-config.yaml

# GitHub integration
integrations:
  github:
    - host: github.com
      token: \${GITHUB_TOKEN}
EOF
    else
        # Integrations section exists, check if GitHub is already configured
        if ! grep -q "github:" app-config.yaml; then
            # Add just the GitHub integration under existing integrations section
            sed -i.bak "/integrations:/a\\
  github:\\
    - host: github.com\\
      token: \\\${GITHUB_TOKEN}" app-config.yaml
            rm -f app-config.yaml.bak
        else
            log "INFO" "GitHub integration already configured in app-config.yaml"
        fi
    fi

    # Now check for and add the template configuration if it doesn't exist
    if ! grep -q "catalog:" app-config.yaml || ! grep -q "locations:" app-config.yaml; then
        # Add catalog template locations configuration
        cat <<EOF >> app-config.yaml

# Template configuration
catalog:
  locations:
    - type: url
      target: https://raw.githubusercontent.com/${GITHUB_ORG}/${GITHUB_REPO}/main/templates/aks-clusters/template.yaml
      rules:
        - allow: [Template]
EOF
    else
        # Try to add the template location to existing catalog section
        log "INFO" "Catalog section already exists, attempting to add template location"
        if ! grep -q "${GITHUB_REPO}/main/templates/aks-clusters/template.yaml" app-config.yaml; then
            sed -i.bak "/locations:/a\
    - type: url\
      target: https://raw.githubusercontent.com/${GITHUB_ORG}/${GITHUB_REPO}/main/templates/aks-clusters/template.yaml\
      rules:\
        - allow: [Template]" app-config.yaml
            rm -f app-config.yaml.bak
        fi
    fi

    # Same for scaffolder section
    if ! grep -q "scaffolder:" app-config.yaml; then
        cat <<EOF >> app-config.yaml

scaffolder:
  # Actions that the scaffolder can use
  actions:
    - id: fetch:template
      type: url
      allowedHosts:
        - github.com
        - raw.githubusercontent.com
    - id: publish:github
      type: url
      allowedHosts:
        - github.com
EOF
    else
        log "INFO" "Scaffolder section already exists in app-config.yaml"
    fi
    
    # Check if the file exists first (use the correct path)
    if [[ -f "app-config.yaml" ]]; then
        # Create a temporary file
        touch app-config.yaml.tmp
        
        # Find the line number of the duplicate GitHub integration section
        duplicate_line=$(grep -n "^# GitHub integration$" app-config.yaml | tail -1 | cut -d: -f1)
        
        if [[ -n "$duplicate_line" ]]; then
            # Calculate section end (typically 4 lines)
            end_line=$((duplicate_line + 4))
            
            # Write to temporary file without the duplicate section
            awk "NR < $duplicate_line || NR > $end_line" app-config.yaml > app-config.yaml.tmp
            
            # Replace the original file
            mv app-config.yaml.tmp app-config.yaml
            
            echo "Removed duplicate GitHub integration section from app-config.yaml"
        else
            echo "No duplicate GitHub integration section found"
            rm -f app-config.yaml.tmp
        fi
    fi

    # Create template directories
    log "INFO" "Creating template directories..."
    mkdir -p ../templates/aks-clusters/skeleton
    
    # Create template.yaml
    log "INFO" "Creating template.yaml..."
    create_template_yaml
    
    # Create skeleton YAML
    log "INFO" "Creating skeleton template..."
    create_skeleton_yaml

    # Push templates to GitHub
    log "INFO" "Pushing templates to GitHub repository..."
    push_templates_to_github || {
        log "WARN" "Failed to push templates to GitHub automatically. You'll need to do this manually."
    }
    
    # Install and build Backstage
    log "INFO" "Installing and building Backstage..."
    # Use modern Yarn commands for v4+
    yarn install || {
        log "ERROR" "Failed to install Backstage dependencies."
        return 1
    }
    
    # Set GitHub token in the environment for Backstage
    export GITHUB_TOKEN="${GITHUB_TOKEN}"
    
    # Check if the package.json has a build script
    if grep -q "\"build\":" package.json; then
        log "INFO" "Running yarn build..."
        yarn build || {
            log "ERROR" "Failed to build Backstage."
            return 1
        }
    else
        log "INFO" "No build script found in package.json. This might be normal with newer Backstage versions."
        log "INFO" "Directly running yarn dev instead."
    fi
    
    log "INFO" "Backstage setup complete."
    log "INFO" "You can start Backstage by running: cd ${BACKSTAGE_DIR} && yarn dev"
    
    # Automatically start Backstage in the background
    log "INFO" "Starting Backstage automatically..."
    (cd "${BACKSTAGE_DIR}" && GITHUB_TOKEN="${GITHUB_TOKEN}" yarn dev &)
    
    # Wait for Backstage to start (typically takes 10-15 seconds)
    log "INFO" "Waiting for Backstage to start up (this may take a minute)..."
    sleep 15
    
    # Check if the service is running on port 3000
    if command -v nc &>/dev/null && nc -z localhost 3000 2>/dev/null; then
        log "INFO" "Backstage is now running on http://localhost:3000"
        # Open the browser on macOS
        if command -v open &>/dev/null; then
            open "http://localhost:3000"
        fi
    else
        log "WARN" "Backstage may still be starting up. Please visit http://localhost:3000 in your browser."
        # Try to open browser anyway
        if command -v open &>/dev/null; then
            open "http://localhost:3000" &>/dev/null || true
        fi
    fi
    
    return 0
}

# Remove Backstage installation
remove_backstage() {
    # Get the correct backstage directory from the current working directory
    local correct_backstage_dir
    correct_backstage_dir="backstage"
    
    if [[ ! -d "${correct_backstage_dir}" ]]; then
        log "INFO" "Backstage directory ${correct_backstage_dir} not found. Skipping."
        return 0
    fi
    
    # Confirm deletion
    if ! confirm_action "Do you want to delete the Backstage installation at ${correct_backstage_dir}?" "Y"; then
        log "INFO" "Skipping Backstage removal."
        return 0
    fi
    
    log "INFO" "Removing Backstage directory..."
    rm -rf "${correct_backstage_dir}" || {
        log "ERROR" "Failed to delete Backstage directory."
        return 1
    }
    
    log "INFO" "Backstage removed successfully."
    return 0
}

# Push templates to GitHub repository
push_templates_to_github() {
    log "INFO" "Pushing templates to GitHub repository..."
    
    # Create temp directory for git operations
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Clone the repository
    log "INFO" "Cloning repository ${GITHUB_ORG}/${GITHUB_REPO}..."
    git clone "https://${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${GITHUB_REPO}.git" "${temp_dir}" || {
        log "ERROR" "Failed to clone repository."
        return 1
    }
    
    # Create templates directory
    mkdir -p "${temp_dir}/templates/aks-clusters/skeleton"
    
    # Copy the template files from local to the cloned repo
    cp -f "../templates/aks-clusters/template.yaml" "${temp_dir}/templates/aks-clusters/"
    cp -f "../templates/aks-clusters/skeleton/cluster.yaml" "${temp_dir}/templates/aks-clusters/skeleton/"
    
    # Commit and push changes
    cd "${temp_dir}" || {
        log "ERROR" "Failed to change directory to cloned repo."
        return 1
    }
    
    git config user.name "${GITHUB_USER}"
    git config user.email "${GITHUB_USER}@users.noreply.github.com"
    
    git add templates/
    git commit -m "Add AKS cluster templates for Backstage" || {
        log "WARN" "No changes to commit or commit failed. Template might already exist."
        cd - > /dev/null
        rm -rf "${temp_dir}"
        return 0
    }
    
    git push || {
        log "ERROR" "Failed to push templates to GitHub."
        cd - > /dev/null
        rm -rf "${temp_dir}"
        return 1
    }
    
    cd - > /dev/null
    rm -rf "${temp_dir}"
    log "INFO" "Templates pushed to GitHub successfully."
    return 0
}

# Create template.yaml
create_template_yaml() {
    cat <<EOF > ../templates/aks-clusters/template.yaml
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: aks-cluster-template
  title: Azure Kubernetes Service Cluster
  description: Create a new AKS cluster using Cluster API
  tags:
    - kubernetes
    - azure
    - aks
    - cluster-api
spec:
  owner: platform-team
  type: infrastructure
  parameters:
    - title: Basic Cluster Configuration
      required:
        - clusterName
        - region
        - businessUnit
        - environment
        - owner
      properties:
        clusterName:
          title: Cluster Name
          type: string
          description: Name of your AKS cluster
          ui:autofocus: true
        environment:
          title: Environment
          type: string
          description: Target environment (dev, staging, prod)
          enum: ['development', 'staging', 'production']
        businessUnit:
          title: Business Unit
          type: string
          description: Which business unit owns this cluster
        owner:
          title: Owner Email
          type: string
          description: Email of the responsible team/individual
          
    - title: Azure Configuration
      required:
        - subscriptionId
        - region
      properties:
        subscriptionId:
          title: Azure Subscription ID
          type: string
          description: Azure subscription to deploy the cluster in
          default: "${AZURE_SUBSCRIPTION_ID}"
        region:
          title: Azure Region
          type: string
          description: Region to deploy the cluster
          enum: ['eastus', 'westus2', 'centralus', 'northeurope', 'westeurope']
          default: "eastus"
          
    - title: Cluster Configuration
      required:
        - kubernetesVersion
        - nodeCount
        - skuType
      properties:
        kubernetesVersion:
          title: Kubernetes Version
          type: string
          description: Kubernetes version to deploy
          default: "v${K8S_VERSION}"
          enum: ['v1.30.4', 'v1.31.3', 'v${K8S_VERSION}']
        nodeCount:
          title: Initial Node Count
          type: integer
          description: Number of worker nodes
          default: 3
          minimum: 1
          maximum: 10
        skuType:
          title: VM Size
          type: string
          description: Azure VM size for nodes
          default: "Standard_D4s_v5"
          enum: ['Standard_D2s_v5', 'Standard_D4s_v5', 'Standard_D8s_v5', 'Standard_D16s_v5']
        
    - title: Networking Configuration
      required:
        - vnetCidr
      properties:
        vnetCidr:
          title: VNet CIDR
          type: string
          description: CIDR block for the virtual network
          default: "10.0.0.0/16"
        nodeCidr:
          title: Node Subnet CIDR
          type: string
          description: CIDR block for the node subnet
          default: "10.0.0.0/22"

  steps:
    - id: generate-cluster-manifests
      name: Generate Cluster API manifests
      action: fetch:template
      input:
        url: ./skeleton
        targetPath: ./generated
        values:
          clusterName: \${{ parameters.clusterName }}
          environment: \${{ parameters.environment }}
          businessUnit: \${{ parameters.businessUnit }}
          owner: \${{ parameters.owner }}
          subscriptionId: \${{ parameters.subscriptionId }}
          region: \${{ parameters.region }}
          kubernetesVersion: \${{ parameters.kubernetesVersion }}
          nodeCount: \${{ parameters.nodeCount }}
          skuType: \${{ parameters.skuType }}
          vnetCidr: \${{ parameters.vnetCidr }}
          nodeCidr: \${{ parameters.nodeCidr }}
          
    - id: publish-to-github
      name: Publish to GitHub
      action: publish:github
      input:
        repoUrl: github.com?owner=${GITHUB_ORG}&repo=${GITHUB_REPO}
        title: Add AKS cluster \${{ parameters.clusterName }}
        description: |
          This PR adds a new AKS cluster with the following configuration:
          - Name: \${{ parameters.clusterName }}
          - Environment: \${{ parameters.environment }}
          - Region: \${{ parameters.region }}
          - Node type: \${{ parameters.skuType }}
          - Node count: \${{ parameters.nodeCount }}
        targetPath: clusters/\${{ parameters.clusterName }}
        branch: add-cluster-\${{ parameters.clusterName }}

  output:
    links:
      - title: GitHub Pull Request
        url: \${{ steps.publish-to-github.output.remoteUrl }}
EOF
}

# Create skeleton YAML template
create_skeleton_yaml() {
    cat <<EOF > ../templates/aks-clusters/skeleton/cluster.yaml
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: {{ clusterName }}
  namespace: default
  labels:
    environment: {{ environment }}
    businessUnit: {{ businessUnit }}
    owner: {{ owner }}
    managedBy: clusterapi
spec:
  clusterNetwork:
    services:
      cidrBlocks: ["10.1.0.0/16"]
    pods:
      cidrBlocks: ["10.0.0.0/16"]
    serviceDomain: "cluster.local"
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: AzureManagedControlPlane
    name: {{ clusterName }}-control-plane
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: AzureManagedCluster
    name: {{ clusterName }}
---
# Azure Resource Group
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureResourceGroup
metadata:
  name: rg-{{ businessUnit }}-aks-{{ environment }}-{{ region }}-001
  namespace: default
spec:
  location: {{ region }}
  tags:
    environment: {{ environment }}
    businessUnit: {{ businessUnit }}
    owner: {{ owner }}
    managedBy: clusterapi
---
# AKS Control Plane Configuration
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: AzureManagedControlPlane
metadata:
  name: {{ clusterName }}-control-plane
  namespace: default
spec:
  location: {{ region }}
  resourceGroupName: rg-{{ businessUnit }}-aks-{{ environment }}-{{ region }}-001
  subscriptionID: {{ subscriptionId }}
  version: {{ kubernetesVersion }}
  sshPublicKey: \${SSH_PUBLIC_KEY}
  dnsServiceIP: 10.1.0.10
  networkPolicy: cilium
  networkPlugin: azure
  networkPluginMode: "Overlay"
  disableLocalAccounts: true
  addonProfiles:
  - name: azurepolicy
    enabled: true
  - name: omsagent
    enabled: true
  - name: azureKeyvaultSecretsProvider
    enabled: true
  - name: cilium
    enabled: true
  identityRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: AzureClusterIdentity
    name: cluster-identity
  virtualNetwork:
    name: vnet-{{ businessUnit }}-aks-{{ environment }}-001
    cidrBlock: {{ vnetCidr }}
    subnet:
      name: snet-aks-nodes-{{ environment }}-001
      cidrBlock: {{ nodeCidr }}
---
# AKS Managed Cluster
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureManagedCluster
metadata:
  name: {{ clusterName }}
  namespace: default
spec:
  controlPlaneEndpoint:
    host: {{ clusterName }}.azmk8s.io
    port: 443
  identityRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: AzureClusterIdentity
    name: cluster-identity
  location: {{ region }}
  resourceGroupName: rg-{{ businessUnit }}-aks-{{ environment }}-{{ region }}-001
  tags:
    environment: {{ environment }}
    businessUnit: {{ businessUnit }}
    owner: {{ owner }}
    managedBy: clusterapi
---
# System Node Pool
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachinePool
metadata:
  name: {{ clusterName }}-system
  namespace: default
spec:
  clusterName: {{ clusterName }}
  replicas: {{ nodeCount }}
  template:
    spec:
      bootstrap:
        dataSecretName: ""
      clusterName: {{ clusterName }}
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: AzureManagedMachinePool
        name: {{ clusterName }}-system
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureManagedMachinePool
metadata:
  name: {{ clusterName }}-system
  namespace: default
spec:
  mode: System
  osDiskSizeGB: 128
  osDiskType: Managed
  vmSize: {{ skuType }}
  sku: AzureLinux
  enableAutoScaling: true
  minCount: {{ nodeCount }}
  maxCount: {{ nodeCount | twice }}
  maxPods: 30
  nodeLabels:
    nodepool: system
    nodetype: system
---
# Worker Node Pool
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachinePool
metadata:
  name: {{ clusterName }}-worker
  namespace: default
spec:
  clusterName: {{ clusterName }}
  replicas: {{ nodeCount }}
  template:
    spec:
      bootstrap:
        dataSecretName: ""
      clusterName: {{ clusterName }}
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: AzureManagedMachinePool
        name: {{ clusterName }}-worker
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureManagedMachinePool
metadata:
  name: {{ clusterName }}-worker
  namespace: default
spec:
  mode: User
  osDiskSizeGB: 128 
  osDiskType: Managed
  vmSize: {{ skuType }}
  sku: AzureLinux
  enableAutoScaling: true
  minCount: {{ nodeCount }}
  maxCount: {{ nodeCount | twice }}
  maxPods: 30
  nodeLabels:
    nodepool: workload
    nodetype: application
EOF
}

# =============================================================================
#                             MAIN SCRIPT
# =============================================================================

main() {
    trap 'handle_error $LINENO' ERR
    
    # Print script banner
    log "INFO" "===================================================================="
    log "INFO" "    Backstage + Cluster API Self-Service AKS Setup"
    log "INFO" "    Created for: ${GITHUB_USER}"
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
    │       █████╗ ███████╗██╗   ██╗██████╗ ███████╗       │
    │      ██╔══██╗╚══███╔╝██║   ██║██╔══██╗██╔════╝       │
    │      ███████║  ███╔╝ ██║   ██║██████╔╝█████╗         │
    │      ██╔══██║ ███╔╝  ██║   ██║██╔══██╗██╔══╝         │
    │      ██║  ██║███████╗╚██████╔╝██║  ██║███████╗       │
    │      ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝       │
    │                                                      │
    │        Verify Prequisites are installed...           │
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
    │     ██╗  ██╗ █████╗ ███████╗                         │
    │     ██║ ██╔╝██╔══██╗██╔════╝                         │
    │     █████╔╝ ╚█████╔╝███████╗                         │
    │     ██╔═██╗ ██╔══██╗╚════██║                         │
    │     ██║  ██╗╚█████╔╝███████║                         │
    │     ╚═╝  ╚═╝ ╚════╝ ╚══════╝                         │
    │                                                      │
    │           MANAGEMENT CLUSTER SETUP                   │
    │                                                      │
    ╰──────────────────────────────────────────────────────╯"
    create_management_cluster || exit 1
    
    log "INFO" "
    ╭──────────────────────────────────────────────────────╮
    │                                                      │
    │    ██████╗ █████╗ ██████╗ ██╗                        │
    │   ██╔════╝██╔══██╗██╔══██╗██║                        │
    │   ██║     ███████║██████╔╝██║                        │
    │   ██║     ██╔══██║██╔═══╝ ██║                        │
    │   ╚██████╗██║  ██║██║     ██║                        │
    │    ╚═════╝╚═╝  ╚═╝╚═╝     ╚═╝                        │
    │         CLUSTER API INSTALLATION                     │
    │                                                      │
    ╰──────────────────────────────────────────────────────╯"
    install_cluster_api || exit 1
    
    log "INFO" "
    ╭──────────────────────────────────────────────────────╮
    │                                                      │
    │   ███████╗██╗     ██╗   ██╗██╗  ██╗                  │
    │   ██╔════╝██║     ██║   ██║╚██╗██╔╝                  │
    │   █████╗  ██║     ██║   ██║ ╚███╔╝                   │
    │   ██╔══╝  ██║     ██║   ██║ ██╔██╗                   │
    │   ██║     ███████╗╚██████╔╝██╔╝ ██╗                  │
    │   ╚═╝     ╚══════╝ ╚═════╝ ╚═╝  ╚═╝                  │
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
    │   ██████╗  █████╗  ██████╗██╗  ██╗███████╗████████╗  │
    │   ██╔══██╗██╔══██╗██╔════╝██║ ██╔╝██╔════╝╚══██╔══╝  │
    │   ██████╔╝███████║██║     █████╔╝ ███████╗   ██║     │
    │   ██╔══██╗██╔══██║██║     ██╔═██╗ ╚════██║   ██║     │
    │   ██████╔╝██║  ██║╚██████╗██║  ██╗███████║   ██║     │
    │   ╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝   ╚═╝     │
    │             BACKSTAGE INSTALLATION                   │
    │                                                      │
    ╰──────────────────────────────────────────────────────╯"
    setup_backstage || exit 1
    
    log "INFO" "
    ╭──────────────────────────────────────────────────────╮
    │                                                      │
    │   ██████╗ ██████╗ ███╗   ███╗██████╗ ██╗     ███████╗│
    │  ██╔════╝██╔═══██╗████╗ ████║██╔══██╗██║     ██╔════╝│
    │  ██║     ██║   ██║██╔████╔██║██████╔╝██║     █████╗  │
    │  ██║     ██║   ██║██║╚██╔╝██║██╔═══╝ ██║     ██╔══╝  │
    │  ╚██████╗╚██████╔╝██║ ╚═╝ ██║██║     ███████╗███████╗│
    │   ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚══════╝╚══════╝│
    │                                                      │
    │       SETUP COMPLETED SUCCESSFULLY!                  │
    │                                                      │
    │  Backstage has been automatically started            │
    │  and should be available at http://localhost:3000    │
    │                                                      │
    ╰──────────────────────────────────────────────────────╯"
}

# Execute main function
main