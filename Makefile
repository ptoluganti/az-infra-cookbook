# set the shell to bash always
SHELL         := /bin/bash

# set make and shell flags to exit on errors
MAKEFLAGS     += --warn-undefined-variables
.SHELLFLAGS   := -euo pipefail -c

.EXPORT_ALL_VARIABLES:


DEPS := $(shell find . -type f -name "helm" -printf "%p ")
CURRENT_DIR=$(shell pwd)

KIND_CLUSTER_NAME := workshop.local
K8S_LATEST := 1.32.3

ARGOCD_HELM_RELEASE_NAME := gitops
ARGOCD_CHART_NAME := argo-cd
ARGOCD_CHART_REPO_URL := "https://argoproj.github.io/argo-helm"
ARGOCD_CHART_REPO := argo
ARGOCD_HELM_VALUES := "./gitops/argocd-values.yaml"
ARGOCD_CHART := "${ARGOCD_CHART_REPO}/${ARGOCD_CHART_NAME}"
ARGOCD_CHART_VERSION := "7.8.15"

AWX_HELM_RELEASE_NAME := awx
AWX_CHART_NAME := awx-operator
AWX_CHART_REPO_URL := "https://ansible-community.github.io/awx-operator-helm/"
AWX_CHART_REPO := awx-operator
AWX_HELM_VALUES := "./awx/awx-operator-values.yaml"
AWX_CHART := "${AWX_CHART_REPO}/${AWX_CHART_NAME}"
AWX_CHART_VERSION := "2.19.1"

.PHONY: help

# ====================================================================================
# Colors

BLUE         := $(shell printf "\033[34m")
YELLOW       := $(shell printf "\033[33m")
RED          := $(shell printf "\033[31m")
GREEN        := $(shell printf "\033[32m")
CNone        := $(shell printf "\033[0m")

# ====================================================================================
# Logger

TIME_LONG	= `date +%Y-%m-%d' '%H:%M:%S`
TIME_SHORT	= `date +%H:%M:%S`
TIME		= $(TIME_SHORT)

INFO	= echo ${TIME} ${BLUE}[ .. ]${CNone}
WARN	= echo ${TIME} ${YELLOW}[WARN]${CNone}
ERR		= echo ${TIME} ${RED}[FAIL]${CNone}
OK		= echo ${TIME} ${GREEN}[ OK ]${CNone}
FAIL	= (echo ${TIME} ${RED}[FAIL]${CNone} && false)

# ====================================================================================
# Help

# only comments after make target name are shown as help text
help: ## Displays this help message
	@echo -e "$$(grep -hE '^\S+:.*##' $(MAKEFILE_LIST) | sed -e 's/:.*##\s*/:/' -e 's/^\(.\+\):\(.*\)/\\x1b[36m\1\\x1b[m:\2/' | column -c2 -t -s : | sort)"


# ====================================================================================
# Kind

setup_local_cluster: create_kind_cluster 
	@skaffold run -p local-cluster-core

connect_registry_to_kind_network:
	docker network connect kind kind-registry || true;

connect_registry_to_kind: connect_registry_to_kind_network
	kubectl apply -f ./kind_configmap.yaml;

create_docker_registry:
	if ! docker ps | grep -q 'kind-registry'; \
	then docker run -d -p 127.0.0.1:5000:5000 --name kind-registry --restart=always registry:2; \
	else echo "---> kind-registry is already running. There's nothing to do here."; \
	fi

create_kind_cluster: create_docker_registry
	@$(INFO) "--- Create cluster --name ${KIND_CLUSTER_NAME} "
	@kind create cluster --image=kindest/node:v${K8S_LATEST} --name ${KIND_CLUSTER_NAME} --config ./kind_config.yaml || true
	@kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
	@kubectl get nodes
	@$(OK)  "--- Done ---"

create_kind_cluster_with_registry:  ## Create kind cluster with registry
	$(MAKE) create_kind_cluster && $(MAKE) connect_registry_to_kind && $(MAKE) install_ingress_controller && $(MAKE) install_metallb_native
	
install_ingress_controller:
	kubectl apply -f ./deploy-ingress-nginx.yaml && \
	sleep 5 && \
	kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=90s

# https://kind.sigs.k8s.io/docs/user/loadbalancer/
install_metallb_native:
	@kubectl apply -f ./metallb-native.yaml && \
	sleep 5 && \
	kubectl wait --namespace metallb-system \
		--for=condition=ready pod \
		--selector=app=metallb \
		--timeout=90s
	@kubectl apply -f ./metallb-config.yaml

delete_kind_cluster: ## Delete kind cluster
	@$(INFO) "--- delete cluster --name ${KIND_CLUSTER_NAME} "
	@kind delete cluster --name ${KIND_CLUSTER_NAME}
	@$(OK)  "--- Done ---"

# ====================================================================================
# AWX Operator
add_awx_repo: ## Helm Add AWX Repository
	@$(INFO) "--- helm repo add ${AWX_CHART_REPO} ${AWX_CHART_REPO_URL}"
	@helm repo add ${AWX_CHART_REPO} ${AWX_CHART_REPO_URL}
	@helm repo update
	@$(OK)  "--- Done ---"

install_awx_operator: add_awx_repo ## Helm Upgrade AWX chart
	@$(INFO) "------ Install AWX Operator --------"
	@$(INFO) "Current context"
	@kubectl config current-context
	@kubectl apply -f ./${AWX_HELM_RELEASE_NAME}/ns.yaml
	
	@$(INFO) "--- helm upgrade --install ${AWX_HELM_RELEASE_NAME} --namespace ${AWX_HELM_RELEASE_NAME} -f ${AWX_HELM_VALUES} ${AWX_CHART} --version ${AWX_CHART_VERSION}---"
	@helm upgrade --install ${AWX_HELM_RELEASE_NAME} --namespace ${AWX_HELM_RELEASE_NAME} -f ${AWX_HELM_VALUES} ${AWX_CHART} --version ${AWX_CHART_VERSION}
	@$(OK)  "--- Done ---"

create_awx_instace:
	@$(INFO) "------ Create AWX Instance --------"
	@$(INFO) "Current context"
	@kubectl config current-context
	@kubectl apply -f ./${AWX_HELM_RELEASE_NAME}/awx-instance.yaml
	@$(OK)  "--- Done ---"

# ====================================================================================
# ArgoCD  
add_argocd_repo: ## Helm Add ArgoCD Repository
	@$(INFO) "--- helm repo add ${ARGOCD_CHART_REPO} ${ARGOCD_CHART_REPO_URL}"
	@helm repo add ${ARGOCD_CHART_REPO} ${ARGOCD_CHART_REPO_URL}
	@helm repo update
	@$(OK)  "--- Done ---"

install_argocd: add_argocd_repo ## Helm Upgrade ArgoCD chart
	@$(INFO) "------ Install Argocd --------"
	@$(INFO) "Current context"
	@kubectl config current-context
	@kubectl apply -f ./${ARGOCD_HELM_RELEASE_NAME}/ns.yaml

	@$(INFO) "--- helm upgrade --install ${ARGOCD_HELM_RELEASE_NAME} --namespace ${ARGOCD_HELM_RELEASE_NAME} -f ${ARGOCD_HELM_VALUES} ${ARGOCD_CHART} --version ${ARGOCD_CHART_VERSION}---"
	@helm upgrade --install ${ARGOCD_HELM_RELEASE_NAME} --namespace ${ARGOCD_HELM_RELEASE_NAME} -f ${ARGOCD_HELM_VALUES} ${ARGOCD_CHART} --version ${ARGOCD_CHART_VERSION}

	# @kubectl wait --namespace ${ARGOCD_HELM_RELEASE_NAME} \
	# 	--for=condition=ready pod \
	# 	--selector=app.kubernetes.io/instance=${ARGOCD_HELM_RELEASE_NAME} \
	# 	--timeout=90s

	@kubectl apply -f ./${ARGOCD_HELM_RELEASE_NAME}/argocd-ui-ingress.yaml
	@$(OK)  "--- Done ---"