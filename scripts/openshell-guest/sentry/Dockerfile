# Build container for the kernel sentry module (Jenkinsfile.sentry).
#
# Ubuntu 24.04 arm64: the same series and architecture as the guest images, so
# the archive's linux-headers-<ABI>-generic packages and Ubuntu's own compiler
# (gcc-13, what build.sh pins) are exactly what the guest kernels were built
# with. The kernel headers themselves are installed per ABI at run time by
# ci-build.sh, since the list of kernels to build is only known then.
#
# The build context is a directory holding this file, build.sh, ci-build.sh,
# source-hash.sh and the module source (Makefile, bromure_sentry.c/.h) — for an
# older release, that release's source with the current scripts. No bind
# mounts: the Jenkins agent runs Docker-in-Docker and can't share its workspace.
#
#   docker build --platform linux/arm64 -t bromure-sentry-builder <context>
#   docker run --name sentrybuild -e SOURCE_DATE_EPOCH=<epoch> bromure-sentry-builder
#   docker cp sentrybuild:/out ./out
FROM ubuntu:24.04

RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        build-essential gcc-13 kmod ca-certificates curl python3 \
 && rm -rf /var/lib/apt/lists/*

COPY Makefile bromure_sentry.c bromure_sentry.h build.sh ci-build.sh source-hash.sh /src/
RUN chmod 0755 /src/*.sh

ENTRYPOINT ["/src/ci-build.sh"]
