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

# place storing the configuration secrets
GITHUB_TOKEN = ''
CONFIG_FILE_URL = 'https://raw.githubusercontent.com/user-name/kfp-secrets/master/creds.ini'

# generate default secret name
import os
import kfp
from kfp import components
from kfp import dsl
import ai_pipeline_params as params

secret_name = 'kfp-creds'
configuration_op = components.load_component_from_url('https://raw.githubusercontent.com/kubeflow/pipelines/master/components/ibm-components/commons/config/component.yaml')
train_op = components.load_component_from_url('https://raw.githubusercontent.com/kubeflow/pipelines/master/components/ibm-components/watson/train/component.yaml')
store_op = components.load_component_from_url('https://raw.githubusercontent.com/kubeflow/pipelines/master/components/ibm-components/watson/store/component.yaml')
deploy_op = components.load_component_from_url('https://raw.githubusercontent.com/kubeflow/pipelines/master/components/ibm-components/watson/deploy/component.yaml')
    
# create pipelines

@dsl.pipeline(
    name='KFP on WML training',
    description='Kubeflow pipelines running on WML performing tensorflow image recognition.'
)
def kfp_wml_pipeline(
    GITHUB_TOKEN=dsl.PipelineParam(name='github-token',
                                   value=''),
    CONFIG_FILE_URL=dsl.PipelineParam(name='config-file-url',
                                      value='https://raw.githubusercontent.com/user/repository/branch/creds.ini'),
    train_code=dsl.PipelineParam(name='train-code', value='tf-model.zip'),
    execution_command=dsl.PipelineParam(name='execution-command', value='\'python3 convolutional_network.py --trainImagesFile ${DATA_DIR}/train-images-idx3-ubyte.gz --trainLabelsFile ${DATA_DIR}/train-labels-idx1-ubyte.gz --testImagesFile ${DATA_DIR}/t10k-images-idx3-ubyte.gz --testLabelsFile ${DATA_DIR}/t10k-labels-idx1-ubyte.gz --learningRate 0.001 --trainingIters 20000\''),
    framework= dsl.PipelineParam(name='framework', value='tensorflow'),
    framework_version = dsl.PipelineParam(name='framework-version', value='1.5'),
    runtime = dsl.PipelineParam(name='runtime', value='python'),
    runtime_version = dsl.PipelineParam(name='runtime-version', value='3.5'),
    run_definition = dsl.PipelineParam(name='run-definition', value='wml-tensorflow-definition'),
    run_name = dsl.PipelineParam(name='run-name', value='wml-tensorflow-run'),
    model_name=dsl.PipelineParam(name='model-name', value='wml-tensorflow-mnist'),
    scoring_payload=dsl.PipelineParam(name='scoring-payload', value='tf-mnist-test-payload.json')
):
    # op1 - this operation will create the credentials as secrets to be used by other operations
    get_configuration = configuration_op(
                   token = GITHUB_TOKEN,
                   url = CONFIG_FILE_URL,
                   name = secret_name
    )
    
    # op2 - this operation trains the model with the model codes and data saved in the cloud object store
    wml_train = train_op(
                   get_configuration.output,
                   train_code,
                   execution_command
                   ).apply(params.use_ai_pipeline_params(secret_name))
    
    # op3 - this operation stores the model trained above
    wml_store = store_op(
                   wml_train.output,
                   model_name
                  ).apply(params.use_ai_pipeline_params(secret_name))
    
    # op4 - this operation deploys the model to a web service and run scoring with the payload in the cloud object store
    wml_deploy = deploy_op(
                  wml_store.output,
                  model_name,
                  scoring_payload
                 ).apply(params.use_ai_pipeline_params(secret_name))

if __name__ == '__main__':
    # compile the pipeline
    import kfp.compiler as compiler
    pipeline_filename = kfp_wml_pipeline.__name__ + '.zip'
    compiler.Compiler().compile(kfp_wml_pipeline, pipeline_filename)
