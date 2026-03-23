FROM arm64v8/alpine:3.22.3

RUN apk add --no-cache linux-lts-dev make gcc musl-dev

ARG V4L2LOOPBACK_VERSION=0.15.3
RUN wget -qO /tmp/v4l2loopback.tar.gz \
        "https://github.com/umlaeute/v4l2loopback/archive/refs/tags/v${V4L2LOOPBACK_VERSION}.tar.gz" && \
    tar xzf /tmp/v4l2loopback.tar.gz -C /tmp/

RUN KVER=$(ls /lib/modules/) && \
    make -C /lib/modules/$KVER/build M=/tmp/v4l2loopback-${V4L2LOOPBACK_VERSION} modules && \
    mkdir -p /out && \
    cp /tmp/v4l2loopback-${V4L2LOOPBACK_VERSION}/v4l2loopback.ko /out/ && \
    echo "$KVER" > /out/KVER

# Usage:
#   docker build --platform linux/arm64 -t v4l2loopback-builder .
#   docker create --name v4l2lb v4l2loopback-builder
#   docker cp v4l2lb:/out/v4l2loopback.ko .
#   docker cp v4l2lb:/out/KVER .
#   docker rm v4l2lb
