# Bromure Client — Linux build container (Jenkinsfile.client-linux).
# Context: web-client/. Builds the web bundle + Electron main, runs the unit
# tests, and packages the Linux app for every arch in $ARCHES (x64 and arm64
# from either host arch: packaging only swaps Electron's prebuilt binary, the
# app itself has no native modules). Results in /home/node/artifacts.
FROM node:22-bookworm-slim

# desktop-file-utils: desktop-file-validate for the .deb's entry; dpkg-deb
# (dpkg, in the base image) inspects the .debs.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends ca-certificates desktop-file-utils \
 && rm -rf /var/lib/apt/lists/*

# WORKDIR alone would create the app dir root-owned.
RUN install -d -o node -g node /home/node/app
USER node
WORKDIR /home/node/app

# Dependencies first (cached until the lock changes), through the user's
# supply-chain wrapper like every other pipeline. The Electron binary for the
# HOST isn't needed (the packager downloads each target arch's own build).
COPY --chown=node:node package.json package-lock.json ./
ENV ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
    electron_config_cache=/home/node/.cache/electron
RUN npx --yes @socketsecurity/cli npm ci --no-audit --no-fund

COPY --chown=node:node . .
ENV ARCHES=x64,arm64
CMD ["sh", "ci/linux/build.sh"]
