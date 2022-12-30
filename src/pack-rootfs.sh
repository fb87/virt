#!/usr/bin/env bash

ARTIFACT_DIR=${1:-$PWD}
OUTPUT_DIR=${2:-${ARTIFACT_DIR}}

# generate boot script (u-boot boot script format)
${ARTIFACT_DIR}/mkimage -A arm -T script -C none -n "Xen QEMU boot script" -d boot.cmd ${ARTIFACT_DIR}/boot.scr
${ARTIFACT_DIR}/mkimage -A arm -T ramdisk -C gzip -d ${ARTIFACT_DIR}/initrd.img ${ARTIFACT_DIR}/initrd.img.gz

cat > boot.cmd <<-EOF
    fatload virtio 0:1 0x48000000 /Image
    fatload virtio 0:1 0x48800000 /initrd.img.gz

    setenv bootargs "root=/dev/ram0 rdinit=/sbin/init"
    booti 0x48000000 0x48800000 0x40000000
EOF

cat > genimage.cfg <<- EOF
    image boot.vfat {
        vfat {
            label = "VIRT_BOOT"
            files = {
                "${ARTIFACT_DIR}/xen",
                "${ARTIFACT_DIR}/Image",
                "${ARTIFACT_DIR}/initrd.img.gz",
                "${ARTIFACT_DIR}/boot.scr",
            }
        }

        size = 128M
    }

    image root.ext2 {
        ext2  {
            label = "VIRT_ROOT"
            use-mke2fs = true
        }
        
        size = 512M
    }

    image ${OUTPUT_DIR}/disk.img {
        hdimage {
        }

        partition boot {
            partition-type = 0xC
            bootable = "true"
            image = "boot.vfat"
        }

        partition root {
            partition-type = 0x83
            image = "root.ext2"
        }
    }
EOF

# generate the disk image
if [ -f ${ARTIFACT_DIR}/genimage ]; then
    ${ARTIFACT_DIR}/genimage --rootpath ${ARTIFACT_DIR}/_install
else
    genimage --rootpath ${ARTIFACT_DIR}/_install
fi
