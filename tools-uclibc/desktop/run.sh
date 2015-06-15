#!/bin/bash

ROOTFS="desktop-amd64-uclibc-hardened"

PWD="$(pwd)"
STAGE3="/var/tmp/catalyst/builds/uclibc/hardened/amd64/stage3-amd64-uclibc-hardened.tar.bz2"
KERNEL_SOURCE="/usr/src/linux-lilblue"
LAYMAN="/var/lib/layman"
ADDOVERLAY=""


unpack_stage3() {
	mkdir -p "${ROOTFS}"
	tar -x -C "${ROOTFS}" -f "${STAGE3}"
}

mount_dirs() {
	mkdir -p "${ROOTFS}"/usr/portage/
	mount --bind /usr/portage/ "${ROOTFS}"/usr/portage/
	mount --bind /proc/ "${ROOTFS}"/proc/
	mount --bind /dev/ "${ROOTFS}"/dev/
	mount --bind /dev/pts "${ROOTFS}"/dev/pts/
	mount -t tmpfs shm "${ROOTFS}"/dev/shm
	mount --bind /sys/ "${ROOTFS}"/sys/
}

add_overlay() {
	layman -S
	mkdir -p "${ROOTFS}"/"${LAYMAN}"
	cp -a "${LAYMAN}"/hardened-development/ "${ROOTFS}"/"${LAYMAN}"
	cp installed.xml "${ROOTFS}"/"${LAYMAN}"/installed.xml
	cp make.conf.layman "${ROOTFS}"/"${LAYMAN}"/make.conf
}

populate_etc() {
	cp -f fstab "${ROOTFS}"/etc/fstab 
	cp -f lilo.conf "${ROOTFS}"/etc/lilo.conf
	cp -f resolv.conf "${ROOTFS}"/etc/resolv.conf

	rm -f "${ROOTFS}"/etc/portage/make.conf.catalyst
	cp -f portage/make.conf.1 "${ROOTFS}"/etc/portage/make.conf
	[[ -z "${ADDOVERLAY}" ]] && sed -i '/^source/,+1d' "${ROOTFS}"/etc/portage/make.conf

	rm -rf "${ROOTFS}"/etc/portage/patches
	for d in env package.accept_keywords package.env package.mask package.unmask package.use patches profile repos.conf; do
		[[ -a portage/"${d}" ]] && cp -af portage/${d} "${ROOTFS}"/etc/portage
	done
}

rebuild_toolchain() {
	cp -f toolchain.sh "${ROOTFS}"/tmp/
	chroot "${ROOTFS}"/ /tmp/toolchain.sh
	rm -f "${ROOTFS}"/tmp/toolchain.sh
}

rebuild_world() {
	cp -f portage/make.conf.2 "${ROOTFS}"/etc/portage/make.conf
	[[ -z "${ADDOVERLAY}" ]] && sed -i '/^source/,+1d' "${ROOTFS}"/etc/portage/make.conf
	cp -f world.1 "${ROOTFS}"/var/lib/portage/world
	cp -f rebuild.sh "${ROOTFS}"/tmp/
	chroot "${ROOTFS}"/ /tmp/rebuild.sh
	rm -f "${ROOTFS}"/tmp/rebuild.sh
}


update_world() {
	cp -f portage/make.conf.3 "${ROOTFS}"/etc/portage/make.conf
	[[ -z "${ADDOVERLAY}" ]] && sed -i '/^source/,+1d' "${ROOTFS}"/etc/portage/make.conf
	cp -f world.2 "${ROOTFS}"/var/lib/portage/world

	cp -f update.sh "${ROOTFS}"/tmp/
	chroot "${ROOTFS}"/ /tmp/update.sh
	rm -f "${ROOTFS}"/tmp/update.sh
}

build_kernel() {
	mkdir -p "${ROOTFS}"/boot

	genkernel \
		--kernel-config=config \
		--makeopts=-j9 \
		--symlink \
		--no-mountboot \
		--kerneldir="${KERNEL_SOURCE}" \
		--bootdir="${PWD}"/"${ROOTFS}"/boot/ \
		--module-prefix="${PWD}"/"${ROOTFS}"/ \
		--modprobedir="${PWD}"/"${ROOTFS}"/etc/modprobe.d \
		all

	for i in $(find "${PWD}"/"${ROOTFS}"/lib/modules -iname *ko); do
		objcopy --strip-unneeded $i
	done
}

setup_initrc() {
	ln -sf net.lo "${ROOTFS}"/etc/init.d/net.eth0
	chroot "${ROOTFS}"/ rc-update add alsasound default
	chroot "${ROOTFS}"/ rc-update add cupsd default
	chroot "${ROOTFS}"/ rc-update add fcron default
	chroot "${ROOTFS}"/ rc-update add net.eth0 default
	chroot "${ROOTFS}"/ rc-update add postfix default
	chroot "${ROOTFS}"/ rc-update add sshd default
	chroot "${ROOTFS}"/ rc-update add xdm default
	chroot "${ROOTFS}"/ rc-update add avahi-daemon default
	chroot "${ROOTFS}"/ rc-update add dbus default
	chroot "${ROOTFS}"/ rc-update add samba default
	chroot "${ROOTFS}"/ rc-update add syslog-ng default
}

setup_usergroups() {
	local DCONF_LOCAL="http://dev.gentoo.org/~blueness/lilblue/user"

	cp -f passwd.sh "${ROOTFS}"/tmp/
	chroot  "${ROOTFS}"/ /tmp/passwd.sh
	rm -f "${ROOTFS}"/tmp/passwd.sh

	rm -rf "${ROOTFS}"/etc/skel
	cp -a gentoo "${ROOTFS}"/etc/skel
	mkdir -p "${ROOTFS}"/etc/skel/{Desktop,Documents,Downloads,Music,Pictures,Public,Templates,Videos,.ssh,.cache/dconf,.config/dconf}
	chmod 700 "${ROOTFS}"/etc/skel/.ssh
	wget -O "${ROOTFS}"/etc/skel/.config/dconf/user "${DCONF_LOCAL}"
	wget -O "${ROOTFS}"/etc/skel/.cache/dconf/user "${DCONF_LOCAL}"

	rm -rf "${ROOTFS}"/home/gentoo
	cp -a gentoo "${ROOTFS}"/home/gentoo
	mkdir -p "${ROOTFS}"/home/gentoo/{Desktop,Documents,Downloads,Music,Pictures,Public,Templates,Videos,.ssh,.cache/dconf,.config/dconf}
	chmod 700 "${ROOTFS}"/home/gentoo/.ssh
	wget -O "${ROOTFS}"/home/gentoo/.config/dconf/user "${DCONF_LOCAL}"
	wget -O "${ROOTFS}"/home/gentoo/.cache/dconf/user "${DCONF_LOCAL}"

	chroot "${ROOTFS}"/ chown -R gentoo:gentoo /home/gentoo
	sed -i 's/# \(%wheel.*NOPASSWD\)/\1/' "${ROOTFS}"/etc/sudoers
}

setup_confs() {
	local IMAGE="http://dev.gentoo.org/~blueness/lilblue/gentoo1600x1200.jpg"

	# Clean up /etc/portage.
	sed -i '/^GENTOO_MIRRORS/d' "${ROOTFS}"/etc/portage/make.conf
	sed -i 's/^MAKEOPTS/#MAKEOPTS/' "${ROOTFS}"/etc/portage/make.conf

	# Change the display greeter to slim and configure.
	sed -i 's/^\(DISPLAYMANAGER="\)xdm/\1slim/' "${ROOTFS}"/etc/conf.d/xdm
	sed -i 's/^\(login.*\)/# \1/' "${ROOTFS}"/etc/slim.conf
	sed -i '/# login_cmd.*Xsession/ a\login_cmd exec /bin/bash -login ~/.xinitrc' "${ROOTFS}"/etc/slim.conf
	sed -i 's/^\(sessiondir.*\)/# \1/' "${ROOTFS}"/etc/slim.conf
	sed -i '/# sessiondir.*/ a\sessiondir /etc/X11/Sessions' "${ROOTFS}"/etc/slim.conf

	wget -O "${ROOTFS}"/usr/share/slim/themes/default/background.jpg "${IMAGE}"
	#wget -O "${ROOTFS}"/usr/share/pixmaps/backgrounds/gnome/background-default.jpg "${IMAGE}"

	# Change the hostname to 'lilblue'.
	sed -i 's/localhost/lilblue/' "${ROOTFS}"/etc/conf.d/hostname

	# In kernels 3.9 and above, we must disallow-other-stacks because of SO_REUSEPORT.
	sed -i 's/^#\(disallow-other-stacks=\)no/\1yes/g' "${ROOTFS}"/etc/avahi/avahi-daemon.conf

	# Since we're using an ubuntu-based config, get rid of the evdev spam in dmesg.
	# https://bugs.launchpad.net/ubuntu/+source/module-init-tools/+bug/240553
	echo "blacklist evbug" >> "${ROOTFS}"/etc/modprobe.d/blacklist.conf
}

cleanup_dirs() {
	rm -rf "${ROOTFS}"/tmp/*
	rm -rf "${ROOTFS}"/var/log/*
	rm -rf "${ROOTFS}"/var/tmp/*
	rm -rf "${ROOTFS}"/etc/resolv.conf
}

unmount_dirs() {
	umount "${ROOTFS}"/sys/
	umount "${ROOTFS}"/dev/shm
	umount "${ROOTFS}"/dev/pts/
	umount "${ROOTFS}"/dev/
	umount "${ROOTFS}"/proc/
	umount "${ROOTFS}"/usr/portage/

	mkdir -p "${ROOTFS}"/usr/portage/profiles/
	echo "gentoo" >> "${ROOTFS}"/usr/portage/profiles/repo_name
}

bundle_it() {
	local DATE=$(date +%Y%m%d)
	local NAME="${ROOTFS}"-"${DATE}".tar.xz
	local DIGESTS="${NAME}".DIGESTS

	cd "${ROOTFS}"
	tar --xattrs --xattrs-include=security.capability --xattrs-include=user.pax.flags -J -c -f ../"${NAME}" .

	cd ..
	>"${DIGESTS}"

	echo "# MD5 HASH" >> "${DIGESTS}"
	md5sum "${NAME}" >> "${DIGESTS}"

	echo "# SHA1 HASH" >> "${DIGESTS}"
	sha1sum "${NAME}" >> "${DIGESTS}"

	echo "# SHA512 HASH" >> "${DIGESTS}"
	sha512sum "${NAME}" >> "${DIGESTS}"

	echo "# WHIRLPOOL HASH" >> "${DIGESTS}"
	whirlpooldeep "${NAME}" >> "${DIGESTS}"
}

main() {

	while getopts ":a" opt; do
		case $opt in
			a) ADDOVERLAY="yes" ;;
		esac
	done

	unpack_stage3
	mount_dirs
	[[ ! -z "${ADDOVERLAY}" ]] && add_overlay
	populate_etc
	rebuild_toolchain
	rebuild_world
	update_world
	build_kernel
	setup_initrc
	setup_usergroups
	setup_confs
	cleanup_dirs
	unmount_dirs
	bundle_it
}

main > zzz.log 2>&1 &
