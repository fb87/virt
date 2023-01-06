cmake_minimum_required(VERSION 3.10)

project(virt C CXX)

include(ExternalProject)

set (BUILD_JOBS     "-j3")  # can use $(nproc) but then it will eat all your CPU
set (OUTPUT_DIR     ${CMAKE_BINARY_DIR}/dist)

file(MAKE_DIRECTORY ${OUTPUT_DIR}/_install/etc/init.d)

file(WRITE ${OUTPUT_DIR}/_install/etc/init.d/rcS
    "#!/bin/sh\n\n"

    "mkdir -p /proc /sys /dev\n\n"

    "mount -t proc none  /proc\n"
    "mount -t sysfs none /sys\n"

    "/sbin/mdev -s"
)

# create initramfs (might use without initrd)
file(WRITE ${OUTPUT_DIR}/initramfs.rc
    "dir    /dev            755 0 0\n"
    "dir    /sys            755 0 0\n"
    "dir    /proc           755 0 0\n"
    "nod    /dev/console    644 0 0 c 5 1\n"
    "nod    /dev/loop0      644 0 0 b 7 0\n"
    "dir    /bin            755 1000 1000\n"
    "dir    /sbin           755 1000 1000\n"
    "dir    /usr            755 1000 1000\n"
    "dir    /usr/bin        755 1000 1000\n"
    "dir    /usr/sbin       755 1000 1000\n"
    "slink  /bin/sh busybox 755 0 0\n"
    "file   /bin/busybox    ${OUTPUT_DIR}/busybox 755 0 0\n"
    "file   /init           ${OUTPUT_DIR}/_install/etc/init.d/rcS 755 0 0"
)

# geniamge - host tool to generate rootfs image from spec
ExternalProject_Add(genimage
    URL                     https://github.com/pengutronix/genimage/releases/download/v16/genimage-16.tar.xz
    BUILD_IN_SOURCE         true
    CONFIGURE_COMMAND       ./configure
    BUILD_COMMAND           make
    INSTALL_COMMAND         install genimage ${OUTPUT_DIR}
)

# u-boot - QEMU aarch64
ExternalProject_Add(u-boot
    URL                     https://github.com/u-boot/u-boot/archive/refs/tags/v2022.10.tar.gz
    BUILD_IN_SOURCE         true
    CONFIGURE_COMMAND       CROSS_COMPILE=aarch64-linux-gnu- make ${BUILD_JOBS} qemu_arm64_defconfig
    BUILD_COMMAND           CROSS_COMPILE=aarch64-linux-gnu- make ${BUILD_JOBS} 
    INSTALL_COMMAND         install -m644 u-boot.bin ${OUTPUT_DIR}
            COMMAND         install tools/mkimage    ${OUTPUT_DIR}
            COMMAND         echo "U-Boot built"
)

# xen hypervisor - QEMU aarch64
ExternalProject_Add(xen
    URL                     https://downloads.xenproject.org/release/xen/4.14.0/xen-4.14.0.tar.gz
    BUILD_IN_SOURCE         true
    CONFIGURE_COMMAND       XEN_TARGET_ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CONFIG_DEBUG=y ./configure --disable-tools
    BUILD_COMMAND           XEN_TARGET_ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make ${BUILD_JOBS} dist-xen
    INSTALL_COMMAND         install -m644 dist/install/boot/xen-4.14.0 ${OUTPUT_DIR}
)

# busybox - QEMU aarch64
ExternalProject_Add(busybox
    URL                     https://busybox.net/downloads/busybox-1.32.0.tar.bz2
    BUILD_IN_SOURCE         true
    CONFIGURE_COMMAND       ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make ${BUILD_JOBS} defconfig
              COMMAND       sed -i.orig "s/^#.*CONFIG_STATIC.*/CONFIG_STATIC=y/" .config
    BUILD_COMMAND           ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make ${BUILD_JOBS} install
    INSTALL_COMMAND         cp -Rf _install busybox ${OUTPUT_DIR} && mkdir -p ${OUTPUT_DIR}/_install/etc/init.d
            COMMAND         cd ${OUTPUT_DIR}/_install && find . | cpio -o --format=newc > ${OUTPUT_DIR}/initrd.img
            COMMAND         chmod +x ${OUTPUT_DIR}/_install/etc/init.d/rcS
)

# kernel - QEMU aarch64
ExternalProject_Add(kernel
    URL                     https://mirrors.edge.kernel.org/pub/linux/kernel/v5.x/linux-5.9.15.tar.xz
    BUILD_IN_SOURCE         true
    CONFIGURE_COMMAND       ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make ${BUILD_JOBS} allnoconfig xen.config
              COMMAND       ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- ./scripts/config
                                --set-val VIRTUALIZATION y
                                --set-val BINFMT_SCRIPT y
                                --set-val NET n
                                --set-val PROC_FS y
                                --set-val BLK_DEV_INITRD y
                                --set-val SERIAL_AMBA_PL011 y
                                --set-val SERIAL_AMBA_PL011_CONSOLE y
                                --set-val FRAMEBUFFER_CONSOLE y
                                --set-val EXT2_FS y
                                --set-val EXT4_FS y
                                --set-val PRINTK y
                                --set-val TTY_PRINTK y
                                --set-val VIRTIO y
                                --set-val VIRTIO_FS y
                                --set-val VIRTIO_BLK y
                                --set-val VIRTIO_CONSOLE y
                                --set-val SCSI_VIRTIO y
                                --set-val CRYPTO_DEV_VIRTIO y
                                --set-val STACKTRACE y
              COMMAND       ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make ${BUILD_JOBS} oldconfig
    BUILD_COMMAND           ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make ${BUILD_JOBS}
    INSTALL_COMMAND         install -m644 arch/arm64/boot/Image ${OUTPUT_DIR}
)

# an virtual target to pack all output above
add_custom_target(virt_all ALL)

# make sure the script is executable to avoid complaining from noobs
add_custom_command(TARGET virt_all POST_BUILD
    COMMAND                 ${CMAKE_CURRENT_SOURCE_DIR}/src/pack-rootfs.sh ${OUTPUT_DIR}
    COMMAND                 chmod +x ${OUTPUT_DIR}/start-qemu.sh
)

# to make sure all others got built before we pack them
add_dependencies(virt_all u-boot xen busybox kernel genimage)
