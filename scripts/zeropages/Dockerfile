# Build container for the bromure_zeropages kernel module (Jenkinsfile.zeropages).
#
# Ubuntu 24.04 arm64, the series and architecture of the guest images, so the
# archive's linux-headers-<ABI>-generic packages and Ubuntu's own compiler are
# what the guest kernels were built with. Headers are installed per ABI at run
# time by ci-build.sh. The build context holds this file, the scripts and the
# module source (Makefile, bromure_zeropages.c); no bind mounts (the Jenkins
# agent is Docker-in-Docker).
FROM ubuntu:24.04

RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        build-essential gcc-13 kmod ca-certificates curl python3 \
 && rm -rf /var/lib/apt/lists/*

COPY Makefile bromure_zeropages.c build.sh ci-build.sh source-hash.sh /src/
RUN chmod 0755 /src/*.sh

ENTRYPOINT ["/src/ci-build.sh"]
