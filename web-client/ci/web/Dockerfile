# Bromure Client — hosted web app image (bromure.io/client/, Jenkinsfile.client-web).
# Context: web-client/. Stage 1 builds the bundle with absolute /client/ asset
# URLs (npm run build:web → dist-web/); stage 2 serves it as static files on
# :8080 as an unprivileged user. The edge routes path_beg /client here and sets
# Referrer-Policy; everything else (CSP, COOP, nosniff, caching) is ci/web/nginx.conf.
# The bundle is platform-independent: build it natively on the CI host, so the
# linux/amd64 image needs no emulation (its stage only copies files).
FROM --platform=$BUILDPLATFORM node:22-bookworm-slim AS build
RUN install -d -o node -g node /home/node/app
USER node
WORKDIR /home/node/app
COPY --chown=node:node package.json package-lock.json ./
# The web bundle needs no Electron binary.
ENV ELECTRON_SKIP_BINARY_DOWNLOAD=1
RUN npx --yes @socketsecurity/cli npm ci --no-audit --no-fund
COPY --chown=node:node . .
RUN npm test && npm run build:web && find dist-web -name '*.map' -delete

FROM nginxinc/nginx-unprivileged:stable-alpine
COPY ci/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY ci/web/security-headers.conf /etc/nginx/snippets/security-headers.conf
COPY --from=build /home/node/app/dist-web /usr/share/nginx/html/client
EXPOSE 8080
