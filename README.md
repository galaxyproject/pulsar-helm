# Pulsar-Helm

This repository contains Helm chart for Galaxy Project's Pulsar installations.

## Installation

### 1. Setting up persistent volumes

We first need to create a persistent volume for Pulsar to store its data. Here
is a minimal example of such a `myvolumes.yaml` persistent volume
configuration:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pulsar-data-pv
  labels:
    type: local
spec:
  storageClassName: standard # Or your cluster's storage class
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: "/mnt/data/pulsar" # For local testing only
  persistentVolumeReclaimPolicy: Retain
```

Note that the `hostPath` type is only suitable for single-node development
clusters, such as for local testing. For production purposes, you would use
your cloud provider's storage solutions.

We can now create the persistent volume as follows:

```console
kubectl apply -f myvolumes.yaml
```

### 2. Installing Pulsar with Helm

Now that the storage volume has been created, we can install Pulsar. Let us
create a `myvalues.yaml` file with our desired configuration, for example:

```yaml
# Basic Pulsar configuration
image:
  repository: galaxy/pulsar-kubernetes
  tag: "0.15.7"
  pullPolicy: IfNotPresent

# Storage configuration
persistence:
  enabled: true
  storageClass: "standard" # Must match your PV's storageClassName
  size: 20Gi
  mountPath: "/pulsar/files"

# Security - CHANGE THIS!
api_key: "your-secure-api-key-here"

# Service configuration
service:
  type: ClusterIP # or NodePort, LoadBalancer
  port: 8913

# Optional: Enable ingress for external access
ingress:
  enabled: false
  # className: nginx
  # hosts:
  #   - host: pulsar.example.com
  #     paths:
  #       - path: /
  #         pathType: Prefix
```

It is important to always use a strong, unique API key in production
environments.

We can now proceed with installing Pulsar using Helm chart with the given
configuration:

```console
helm install mypulsar ./pulsar -n pulsar --create-namespace -f myvalues.yaml
```

## Development

For local testing of Pulsar deployment on macOS using Colima, you can use
provided `Makefile`:

```console
make help                                  # Show all available commands
make setup-deps setup-colima setup-images  # 1. Setup dependencies
make setup-pv setup-pulsar                 # 2. Deploy Pulsar locally
make test-job                              # 3. Test job submission
make clean-pulsar clean-pv clean-colima    # 4. Tear down everything
```
