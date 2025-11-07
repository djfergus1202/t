#!/bin/bash
# deploy-k8s.sh - Automated Kubernetes Deployment Script for BioMed Research Suite

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="biomed-suite"
REGISTRY="${DOCKER_REGISTRY:-docker.io}"
IMAGE_NAME="${IMAGE_NAME:-biomed-suite}"
IMAGE_TAG="${IMAGE_TAG:-v3.0-fixed}"
CLUSTER_TYPE="${CLUSTER_TYPE:-generic}" # Options: gke, eks, aks, generic

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}   BioMed Research Suite - K8s Deployment${NC}"
echo -e "${BLUE}================================================${NC}"

# Function to check prerequisites
check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    # Check for kubectl
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}kubectl is not installed. Please install it first.${NC}"
        exit 1
    fi
    
    # Check for docker
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker is not installed. Please install it first.${NC}"
        exit 1
    fi
    
    # Check kubectl connection
    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}Cannot connect to Kubernetes cluster. Please configure kubectl.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Prerequisites satisfied${NC}"
}

# Function to build Docker image
build_docker_image() {
    echo -e "${YELLOW}Building Docker image...${NC}"
    
    if [ -f "Dockerfile.v2" ]; then
        docker build -f Dockerfile.v2 -t $REGISTRY/$IMAGE_NAME:$IMAGE_TAG .
    else
        docker build -t $REGISTRY/$IMAGE_NAME:$IMAGE_TAG .
    fi
    
    echo -e "${GREEN}✓ Docker image built successfully${NC}"
}

# Function to push Docker image
push_docker_image() {
    echo -e "${YELLOW}Pushing Docker image to registry...${NC}"
    
    # Login to registry if needed
    if [ "$REGISTRY" != "docker.io" ]; then
        echo "Please ensure you're logged in to $REGISTRY"
    fi
    
    docker push $REGISTRY/$IMAGE_NAME:$IMAGE_TAG
    echo -e "${GREEN}✓ Docker image pushed successfully${NC}"
}

# Function to create namespace
create_namespace() {
    echo -e "${YELLOW}Creating namespace...${NC}"
    
    kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
    echo -e "${GREEN}✓ Namespace created/verified${NC}"
}

# Function to deploy using kubectl
deploy_kubectl() {
    echo -e "${YELLOW}Deploying using kubectl...${NC}"
    
    # Apply the full deployment
    kubectl apply -f kubernetes-full-deployment.yaml -n $NAMESPACE
    
    echo -e "${GREEN}✓ Deployment applied${NC}"
}

# Function to deploy using Helm
deploy_helm() {
    echo -e "${YELLOW}Deploying using Helm...${NC}"
    
    # Check if Helm is installed
    if ! command -v helm &> /dev/null; then
        echo -e "${YELLOW}Helm not installed. Falling back to kubectl deployment.${NC}"
        deploy_kubectl
        return
    fi
    
    # Install or upgrade Helm release
    helm upgrade --install biomed-suite ./helm-chart \
        --namespace $NAMESPACE \
        --create-namespace \
        --set image.backend.repository=$REGISTRY/$IMAGE_NAME \
        --set image.backend.tag=$IMAGE_TAG \
        --wait
    
    echo -e "${GREEN}✓ Helm deployment completed${NC}"
}

# Function to deploy using Kustomize
deploy_kustomize() {
    echo -e "${YELLOW}Deploying using Kustomize...${NC}"
    
    # Update kustomization.yaml with correct image
    kubectl kustomize . | \
        sed "s|biomed-suite:.*|$REGISTRY/$IMAGE_NAME:$IMAGE_TAG|g" | \
        kubectl apply -n $NAMESPACE -f -
    
    echo -e "${GREEN}✓ Kustomize deployment completed${NC}"
}

# Function to wait for deployment
wait_for_deployment() {
    echo -e "${YELLOW}Waiting for deployment to be ready...${NC}"
    
    kubectl rollout status deployment/biomed-backend -n $NAMESPACE --timeout=300s
    kubectl rollout status deployment/biomed-frontend -n $NAMESPACE --timeout=300s
    
    echo -e "${GREEN}✓ All deployments ready${NC}"
}

# Function to get service URLs
get_service_urls() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}   Service Information${NC}"
    echo -e "${BLUE}================================================${NC}"
    
    # Get service details
    BACKEND_SERVICE=$(kubectl get svc biomed-backend-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    FRONTEND_SERVICE=$(kubectl get svc biomed-frontend-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    
    # Get ingress details
    INGRESS_HOST=$(kubectl get ingress biomed-ingress -n $NAMESPACE -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "not configured")
    INGRESS_IP=$(kubectl get ingress biomed-ingress -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    
    echo -e "${GREEN}Backend Service:${NC} $BACKEND_SERVICE"
    echo -e "${GREEN}Frontend Service:${NC} $FRONTEND_SERVICE"
    echo -e "${GREEN}Ingress Host:${NC} $INGRESS_HOST"
    echo -e "${GREEN}Ingress IP:${NC} $INGRESS_IP"
    
    # Port forwarding instructions
    echo ""
    echo -e "${YELLOW}For local access, use port forwarding:${NC}"
    echo "kubectl port-forward svc/biomed-backend-service 5000:80 -n $NAMESPACE"
    echo "kubectl port-forward svc/biomed-frontend-service 8080:80 -n $NAMESPACE"
}

# Function to run health check
health_check() {
    echo -e "${YELLOW}Running health check...${NC}"
    
    # Port forward for testing
    kubectl port-forward svc/biomed-backend-service 5000:80 -n $NAMESPACE &
    PF_PID=$!
    sleep 5
    
    # Test health endpoint
    if curl -s http://localhost:5000/api/health | grep -q "healthy"; then
        echo -e "${GREEN}✓ Health check passed${NC}"
    else
        echo -e "${RED}✗ Health check failed${NC}"
    fi
    
    kill $PF_PID 2>/dev/null
}

# Function for cloud-specific configurations
configure_cloud_provider() {
    case $CLUSTER_TYPE in
        gke)
            echo -e "${YELLOW}Configuring for GKE...${NC}"
            # GKE-specific configurations
            kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml
            ;;
        eks)
            echo -e "${YELLOW}Configuring for EKS...${NC}"
            # EKS-specific configurations
            kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/aws/deploy.yaml
            ;;
        aks)
            echo -e "${YELLOW}Configuring for AKS...${NC}"
            # AKS-specific configurations
            kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml
            ;;
        *)
            echo -e "${YELLOW}Using generic Kubernetes configuration...${NC}"
            ;;
    esac
}

# Main deployment flow
main() {
    echo "Starting deployment process..."
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --build)
                BUILD_IMAGE=true
                shift
                ;;
            --push)
                PUSH_IMAGE=true
                shift
                ;;
            --helm)
                USE_HELM=true
                shift
                ;;
            --kustomize)
                USE_KUSTOMIZE=true
                shift
                ;;
            --cluster-type)
                CLUSTER_TYPE="$2"
                shift 2
                ;;
            --registry)
                REGISTRY="$2"
                shift 2
                ;;
            --tag)
                IMAGE_TAG="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    # Run deployment steps
    check_prerequisites
    
    if [ "$BUILD_IMAGE" = true ]; then
        build_docker_image
    fi
    
    if [ "$PUSH_IMAGE" = true ]; then
        push_docker_image
    fi
    
    create_namespace
    configure_cloud_provider
    
    # Deploy using selected method
    if [ "$USE_HELM" = true ]; then
        deploy_helm
    elif [ "$USE_KUSTOMIZE" = true ]; then
        deploy_kustomize
    else
        deploy_kubectl
    fi
    
    wait_for_deployment
    get_service_urls
    health_check
    
    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}   Deployment Complete! 🎉${NC}"
    echo -e "${GREEN}================================================${NC}"
}

# Run main function
main "$@"
