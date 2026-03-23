FROM arm64v8/alpine:3.22.3

RUN apk add --no-cache linux-lts-dev make gcc musl-dev

# Build rtc-pl031.ko from the kernel source tree
RUN KVER=$(ls /lib/modules/) && \
    KSRC=/lib/modules/$KVER/build && \
    mkdir -p /tmp/build && \
    echo 'obj-m := rtc-pl031.o' > /tmp/build/Makefile && \
    cp $KSRC/drivers/rtc/rtc-pl031.c /tmp/build/ 2>/dev/null || \
    wget -qO /tmp/build/rtc-pl031.c \
        "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/rtc/rtc-pl031.c?h=v${KVER%-0-lts}" && \
    make -C $KSRC M=/tmp/build modules && \
    mkdir -p /out && \
    cp /tmp/build/rtc-pl031.ko /out/ && \
    echo "$KVER" > /out/KVER

# Usage:
#   docker build --platform linux/arm64 -t rtc-pl031-builder .
#   docker create --name rtcbuild rtc-pl031-builder
#   docker cp rtcbuild:/out/rtc-pl031.ko .
#   docker cp rtcbuild:/out/KVER .
#   docker rm rtcbuild
