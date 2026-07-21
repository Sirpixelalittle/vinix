#!/bin/sh

set -eu

if [ "$#" -ne 2 ]; then
	echo "usage: $0 <sysroot> <output-tar>" >&2
	exit 2
fi

for utility in awk chmod cp dirname du find grep mkdir mktemp readelf readlink realpath sed tar touch; do
	if ! command -v "${utility}" >/dev/null 2>&1; then
		echo "ERROR: required host utility '${utility}' was not found" >&2
		exit 1
	fi
done

sysroot_dir=$(cd "$1" && pwd)
case $2 in
	/*) output_tar=$2 ;;
	*) output_tar=$(pwd)/$2 ;;
esac

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vinix-recovery.XXXXXX")
recovery_root=${work_dir}/root
copied_paths=${work_dir}/copied-paths
copied_elfs=${work_dir}/copied-elfs
trap 'rm -rf "${work_dir}"' EXIT HUP INT TERM

mkdir -p "${recovery_root}"
touch "${copied_paths}" "${copied_elfs}"

normalise_guest_path() {
	local candidate_path=$1
	case ${candidate_path} in
		/*) realpath -m -s -- "${candidate_path}" ;;
		*) echo "ERROR: recovery path '${candidate_path}' is not absolute" >&2; return 1 ;;
	esac
}

copy_one() {
	local guest_path source_path destination_path
	guest_path=$(normalise_guest_path "$1")
	if grep -Fqx "${guest_path}" "${copied_paths}"; then
		return
	fi
	source_path=${sysroot_dir}${guest_path}
	if ! [ -e "${source_path}" ] && ! [ -L "${source_path}" ]; then
		echo "ERROR: recovery file '${guest_path}' does not exist in the sysroot" >&2
		return 1
	fi
	destination_path=${recovery_root}${guest_path}
	mkdir -p "$(dirname "${destination_path}")"
	cp -a -- "${source_path}" "${destination_path}"
	printf '%s\n' "${guest_path}" >>"${copied_paths}"
}

resolve_and_copy() {
	local resolved_path link_target
	resolved_path=$(normalise_guest_path "$1")
	while [ -L "${sysroot_dir}${resolved_path}" ]; do
		copy_one "${resolved_path}"
		link_target=$(readlink "${sysroot_dir}${resolved_path}")
		case ${link_target} in
			/*) resolved_path=$(normalise_guest_path "${link_target}") ;;
			*) resolved_path=$(normalise_guest_path "$(dirname "${resolved_path}")/${link_target}") ;;
		esac
	done
	copy_one "${resolved_path}"
	printf '%s\n' "${resolved_path}"
}

find_library() {
	local library_dir
	for library_dir in /usr/lib /lib /usr/local/lib; do
		if [ -e "${sysroot_dir}${library_dir}/$1" ] || [ -L "${sysroot_dir}${library_dir}/$1" ]; then
			printf '%s/%s\n' "${library_dir}" "$1"
			return
		fi
	done
	echo "ERROR: shared library '$1' was not found in the sysroot" >&2
	return 1
}

copy_elf() {
	local elf_path host_elf interpreter needed_library library_path
	elf_path=$(resolve_and_copy "$1")
	if grep -Fqx "${elf_path}" "${copied_elfs}"; then
		return
	fi
	printf '%s\n' "${elf_path}" >>"${copied_elfs}"
	host_elf=${sysroot_dir}${elf_path}

	interpreter=$(readelf -l "${host_elf}" 2>/dev/null \
		| sed -n 's/.*Requesting program interpreter: \([^]]*\)].*/\1/p')
	if [ -n "${interpreter}" ]; then
		copy_elf "${interpreter}"
	fi

	for needed_library in $(readelf -d "${host_elf}" 2>/dev/null \
		| sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p'); do
		library_path=$(find_library "${needed_library}")
		copy_elf "${library_path}"
	done
}

for directory in dev etc mnt proc root run sys tmp usr/bin usr/lib usr/share/terminfo var/mail; do
	mkdir -p "${recovery_root}/${directory}"
done
chmod 0755 "${recovery_root}/dev" "${recovery_root}/run"
chmod 1777 "${recovery_root}/tmp"

# Preserve the conventional merged-/usr paths without following the directory
# symlinks and accidentally copying the complete sysroot.
for guest_path in /bin /lib /lib64 /sbin; do
	copy_one "${guest_path}"
done

for executable in init bash mount ls cat mkdir; do
	copy_elf "/usr/bin/${executable}"
done
copy_one /usr/bin/sh

for config in bash.bash_logout bash.bashrc group hostname hosts passwd profile shells; do
	if [ -e "${sysroot_dir}/etc/${config}" ] || [ -L "${sysroot_dir}/etc/${config}" ]; then
		copy_one "/etc/${config}"
	fi
done

terminfo_file=$(find -L "${sysroot_dir}/usr/share/terminfo" -type f -name linux -print -quit 2>/dev/null || true)
if [ -n "${terminfo_file}" ]; then
	copy_one "${terminfo_file#${sysroot_dir}}"
fi

(cd "${recovery_root}" && tar cf "${output_tar}" *)
echo "Created recovery initramfs ${output_tar} ($(du -h "${output_tar}" | awk '{ print $1 }'))"
