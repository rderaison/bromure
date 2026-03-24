pipeline {
    agent { label 'macosx-builder' }

    environment {
        KEYCHAIN_PASSWORD = credentials('KEYCHAIN_PASSWORD')
        BUILD_KEYCHAIN    = "${HOME}/build.keychain"
    }

    stages {
        stage('Unlock Keychain') {
            steps {
                sh '''
                    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$BUILD_KEYCHAIN"
                    security list-keychains -s "$BUILD_KEYCHAIN" login.keychain-db
                    security default-keychain -s "$BUILD_KEYCHAIN"
                '''
            }
        }

        stage('Test') {
            options {
                timeout(time: 10, unit: 'MINUTES')
            }
            steps {
                sh 'script -q /dev/null swift test -c release'
            }
        }

        stage('Package') {
            steps {
                withCredentials([
                    string(credentialsId: 'DEVELOPER_ID', variable: 'DEVELOPER_ID'),
                    string(credentialsId: 'APPLE_ID',     variable: 'APPLE_ID'),
                    string(credentialsId: 'TEAM_ID',      variable: 'TEAM_ID'),
                    string(credentialsId: 'APP_PASSWORD',  variable: 'APP_PASSWORD'),
                    file(credentialsId: 'PROVISION_PROFILE', variable: 'PROVISION_PROFILE')
                ]) {
                    sh '''
                        cp "$PROVISION_PROFILE" bromure.provisionprofile
                        ./package.sh
                    '''
                }
            }
        }

        stage('Archive') {
            steps {
                sh '''
                    BUILD_DIR=$(swift build -c release --arch arm64 --show-bin-path 2>/dev/null)
                    cp "$BUILD_DIR/Bromure.dmg" "${WORKSPACE}/Bromure.dmg"
                '''
                archiveArtifacts artifacts: 'Bromure.dmg', fingerprint: true
            }
        }
    }

    post {
        always {
            sh 'security default-keychain -s login.keychain-db || true'
        }
    }
}
