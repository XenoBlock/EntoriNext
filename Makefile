# EntoriNext root Makefile
#
# Builds a bootable Komodo ISO and the BusyBox initramfs.
# Komodo, limine, and busybox are git submodules of this repo.
#
# Layout
#   Komodo/     kernel source (builds KomImage)
#   limine/     bootloader (upstream, pinned)
#   busybox/    busybox source (upstream, pinned)
#   Userspace/  initramfs rootfs staging + generated initramfs.cpio

QEMU       := qemu-system-x86_64
QEMU_FLAGS := -m 2G -serial stdio --enable-kvm

all: Komodo-x64.iso

# ---- kernel ----
KOMIMAGE := Komodo/KomImage
$(KOMIMAGE):
	$(MAKE) -C Komodo

# ---- initramfs ----
# Userspace/rootfs is the staging dir. busybox comes from the submodule's
# source (must be built first); see initramfs target for the copy step.
INITRAMFS := Userspace/initramfs.cpio

initramfs: $(INITRAMFS)

$(INITRAMFS): Userspace/rootfs/bin/busybox
	cd Userspace/rootfs && find . -print0 | cpio -0ov --format=newc > ../initramfs.cpio

Userspace/rootfs/bin/busybox:
	@test -f /usr/bin/busybox && cp -f /usr/bin/busybox $@ || \
	 echo "ERROR: no static busybox at /usr/bin/busybox"

# ---- ISO ----
# Stage from submodules and pack with xorriso (same recipe the kernel used).
ISO_STAGE := iso

Komodo-x64.iso: $(KOMIMAGE) $(INITRAMFS)
	rm -rf $(ISO_STAGE)
	mkdir -p $(ISO_STAGE)/Limine $(ISO_STAGE)/EFI/Boot
	cp limine/limine-bios-cd.bin       $(ISO_STAGE)/Limine/
	cp limine/limine-bios.sys          $(ISO_STAGE)/Limine/
	cp limine/limine-uefi-cd.bin       $(ISO_STAGE)/Limine/
	cp limine/BOOTX64.EFI              $(ISO_STAGE)/EFI/Boot/bootx64.efi
	cp $(KOMIMAGE)                     $(ISO_STAGE)/EFI/Boot/KomImage
	cp $(INITRAMFS)                    $(ISO_STAGE)/initramfs.cpio
	cp boot-komodo/limine.conf         $(ISO_STAGE)/Limine/limine.conf
	xorriso -as mkisofs -R -r -J \
	    -b Limine/limine-bios-cd.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
	    -hfsplus -apm-block-size 2048 -efi-boot-part --efi-boot-image --protective-msdos-label \
	    --efi-boot Limine/limine-uefi-cd.bin -o $@ $(ISO_STAGE)
	rm -rf $(ISO_STAGE)
	@echo "ISO:  $@ ready."

# ---- run ----
run: Komodo-x64.iso
	$(QEMU) $(QEMU_FLAGS) -cdrom Komodo-x64.iso

clean:
	rm -rf $(ISO_STAGE) Komodo-x64.iso
	$(MAKE) -C Komodo clean
	rm -f $(INITRAMFS)

.PHONY: all initramfs run clean