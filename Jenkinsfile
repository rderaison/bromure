pipeline {
    agent { label 'macosx-builder' }

    parameters {
        booleanParam(
            name: 'PUSH_RELEASE',
            defaultValue: false,
            description: 'Upload the signed DMG to DigitalOcean Spaces and register it with the appcast backend.'
        )
        choice(
            name: 'RELEASE_CHANNEL',
            choices: ['stable', 'beta'],
            description: 'Appcast channel the release is published on. Only used when PUSH_RELEASE is checked.'
        )
    }

    environment {
        KEYCHAIN_PASSWORD = credentials('KEYCHAIN_PASSWORD')
        BUILD_KEYCHAIN    = "${HOME}/build.keychain"

        // Non-secret Spaces config. The secrets (access key, private key,
        // auth token) live in Jenkins credentials.
        DO_SPACES_ENDPOINT    = 'https://sfo3.digitaloceanspaces.com'
        DO_SPACES_REGION      = 'sfo3'
        DO_SPACES_BUCKET      = 'bromure'
        DO_SPACES_PUBLIC_BASE = 'https://bromure.sfo3.cdn.digitaloceanspaces.com'
        RELEASE_API_URL       = 'https://bromure.io/api/v1/release'
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

        stage('Package') {
            steps {
                withCredentials([
                    string(credentialsId: 'DEVELOPER_ID',    variable: 'DEVELOPER_ID'),
                    string(credentialsId: 'APPLE_ID',        variable: 'APPLE_ID'),
                    string(credentialsId: 'TEAM_ID',         variable: 'TEAM_ID'),
                    string(credentialsId: 'APP_PASSWORD',    variable: 'APP_PASSWORD'),
                    file(credentialsId:   'PROVISION_PROFILE', variable: 'PROVISION_PROFILE')
                ]) {
                    sh '''
                        rm -f bromure.provisionprofile
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
                    DMG_FILENAME="Bromure-${BROMURE_VERSION}.dmg"
                    cp "$BUILD_DIR/Bromure.dmg" "${WORKSPACE}/${DMG_FILENAME}"
                '''
                archiveArtifacts artifacts: "Bromure-${BROMURE_VERSION}.dmg", fingerprint: true
            }
        }

        stage('Release') {
            when { expression { return params.PUSH_RELEASE } }
            steps {
                withCredentials([
                    string(credentialsId: 'SPARKLE_PRIVATE_KEY', variable: 'SPARKLE_PRIVATE_KEY'),
                    string(credentialsId: 'DO_SPACES_KEY',       variable: 'DO_SPACES_KEY'),
                    string(credentialsId: 'DO_SPACES_SECRET',    variable: 'DO_SPACES_SECRET'),
                    string(credentialsId: 'RELEASES_TOKEN',  variable: 'RELEASE_AUTH_TOKEN')
                ]) {
                    sh '''
                        set -euo pipefail

                        # Install the release-tool deps once per build. npm ci
                        # only when a lock file is committed; fall back to install.
                        (cd tools && if [ -f package-lock.json ]; then npm ci --silent; else npm install --silent; fi)

                        node tools/release-upload.mjs \
                            --file "${WORKSPACE}/Bromure-${BROMURE_VERSION}.dmg" \
                            --version "${BROMURE_VERSION}" \
                            --channel "${RELEASE_CHANNEL}" \
                            --min-system-version "14.0"
                    '''
                }
            }
        }
    }

    post {
        always {
            sh 'security default-keychain -s login.keychain-db || true'
        }
    }
}
