pipeline {
    agent any
    options {
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }
    parameters {
        choice(name: 'ACTION', choices: ['PLAN', 'APPLY', 'DESTROY'], description: 'Preview, build/configure, or remove MongoDB lab')
        choice(name: 'SSH_MODE', choices: ['public', 'private'], description: 'Home Jenkins uses public; AWS Jenkins may use private')
    }
    environment {
        AWS_DEFAULT_REGION = 'eu-west-2'
        TF_IN_AUTOMATION = 'true'
        TF_INPUT = 'false'
        ANSIBLE = '/opt/jenkins-mongodb-venv/bin/ansible-playbook'
        LAB_TOKEN = "${env.BUILD_TAG}"
    }
    stages {
        stage('Checkout') {
            steps { deleteDir(); checkout scm }
        }
        stage('Check tools and configuration') {
            steps {
                sh 'aws sts get-caller-identity'
                sh '''
                    set -eu
                    test -r /var/lib/jenkins/mongodb-lab/backend.hcl
                    test -r /var/lib/jenkins/mongodb-lab/terraform.tfvars
                    test -r /var/lib/jenkins/.ssh/mongodb-lab
                    cp /var/lib/jenkins/mongodb-lab/terraform.tfvars terraform/terraform.tfvars
                    "$ANSIBLE" -i 'localhost,' ansible/install.yml --syntax-check
                    "$ANSIBLE" -i 'localhost,' ansible/configure.yml --syntax-check
                    python3 -m unittest discover -s tests -v
                '''
            }
        }
        stage('Terraform init and validate') {
            steps {
                dir('terraform') {
                    sh 'terraform init -no-color -backend-config=/var/lib/jenkins/mongodb-lab/backend.hcl'
                    sh 'terraform fmt -check && terraform validate -no-color'
                }
            }
        }
        stage('Plan') {
            steps {
                dir('terraform') {
                    sh '''
                        set -eu
                        if [ "$ACTION" = DESTROY ]; then
                            terraform plan -destroy -lock-timeout=60s -no-color -out=lab.tfplan
                        else
                            terraform plan -lock-timeout=60s -no-color -out=lab.tfplan
                        fi
                        terraform show -no-color lab.tfplan > plan.txt
                    '''
                }
                archiveArtifacts artifacts: 'terraform/plan.txt,terraform/.terraform.lock.hcl', fingerprint: true
            }
        }
        stage('Review plan') {
            when { expression { params.ACTION != 'PLAN' } }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: "Execute ${params.ACTION}? Review plan.txt. DESTROY or instance replacement deletes that node's data disk. APPLY also configures MongoDB and may restart members.", ok: 'Execute saved plan'
                }
            }
        }
        stage('Execute') {
            when { expression { params.ACTION != 'PLAN' } }
            steps {
                dir('terraform') { sh 'terraform apply -no-color -lock-timeout=60s lab.tfplan' }
            }
        }
        stage('Inventory') {
            when { expression { params.ACTION == 'APPLY' } }
            steps {
                sh 'terraform -chdir=terraform output -json nodes > nodes.json'
                sh 'python3 scripts/make_inventory.py --mode "$SSH_MODE"'
                archiveArtifacts artifacts: 'nodes.json', fingerprint: true
            }
        }
        stage('Install and configure replica set') {
            when { expression { params.ACTION == 'APPLY' } }
            steps {
                withCredentials([
                    string(credentialsId: 'mongodb-lab-keyfile', variable: 'MONGO_KEYFILE'),
                    usernamePassword(credentialsId: 'mongodb-lab-admin', usernameVariable: 'MONGO_ADMIN_USER', passwordVariable: 'MONGO_ADMIN_PASSWORD')
                ]) {
                    sh '''
                        set +x
                        set -eu
                        "$ANSIBLE" -i inventory.json ansible/install.yml
                        "$ANSIBLE" -i inventory.json ansible/configure.yml
                    '''
                }
                echo 'Verified: one primary, two secondaries, and a document written to and read from all three members.'
            }
        }
    }
    post {
        cleanup {
            sh 'rm -f terraform/lab.tfplan terraform/terraform.tfvars inventory.json known_hosts'
        }
    }
}
