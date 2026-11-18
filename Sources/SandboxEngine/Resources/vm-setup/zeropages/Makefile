# Out-of-tree build of bromure_zeropages. setup.sh builds it in the image
# chroot for the installed kernel, not the running one:
#   make -C /usr/src/bromure-zeropages KVER=6.8.0-149-generic
# (M= uses CURDIR, not PWD: under `make -C` PWD is still the caller's
# directory.)
KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

obj-m += bromure_zeropages.o

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
