// Jenkins equivalent of .github/workflows/pipeline.yml.
//
// Both CI systems call the same Make targets and scripts/ci/*.sh, so the
// build, verification and deploy logic exists exactly once in this repo.
//
// Setup
//   - Multibranch Pipeline job (the `branch 'main'` conditions rely on it).
//   - Agent tools: bash, make, git, python3 with venv, docker, terraform >= 1.10,
//     aws CLI v2.
//   - Global environment variable TF_STATE_BUCKET = terraform/bootstrap output
//     state_bucket (Manage Jenkins > System > Global properties).
//   - "AWS Credentials" entry with id `aws-deploy` (AWS Credentials plugin), or
//     give the agent an instance profile and remove withAws().
//   - Plugins: Pipeline, Pipeline: Multibranch, JUnit, Timestamper,
//     Credentials Binding, AWS Credentials.

// Run a shell step with bash (the default /bin/sh has no pipefail) and the
// project virtualenv first on PATH.
def venv(String cmd) {
    withEnv(["PATH+VENV=${env.WORKSPACE}/.venv/bin"]) {
        sh "#!/bin/bash\nset -euo pipefail\n${cmd}"
    }
}

def shortSha(String sha) {
    return sha.length() > 12 ? sha.substring(0, 12) : sha
}

def withAws(Closure body) {
    withCredentials([[
        $class: 'AmazonWebServicesCredentialsBinding',
        credentialsId: 'aws-deploy',
        accessKeyVariable: 'AWS_ACCESS_KEY_ID',
        secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
    ]]) {
        body()
    }
}

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()   // one deploy per branch at a time
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timeout(time: 90, unit: 'MINUTES')
    }

    parameters {
        string(
            name: 'IMAGE_TAG_OVERRIDE',
            defaultValue: '',
            description: 'Redeploy an existing image tag (commit SHA) instead of building. Use it to roll back.'
        )
    }

    environment {
        AWS_REGION       = 'us-east-1'
        ECR_REPOSITORY   = 'aws-cicd-pipeline-app'
        TF_IN_AUTOMATION = 'true'
        IMAGE_NAME       = 'aws-cicd-pipeline-app'
    }

    stages {
        stage('Setup') {
            steps {
                script {
                    env.IMAGE_TAG = params.IMAGE_TAG_OVERRIDE?.trim() ?: sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${shortSha(env.IMAGE_TAG)}"
                }
                sh 'python3 -m venv .venv'
                venv 'make install install-lint'
            }
        }

        stage('Test') {
            steps {
                venv 'make lint-python test'
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'reports/junit.xml'
                }
            }
        }

        stage('Static checks') {
            parallel {
                stage('Terraform') {
                    steps { venv 'make tf-validate' }
                }
                stage('Ansible + shell') {
                    steps { venv 'make lint-ansible lint-shell' }
                }
            }
        }

        stage('Build image') {
            when { expression { !params.IMAGE_TAG_OVERRIDE?.trim() } }
            steps {
                venv 'make image IMAGE_TAG="$IMAGE_TAG"'
            }
        }

        stage('Verify image') {
            when { expression { !params.IMAGE_TAG_OVERRIDE?.trim() } }
            environment { VERIFY_CONTAINER = "app-verify-${env.BUILD_NUMBER}" }
            steps {
                venv 'make verify IMAGE_TAG="$IMAGE_TAG"'
            }
            post {
                always {
                    archiveArtifacts allowEmptyArchive: true, artifacts: 'reports/**'
                }
            }
        }

        stage('Push to ECR') {
            when {
                allOf {
                    branch 'main'
                    expression { !params.IMAGE_TAG_OVERRIDE?.trim() }
                }
            }
            steps {
                withAws { venv 'make push IMAGE_TAG="$IMAGE_TAG"' }
            }
        }

        stage('Deploy dev') {
            when { branch 'main' }
            steps {
                withAws { venv 'make deploy ENV=dev IMAGE_TAG="$IMAGE_TAG"' }
            }
            post {
                always { archiveArtifacts allowEmptyArchive: true, artifacts: 'reports/plan-dev.log, reports/environment-dev.json' }
            }
        }

        stage('Approve prod') {
            when { branch 'main' }
            steps {
                timeout(time: 2, unit: 'HOURS') {
                    input message: "Deploy ${shortSha(env.IMAGE_TAG)} to prod?", ok: 'Deploy'
                }
            }
        }

        stage('Deploy prod') {
            when { branch 'main' }
            steps {
                withAws { venv 'make deploy ENV=prod IMAGE_TAG="$IMAGE_TAG"' }
            }
            post {
                always { archiveArtifacts allowEmptyArchive: true, artifacts: 'reports/plan-prod.log, reports/environment-prod.json' }
            }
        }
    }

    post {
        always {
            sh 'docker rm -f "app-verify-$BUILD_NUMBER" >/dev/null 2>&1 || true'
        }
        cleanup {
            deleteDir()
        }
    }
}
