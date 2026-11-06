
#!/bin/bash

set -e

# Create kind cluster if it does not exist
if ! kind get clusters | grep -q "^demo$"; then
    echo "Creating kind cluster..."

    KIND_CONFIG=$(mktemp)

    cat > "$KIND_CONFIG" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    labels:
      ingress-ready: "true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF

    kind create cluster --name demo --config "$KIND_CONFIG"

    rm -f "$KIND_CONFIG"
else
    echo "Kind cluster already exists"
fi

# Set kubectl context
kubectl config use-context kind-demo

# Ensure ingress node label exists
kubectl label node demo-control-plane ingress-ready=true --overwrite

# Install ingress-nginx
echo "Installing ingress-nginx..."

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml

kubectl rollout status deployment/ingress-nginx-controller \
    -n ingress-nginx \
    --timeout=180s

# Build Docker image
echo "Building application image..."

docker build -t demo-app:v1 ./service

# Load image into kind
echo "Loading image into kind..."

kind load docker-image demo-app:v1 --name demo

# Create namespace if it does not exist
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -

# Deploy application using Helm
echo "Deploying application..."

helm upgrade --install demo ./chart \
    --namespace demo \
    --set image.repository=demo-app \
    --set image.tag=v1 \
    --set image.pullPolicy=IfNotPresent \
    --wait \
    --timeout=180s

echo "Deployment completed successfully!"

# Display deployment status
kubectl get pods -n demo
kubectl get services -n demo
kubectl get ingress -n demo
