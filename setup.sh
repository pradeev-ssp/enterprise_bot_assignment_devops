
#!/bin/bash

set -e

# Create kind cluster if it does not exist
if ! kind get clusters | grep -q "^demo$"; then
    echo "Creating kind cluster..."
    kind create cluster --name demo
else
    echo "Kind cluster already exists"
fi

# Install ingress-nginx
echo "Installing ingress-nginx..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml

kubectl wait --namespace ingress-nginx \
    --for=condition=Ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s

# Build Docker image
echo "Building application image..."
docker build -t demo-app:v1 ./service

# Load image into kind
echo "Loading image into kind..."
kind load docker-image demo-app:v1 --name demo

# Create namespace
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -

# Deploy application using Helm
echo "Deploying application..."
helm upgrade --install demo ./chart \
    --namespace demo \
    --set image.repository=demo-app \
    --set image.tag=v1 \
    --set image.pullPolicy=IfNotPresent

# Wait for deployment
kubectl rollout status deployment/demo -n demo --timeout=180s

echo "Deployment completed successfully!"

kubectl get pods -n demo
kubectl get services -n demo
kubectl get ingress -n demo
