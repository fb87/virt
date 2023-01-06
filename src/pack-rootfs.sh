#!/usr/bin/env bash

ARTIFACT_DIR=${1:-$PWD}
OUTPUT_DIR=${2:-${ARTIFACT_DIR}}

# generate dtb
qemu-system-aarch64 -machine virt,gic_version=3 -machine virtualization=true -cpu cortex-a57 \
    -machine type=virt -m 2G -display none -machine dumpdtb=${ARTIFACT_DIR}/virt-gicv3.dtb

# add the convinience script to start qemu, this makes life easier
# we can do overlaying but i'm kinda lazy
cat > ${OUTPUT_DIR}/start-qemu.sh <<-EOF
    #!/usr/bin/env bash

    qemu-system-aarch64 -nographic -machine virt,gic_version=3 -no-reboot -no-shutdown \
        -machine virtualization=true -cpu cortex-a57 -machine type=virt \
        -m 2G -bios ${OUTPUT_DIR}/u-boot.bin -drive format=raw,file=${OUTPUT_DIR}/disk.img
EOF

kernel_size=$(printf "%x\n" `stat -c "%s" ${OUTPUT_DIR}/Image`)
initrd_size=$(printf "%x\n" `stat -c "%s" ${OUTPUT_DIR}/initrd.img`)
dtb_size=$(printf "%x\n" `stat -c "%s" ${OUTPUT_DIR}/virt-gicv3.dtb`)

# QEMU RAM address starts from H'4000_0000
# 256MiB = H'1000_0000
# 512MiB = H'2090_0000
# 1  GiB = H'4000_0000
# 2  GiB = H'8000_0000
# 16 MiB = H'  10_0000
# Note: 0x040200000 - address of boot.scr
cat > boot.cmd <<-EOF
    setenv dtb_addr 0x40000000
    setenv xen_addr 0x42000000
    setenv ker_addr 0x46000000
    setenv ird_addr 0x48000000

    setenv du1_ker_addr 0x50000000
    setenv du1_ird_addr 0x52000000

    setenv xen_bootargs "dom0_mem=512M log_lvl=all guest_loglvl=all"


    # fatload virtio 0:1 \${dtb_addr} /virt-gicv3.dtb
    fatload virtio 0:1 \${xen_addr} /xen-4.14.0
    fatload virtio 0:1 \${ker_addr} /Image
    fatload virtio 0:1 \${ird_addr} /initrd.img

    fatload virtio 0:1 \${du1_ker_addr} /Image
    fatload virtio 0:1 \${du1_ird_addr} /initrd.img

    fdt addr \${dtb_addr}

    fdt set /chosen \#address-cells <1>
    fdt set /chosen \#size-cells <1>
    fdt set /chosen xen,xen-bootargs "\${xen_bootargs}"
    fdt mknod /chosen module@0
    fdt set /chosen/module@0 compatible "xen,linux-zimage" "xen,multiboot-module"
    fdt set /chosen/module@0 reg <\${ker_addr} 0x${kernel_size}>
    fdt set /chosen/module@0 bootargs "rw root=/dev/ram rdinit=/sbin/init   earlyprintk=serial,ttyAMA0 console=hvc0 earlycon=xenboot"
    fdt mknod /chosen module@1
    fdt set /chosen/module@1 compatible "xen,linux-initrd" "xen,multiboot-module"
    fdt set /chosen/module@1 reg <\${ird_addr} 0x${initrd_size}>
    
    fdt mknod /chosen domU1
    fdt set /chosen/domU1 compatible "xen,domain"
    fdt set /chosen/domU1 \#address-cells <1>
    fdt set /chosen/domU1 \#size-cells <1>
    fdt set /chosen/domU1 \cpus <1>
    fdt set /chosen/domU1 \memory <0 548576>
    fdt set /chosen/domU1 vpl011
    fdt mknod /chosen/domU1 module@0
    fdt set /chosen/domU1/module@0 compatible "multiboot,kernel" "multiboot,module"
    fdt set /chosen/domU1/module@0 reg <\${du1_ker_addr} 0x${kernel_size}>
    fdt set /chosen/domU1/module@0 bootargs "rw root=/dev/ram rdinit=/sbin/init console=ttyAMA0"
    fdt mknod /chosen/domU1 module@1
    fdt set /chosen/domU1/module@1 compatible "multiboot,ramdisk" "multiboot,module"
    fdt set /chosen/domU1/module@1 reg <\${du1_ird_addr} 0x${initrd_size}>

    setenv bootargs

    printenv
    booti \${xen_addr} - \${dtb_addr}
EOF

# generate boot script (u-boot boot script format)
${ARTIFACT_DIR}/mkimage -A arm -T script -C none -n "Xen QEMU boot script" -d boot.cmd ${ARTIFACT_DIR}/boot.scr
# ${ARTIFACT_DIR}/mkimage -A arm -T ramdisk -C gzip -d ${ARTIFACT_DIR}/initrd.img ${ARTIFACT_DIR}/initrd.img.gz

cat > genimage.cfg <<- EOF
    image boot.vfat {
        vfat {
            label = "VIRT_BOOT"
            files = {
                "${ARTIFACT_DIR}/xen-4.14.0",
                "${ARTIFACT_DIR}/virt-gicv3.dtb",
                "${ARTIFACT_DIR}/Image",
                "${ARTIFACT_DIR}/initrd.img",
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
        
        size = 256M
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
