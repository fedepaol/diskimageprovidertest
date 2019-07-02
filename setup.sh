#!/bin/bash -e
set -x


export NO_PROXY="localhost,127.0.0.1,172.17.0.2"

CLUSTER_NAME=sriov-ci
CLUSTER_CONTROL_PLANE=${CLUSTER_NAME}-control-plane
CONTAINER_REGISTRY_HOST="localhost:5000"

CLUSTER_CMD="docker exec -it -d ${CLUSTER_CONTROL_PLANE}"

function wait_containers_ready {
    # wait until all containers are ready
    while [ -n "$(kubectl get pods --all-namespaces -o'custom-columns=status:status.containerStatuses[*].ready,metadata:metadata.name' --no-headers | grep false)" ]; do
        echo "Waiting for all containers to become ready ..."
        kubectl get pods --all-namespaces -o'custom-columns=status:status.containerStatuses[*].ready,metadata:metadata.name' --no-headers
        sleep 10
    done
}


function wait_kubevirt_up {
    # it takes a while for virt-operator to schedule virt pods; wait for at least one of them to pop up
    while [ -z "$(kubectl get pods -n kubevirt | grep virt)" ]; do
        echo "Waiting for all pods to create ..."
        kubectl get pods -n kubevirt | grep virt
	sleep 10
    done

    wait_containers_ready
}

function finish {
    ~/go/bin/kind delete cluster --name=${CLUSTER_NAME}
}

trap finish EXIT

# Create the cluster...
~/go/bin/kind --loglevel debug create cluster --wait=$((60*60))s --retain --name=${CLUSTER_NAME} --config=./diskimageprovidersample/kind.yaml --image=onesourceintegrations/node:multus

export KUBECONFIG=$(~/go/bin/kind get kubeconfig-path --name=${CLUSTER_NAME})

kubectl cluster-info

# copied from https://github.com/kubernetes-sigs/federation-v2/blob/master/scripts/create-clusters.sh
function configure-insecure-registry-and-reload() {
    local cmd_context="${1}" # context to run command e.g. sudo, docker exec
    ${cmd_context} "$(insecure-registry-config-cmd)"
    ${cmd_context} "$(reload-docker-daemon-cmd)"
}

function reload-docker-daemon-cmd() {
    echo "kill -s SIGHUP \$(pgrep dockerd)"
}

function insecure-registry-config-cmd() {
    echo "cat <<EOF > /etc/docker/daemon.json
{
    \"insecure-registries\": [\"${CONTAINER_REGISTRY_HOST}\"]
}
EOF
"
}

configure-insecure-registry-and-reload "${CLUSTER_CMD} bash -c"

# wait for nodes to become ready
until kubectl get nodes --no-headers
do
    echo "Waiting for all nodes to become ready ..."
    sleep 10
done

# wait until k8s pods are running
while [ -n "$(kubectl get pods --all-namespaces --no-headers | grep -v Running)" ]; do
    echo "Waiting for all pods to enter the Running state ..."
    kubectl get pods --all-namespaces --no-headers | >&2 grep -v Running || true
    sleep 10
done

# wait until all containers are ready
wait_containers_ready

# start local registry
until [ -z "$(docker ps -a | grep registry)" ]; do
    docker stop registry || true
    docker rm registry || true
    sleep 5
done

docker run -d -p 5000:5000 --restart=always --name registry registry:2
${CLUSTER_CMD} socat TCP-LISTEN:5000,fork TCP:$(docker inspect --format '{{.NetworkSettings.IPAddress }}' registry):5000

# ===============
# deploy kubevirt
# ===============
export KUBEVIRT_PROVIDER=external
export DOCKER_PREFIX=${CONTAINER_REGISTRY_HOST}/kubevirt
export DOCKER_TAG=devel

make cluster-build
make cluster-deploy
wait_kubevirt_up