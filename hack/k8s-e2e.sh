#!/bin/bash
#Copyright 2021 The hostpath provisioner Authors.
#
#Licensed under the Apache License, Version 2.0 (the "License");
#you may not use this file except in compliance with the License.
#You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
#Unless required by applicable law or agreed to in writing, software
#distributed under the License is distributed on an "AS IS" BASIS,
#WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#See the License for the specific language governing permissions and
#limitations under the License.
set -e
source ./cluster-up/hack/common.sh
source ./cluster-up/cluster/${KUBEVIRT_PROVIDER}/provider.sh

export KUBEVIRT_NUM_NODES=2
export KUBEVIRT_PROVIDER=k8s-1.23
make cluster-down
make cluster-up

if ! command -v go &> /dev/null
then
  wget https://dl.google.com/go/go1.16.7.linux-amd64.tar.gz
  tar -xzf go1.16.7.linux-amd64.tar.gz
  export GOROOT=$PWD/go
  export PATH=$GOROOT/bin:$PATH
  echo $PATH
fi

if ! command -v sshuttle &> /dev/null
then
  #Setup sshutle
  dnf install -y sshuttle

  docker_id=($(docker ps | grep vm | awk '{print $1}'))
  echo "docker node: [${docker_id[0]}]"

  #Get the key to connect.
  docker cp ${docker_id[0]}:/vagrant.key ./vagrant.key
  md5sum ./vagrant.key

  #Install python 3 on each node so sshuttle will work
  for i in $(seq 1 ${KUBEVIRT_NUM_NODES}); do
    ./cluster-up/ssh.sh "node$(printf "%02d" ${i})" "sudo dnf install -y python39"
  done
  #Look up the ssh port
  ssh_port=$(./cluster-up/cli.sh ports ssh)
  echo "ssh port: ${ssh_port}"
  #Start sshuttle
  sshuttle -r vagrant@127.0.0.1:${ssh_port} 192.168.66.0/24 -e 'ssh -o StrictHostKeyChecking=no -i ./vagrant.key'&
  SSHUTTLE_PID=$!
  function finish() {
    echo "TERMINATING SSHUTTLE!!!!"
    kill $SSHUTTLE_PID
  }
  trap finish EXIT
fi

echo "install hpp"
registry=${IMAGE_REGISTRY:-localhost:$(_port registry)}
echo "registry: ${registry}"
if [[ ${registry} == localhost* ]]; then
  echo "not verifying tls, registry contains localhost"
  export BUILDAH_PUSH_FLAGS="--tls-verify=false"
fi
DOCKER_REPO=${registry} make manifest manifest-push

#install hpp
_kubectl apply -f https://raw.githubusercontent.com/kubevirt/hostpath-provisioner-operator/main/deploy/namespace.yaml
_kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.6.1/cert-manager.yaml
_kubectl wait --for=condition=available -n cert-manager --timeout=120s --all deployments
_kubectl apply -f https://raw.githubusercontent.com/kubevirt/hostpath-provisioner-operator/main/deploy/webhook.yaml -n hostpath-provisioner
echo "Deploying"
_kubectl apply -f https://raw.githubusercontent.com/kubevirt/hostpath-provisioner-operator/main/deploy/operator.yaml -n hostpath-provisioner

echo "Waiting for it to be ready"
_kubectl rollout status -n hostpath-provisioner deployment/hostpath-provisioner-operator --timeout=120s

echo "Updating deployment"
_kubectl get pods -n hostpath-provisioner
# patch the correct development image name.
_kubectl patch deployment hostpath-provisioner-operator -n hostpath-provisioner --patch-file cluster-sync/patch.yaml
_kubectl rollout status -n hostpath-provisioner deployment/hostpath-provisioner-operator --timeout=120s
_kubectl wait --for=condition=available deployment -n hostpath-provisioner hostpath-provisioner-operator
_kubectl apply -f https://raw.githubusercontent.com/kubevirt/hostpath-provisioner-operator/main/deploy/hostpathprovisioner_legacy_cr.yaml
_kubectl apply -f https://raw.githubusercontent.com/kubevirt/hostpath-provisioner-operator/main/deploy/storageclass-wffc-legacy-csi.yaml
#Wait for hpp to be available.
_kubectl wait hostpathprovisioners.hostpathprovisioner.kubevirt.io/hostpath-provisioner --for=condition=Available --timeout=480s

_kubectl get sc hostpath-csi -o yaml

export KUBE_SSH_KEY_PATH=./vagrant.key
export KUBE_SSH_USER=vagrant

echo "KUBE_SSH_USER=${KUBE_SSH_USER}, KEY_FILE=${KUBE_SSH_KEY_PATH}"
#Download test
curl --location https://dl.k8s.io/v1.22.0/kubernetes-test-linux-amd64.tar.gz |   tar --strip-components=3 -zxf - kubernetes/test/bin/e2e.test kubernetes/test/bin/ginkgo
#Run test
# Some of these tests assume immediate binding, which is a random node, however if multiple volumes are involved sometimes they end up on different nodes and the test fails. Excluding that test.
./e2e.test -ginkgo.v -ginkgo.focus='External.Storage.*kubevirt.io.hostpath-provisioner' -ginkgo.skip='immediate binding|External.Storage.*should access to two volumes with the same volume mode and retain data across pod recreation on the same node \[LinuxOnly\]' -storage.testdriver=./hack/test-driver.yaml -provider=local

