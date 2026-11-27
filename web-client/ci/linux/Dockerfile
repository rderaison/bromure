# Bromure Client — Linux build container (Jenkinsfile.client-linux).
# Context: web-client/. Builds the web bundle + Electron main, runs the unit
# tests, and packages the Linux app for every arch in $ARCHES (x64 and arm64
# from either host arch: packaging only swaps Electron's prebuilt binary, the
# app itself has no native modules). Results in /home/node/artifacts.
# BuildKit (docker buildx): the Go stage runs on the build platform.

# The network tunnel's program (web-client/tunnel: Go, stdlib only, static):
# cross-compiled for both arches on the build platform, no emulation.
FROM --platform=$BUILDPLATFORM golang:1.27.4-bookworm AS tunnel
WORKDIR /src
COPY tunnel/ ./
COPY package.json /package.json
RUN go vet ./... && go test ./... \
 && v=$(sed -n 's/^  "version": *"\([^"]*\)".*/\1/p' /package.json) \
 && for a in amd64 arm64; do \
      CGO_ENABLED=0 GOOS=linux GOARCH=$a go build -trimpath -ldflags "-s -w -X main.version=$v" -o /out/$a/bromure-client-tunnel . || exit 1; \
    done

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
COPY --from=tunnel /out /home/node/tunnel-bin
ENV ARCHES=x64,arm64 \
    BROMURE_TUNNEL_PREBUILT=/home/node/tunnel-bin
CMD ["sh", "ci/linux/build.sh"]
