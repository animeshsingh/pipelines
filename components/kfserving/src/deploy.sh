#!/bin/bash -e

# Copyright 2018 The Kubeflow Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -x

KUBERNETES_NAMESPACE="${KUBERNETES_NAMESPACE:-kubeflow}"

while (($#)); do
   case $1 in
     "--model-name")
       shift
       MODEL_NAME="$1"
       shift
       ;;
     "--default-model-uri")
       shift
       DEFAULT_MODEL_URI="$1"
       shift
       ;;
     "--canary-model-uri")
       shift
       CANARY_MODEL_URI="$1"
       shift
       ;;
     "--canary-model-traffic")
       shift
       CANARY_MODEL_TRAFFIC="$1"
       shift
       ;;
     "--pvc-name")
       shift
       PVC_NAME="$1"
       shift
       ;;
     "--namespace")
       shift
       KUBERNETES_NAMESPACE="$1"
       shift
       ;;
     *)
       echo "Unknown argument: '$1'"
       exit 1
       ;;
   esac
done

if [ -z "${MODEL_NAME}" ]; then
  echo "You must specify a name for the model to be deployed"
  exit 1
fi

if [ -z "${DEFAULT_MODEL_URI}" ]; then
  echo "You must specify a path to the saved model"
  exit 1
fi

echo "Deploying the model '${DEFAULT_MODEL_URI}}'"

from kubernetes import client
from kfserving.api.kf_serving_api import KFServingApi
from kfserving.constants import constants
from kfserving.models.v1alpha1_model_spec import V1alpha1ModelSpec
from kfserving.models.v1alpha1_tensorflow_spec import V1alpha1TensorflowSpec
from kfserving.models.v1alpha1_kf_service_spec import V1alpha1KFServiceSpec
from kfserving.models.v1alpha1_kf_service import V1alpha1KFService

default_model_spec = V1alpha1ModelSpec(tensorflow=V1alpha1TensorflowSpec(
    model_uri='gs://kfserving-samples/models/tensorflow/flowers'))

kfsvc = V1alpha1KFService(api_version=constants.KFSERVING_GROUP + '/' + constants.KFSERVING_VERSION,
                          kind=constants.KFSERVING_KIND,
                          metadata=client.V1ObjectMeta(name='flower-sample'),
                          spec=V1alpha1KFServiceSpec(default=default_model_spec))

KFServing = KFServingApi()
KFServing.deploy(kfsvc, namespace='kubeflow')

KFServing.get('flower-sample', namespace='kubeflow')

# Connect kubectl to the local cluster
kubectl config set-cluster "${CLUSTER_NAME}" --server=https://kubernetes.default --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
kubectl config set-credentials pipeline --token "$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
kubectl config set-context kubeflow --cluster "${CLUSTER_NAME}" --user pipeline
kubectl config use-context kubeflow

# Configure and deploy the TF serving app
cd /src/github.com/kubeflow/kubeflow
git checkout ${KUBEFLOW_VERSION}

cd /opt
echo "Initializing KSonnet app..."
ks init tf-serving-app
cd tf-serving-app/

if [ -n "${KUBERNETES_NAMESPACE}" ]; then
  echo "Setting Kubernetes namespace: ${KUBERNETES_NAMESPACE} ..."
  ks env set default --namespace "${KUBERNETES_NAMESPACE}"
fi

echo "Installing Kubeflow packages..."
ks registry add kubeflow /src/github.com/kubeflow/kubeflow/kubeflow
ks pkg install kubeflow/common@${KUBEFLOW_VERSION}
ks pkg install kubeflow/tf-serving@${KUBEFLOW_VERSION}

echo "Generating the TF Serving config..."
ks generate tf-serving server --name="${SERVER_NAME}"
ks param set server modelPath "${MODEL_EXPORT_PATH}"

# service type: ClusterIP or NodePort
if [ -n "${SERVICE_TYPE}" ];then
  ks param set server serviceType "${SERVICE_TYPE}"
fi

# support local storage to deploy tf-serving.
if [ -n "${PVC_NAME}" ];then
  # TODO: Remove modelStorageType setting after the hard code nfs was removed at
  # https://github.com/kubeflow/kubeflow/blob/v0.4-branch/kubeflow/tf-serving/tf-serving.libsonnet#L148-L151
  ks param set server modelStorageType nfs
  ks param set server nfsPVC "${PVC_NAME}"
fi

echo "Deploying the TF Serving service..."
ks apply default -c server

# Wait for the deployment to have at least one available replica
echo "Waiting for the TF Serving deployment to show up..."
timeout="1000"
start_time=`date +%s`
while [[ $(kubectl get deploy --namespace "${KUBERNETES_NAMESPACE}" --selector=app="${SERVER_NAME}" 2>&1|wc -l) != "2" ]];do
  current_time=`date +%s`
  elapsed_time=$(expr $current_time + 1 - $start_time)
  if [[ $elapsed_time -gt $timeout ]];then
    echo "timeout"
    exit 1
  fi
  sleep 2
done

echo "Waiting for the valid workflow json..."
start_time=`date +%s`
exit_code="1"
while [[ $exit_code != "0" ]];do
  kubectl get deploy --namespace "${KUBERNETES_NAMESPACE}" --selector=app="${SERVER_NAME}" --output=jsonpath='{.items[0].status.availableReplicas}'
  exit_code=$?
  current_time=`date +%s`
  elapsed_time=$(expr $current_time + 1 - $start_time)
  if [[ $elapsed_time -gt $timeout ]];then
    echo "timeout"
    exit 1
  fi
  sleep 2
done

echo "Waiting for the TF Serving deployment to have at least one available replica..."
start_time=`date +%s`
while [[ $(kubectl get deploy --namespace "${KUBERNETES_NAMESPACE}" --selector=app="${SERVER_NAME}" --output=jsonpath='{.items[0].status.availableReplicas}') < "1" ]]; do
  current_time=`date +%s`
  elapsed_time=$(expr $current_time + 1 - $start_time)
  if [[ $elapsed_time -gt $timeout ]];then
    echo "timeout"
    exit 1
  fi
  sleep 5
done

echo "Obtaining the pod name..."
start_time=`date +%s`
pod_name=""
while [[ $pod_name == "" ]];do
  pod_name=$(kubectl get pods --namespace "${KUBERNETES_NAMESPACE}" --selector=app="${SERVER_NAME}" --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}')
  current_time=`date +%s`
  elapsed_time=$(expr $current_time + 1 - $start_time)
  if [[ $elapsed_time -gt $timeout ]];then
    echo "timeout"
    exit 1
  fi
  sleep 2
done
echo "Pod name is: " $pod_name

# Wait for the pod container to start running
echo "Waiting for the KF Serving pod to start running..."
start_time=`date +%s`
exit_code="1"
while [[ $exit_code != "0" ]];do
  kubectl get po ${pod_name} --namespace "${KUBERNETES_NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].state.running}'
  exit_code=$?
  current_time=`date +%s`
  elapsed_time=$(expr $current_time + 1 - $start_time)
  if [[ $elapsed_time -gt $timeout ]];then
    echo "timeout"
    exit 1
  fi
  sleep 2
done

start_time=`date +%s`
while [ -z "$(kubectl get po ${pod_name} --namespace "${KUBERNETES_NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].state.running}')" ]; do
  current_time=`date +%s`
  elapsed_time=$(expr $current_time + 1 - $start_time)
  if [[ $elapsed_time -gt $timeout ]];then
    echo "timeout"
    exit 1
  fi
  sleep 5
done

# Wait a little while and then grab the logs of the running server
sleep 10
echo "Logs from the TF Serving pod:"
kubectl logs ${pod_name} --namespace "${KUBERNETES_NAMESPACE}"
