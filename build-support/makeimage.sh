#!/bin/sh

set -eu

readonly sector_size=512
readonly sectors_per_mib=2048
readonly bios_start=$((1 * sectors_per_mib))
readonly bios_size=$((1 * sectors_per_mib))
readonly esp_start=$((2 * sectors_per_mib))
readonly esp_size=$((64 * sectors_per_mib))
readonly root_start=$((66 * sectors_per_mib))
readonly trailing_space=$((1 * sectors_per_mib))

readonly disk_uuid=4db8f510-6ab4-4db3-a41b-f7e62fc35c00
readonly bios_uuid=7c1b4f10-8e2d-4d6a-9f35-6ab472008101
readonly esp_uuid=7c1b4f10-8e2d-4d6a-9f35-6ab472008102
readonly root_uuid=7c1b4f10-8e2d-4d6a-9f35-6ab472008103

readonly bios_type=21686148-6449-6e6f-744e-656564454649
readonly esp_type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
readonly root_type=0fc63daf-8483-4772-8e79-3d69d8477de4

for utility in awk dd du mcopy mformat mke2fs mktemp mmd sfdisk truncate; do
	if ! command -v "${utility}" >/dev/null 2>&1; then
		echo "ERROR: required host utility '${utility}' was not found" >&2
		exit 1
	fi
done

rm -rf sysroot
set -f
./jinx build-if-needed base ${PKGS_TO_INSTALL-}
./jinx install sysroot base ${PKGS_TO_INSTALL-}
set +f

if ! [ -d host-pkgs/limine ]; then
	./jinx host-build limine
fi

# These are mount points in the installed root. Their contents are supplied
# by volatile filesystems or devtmpfs at boot.
mkdir -p sysroot/dev sysroot/root sysroot/run sysroot/tmp sysroot/var/lib/xkb sysroot/var/log
chmod 0755 sysroot/dev sysroot/root sysroot/run sysroot/var/lib/xkb sysroot/var/log
chmod 1777 sysroot/tmp

readonly limine_dir=host-pkgs/limine/usr/local/share/limine
readonly limine=host-pkgs/limine/usr/local/bin/limine

for boot_file in "${limine_dir}/BOOTX64.EFI" "${limine_dir}/limine-bios.sys" \
		sysroot/usr/share/vinix/vinix build-support/limine-disk.conf; do
	if ! [ -f "${boot_file}" ]; then
		echo "ERROR: required boot file '${boot_file}' was not found" >&2
		exit 1
	fi
done

# Leave 25% growth space plus 256 MiB for package installation and filesystem
# metadata, then align the root partition to a whole MiB.
sysroot_kib=$(du -sk sysroot | awk '{ print $1 }')
root_kib=$((sysroot_kib + sysroot_kib / 4 + 262144))
root_mib=$(((root_kib + 1023) / 1024))
root_size=$((root_mib * sectors_per_mib))
disk_size=$((root_start + root_size + trailing_space))

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vinix-image.XXXXXX")
trap 'rm -rf "${work_dir}"' EXIT HUP INT TERM

esp_image=${work_dir}/esp.fat
root_image=${work_dir}/root.ext2

truncate -s $((esp_size * sector_size)) "${esp_image}"
mformat -i "${esp_image}" -F -v VINIX_BOOT ::
mmd -i "${esp_image}" ::/EFI ::/EFI/BOOT ::/boot
mcopy -i "${esp_image}" "${limine_dir}/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "${esp_image}" "${limine_dir}/limine-bios.sys" ::/boot/limine-bios.sys
mcopy -i "${esp_image}" sysroot/usr/share/vinix/vinix ::/boot/vinix
mcopy -i "${esp_image}" build-support/limine-disk.conf ::/boot/limine.conf

truncate -s "${root_mib}M" "${root_image}"
mke2fs -q -t ext2 -b 4096 -I 256 \
	-O none,filetype,sparse_super,large_file \
	-L VINIX_ROOT -U 5ea1761a-8ed4-43df-b992-fcb50c3f2b04 \
	-d sysroot "${root_image}"

truncate -s $((disk_size * sector_size)) vinix.img
sfdisk --quiet vinix.img <<EOF
label: gpt
label-id: ${disk_uuid}
unit: sectors
first-lba: ${bios_start}
sector-size: ${sector_size}

start=${bios_start}, size=${bios_size}, type=${bios_type}, uuid=${bios_uuid}, name="Limine BIOS"
start=${esp_start}, size=${esp_size}, type=${esp_type}, uuid=${esp_uuid}, name="Vinix boot"
start=${root_start}, size=${root_size}, type=${root_type}, uuid=${root_uuid}, name="Vinix root"
EOF

dd if="${esp_image}" of=vinix.img bs=${sector_size} seek=${esp_start} conv=notrunc,sparse status=none
dd if="${root_image}" of=vinix.img bs=${sector_size} seek=${root_start} conv=notrunc,sparse status=none
"${limine}" bios-install vinix.img 1

sfdisk --verify vinix.img
echo "Created vinix.img (${root_mib} MiB root filesystem)"
