# Backstage on AKS

<img width="745" alt="Screenshot 2025-03-26 at 7 02 58 PM" src="https://github.com/user-attachments/assets/099b5328-9e70-461c-bc9a-cc62846f4eff" />

This repository contains resources and instructions for deploying [Backstage](https://backstage.io/) on Azure Kubernetes Service (AKS).

## Prerequisites

Before you begin, ensure you have the following:
- An active Azure subscription.
- Azure CLI installed and authenticated.
- Kubernetes CLI (`kubectl`) installed.
- Helm package manager installed.

## Deployment Steps

1. **Create an AKS Cluster**  
    Use the Azure CLI to create an AKS cluster:
    ```bash
    az aks create --resource-group <resource-group-name> --name <aks-cluster-name> --node-count 3 --enable-addons monitoring --generate-ssh-keys
    ```

2. **Connect to the Cluster**  
    Configure `kubectl` to connect to your AKS cluster:
    ```bash
    az aks get-credentials --resource-group <resource-group-name> --name <aks-cluster-name>
    ```

3. **Install Backstage**  
    Deploy Backstage using Helm:
    ```bash
    helm repo add backstage https://backstage.github.io/charts
    helm repo update
    helm install backstage backstage/backstage
    ```

4. **Access Backstage**  
    Retrieve the service URL to access Backstage:
    ```bash
    kubectl get svc --namespace default
    ```

## Cleanup

To delete the AKS cluster and resources:
```bash
az aks delete --resource-group <resource-group-name> --name <aks-cluster-name> --yes --no-wait
```

## Resources

- [Backstage Documentation](https://backstage.io/docs)
- [Azure Kubernetes Service Documentation](https://learn.microsoft.com/en-us/azure/aks/)

## License

This project is licensed under the [MIT License](LICENSE).
