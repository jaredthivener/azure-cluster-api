# 🚀 Azure Cluster API Automation ⚙️

This repository provides automation scripts to set up and tear down an **Azure Kubernetes Service (AKS)** management cluster with **Cluster API (CAPI)** and GitOps using **FluxCD**. The scripts are designed for self-service AKS provisioning and management, following best practices for Azure and Kubernetes.

---

## 🛠️ Prerequisites

- 🟦 [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`) `>= 2.50.0`
- ☸️ [kubectl](https://kubernetes.io/docs/tasks/tools/) `>= 1.25.0`
- 🔄 [Flux CLI](https://fluxcd.io/docs/installation/) `>= 2.1.0`
- 🏗️ [clusterctl](https://cluster-api.sigs.k8s.io/user/quick-start.html#install-clusterctl) `>= 1.5.0`
- 🎛️ [Helm](https://helm.sh/docs/intro/install/) `>= 3.13.0`
- 📦 [jq](https://stedolan.github.io/jq/) (for JSON parsing)
- ☁️ Azure subscription with sufficient permissions
- 🐙 GitHub Personal Access Token (PAT) with repo and workflow permissions

---

## ⚡ Setup

1. **Clone the repository:**  
   ```sh
   git clone https://github.com/jaredthivener/azure-cluster-api.git
   cd azure-cluster-api
   ```

2. **Configure the scripts:**  
   - ✏️ Edit `setup.sh` and update the Azure and GitHub configuration variables at the top of the script as needed.
   - 🔑 Ensure your GitHub PAT is set in the `GITHUB_TOKEN` variable or will be prompted at runtime.

3. **Run the setup script:**  
   ```sh
   ./setup.sh
   ```
   This will:
   - ✅ Verify prerequisites
   - 🔐 Log in to Azure and set the subscription
   - ☸️ Create the resource group and AKS management cluster (if not present)
   - 🏗️ Install Cluster API with Azure provider
   - 🔄 Bootstrap FluxCD for GitOps

---

## 🧹 Cleanup

To remove all resources created by the setup script, run:

```sh
./cleanup.sh
```

🛑 You will be prompted for confirmation before destructive actions.

---

## 📁 Directory Details

- `clusters/` — Contains FluxCD manifests and kustomizations for GitOps.
- `templates/cluster-templates/` — Contains reusable Cluster API templates.
- `templates/cluster-templates/skeleton/` — Example skeleton for a CAPI cluster.

---

## 💡 Notes

- 📝 The scripts log output to timestamped log files in the working directory.
- 🔒 Ensure you have the necessary Azure and GitHub permissions before running the scripts.
- ♻️ The scripts are idempotent and can be safely re-run; they check for existing resources before creating new ones.

---

## 🗺️ Diagram

See [`backstage-cluster-api.drawio`](backstage-cluster-api.drawio) for an architecture diagram of the setup.

---

## 📜 License

MIT License

---

**👤 Author:** Jared Thivener  
**📅 Created:** 2025-04-05
