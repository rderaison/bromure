# Out-of-tree build of the sentry module.
#
#   make                                 build against the running kernel
#   make KVER=6.8.0-139-generic          build against a specific one
#
# `build.sh` wraps this for the release-time build that produces the prebuilt
# .ko shipped through the meta share.
obj-m := bromure_sentry.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: all clean
