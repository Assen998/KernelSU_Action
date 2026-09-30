#!/usr/bin/env bash
# Package build output: AnyKernel3 flashable zip and, optionally, a boot image.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
BOOT_OUT="${KERNEL_DIR}/out/arch/${ARCH}/boot"
AK3="${WORKSPACE}/AnyKernel3"

make_anykernel3() {
	group "Building AnyKernel3 package"
	rm -rf "$AK3"

	if is_true "${USE_CUSTOM_ANYKERNEL3:-false}"; then
		local src=${CUSTOM_ANYKERNEL3_SOURCE:?CUSTOM_ANYKERNEL3_SOURCE required}
		case "$src" in
			*.tar.gz | *.tgz)
				fetch "$src" "${WORKSPACE}/ak3.tar.gz"
				extract_archive "${WORKSPACE}/ak3.tar.gz" "$AK3" ;;
			*.zip)
				fetch "$src" "${WORKSPACE}/ak3.zip"
				extract_archive "${WORKSPACE}/ak3.zip" "$AK3" ;;
			*git*)
				retry 3 git clone -q --depth=1 ${CUSTOM_ANYKERNEL3_BRANCH:+-b "$CUSTOM_ANYKERNEL3_BRANCH"} \
					"$src" "$AK3" || die "failed to clone ${src}" ;;
			*)
				fetch "$src" "${WORKSPACE}/ak3.zip"
				extract_archive "${WORKSPACE}/ak3.zip" "$AK3" ;;
		esac
	else
		retry 3 git clone -q --depth=1 https://github.com/osm0sis/AnyKernel3 "$AK3" \
			|| die "failed to clone AnyKernel3"
		# Device checks are meaningless here: we do not know the target's
		# ro.product.device, and the zip is flashed deliberately by its builder.
		sed -i 's/do.devicecheck=1/do.devicecheck=0/g' "${AK3}/anykernel.sh"
		sed -i 's!BLOCK=/dev/block/platform/omap/omap_hsmmc.0/by-name/boot;!BLOCK=auto;!g' "${AK3}/anykernel.sh"
		sed -i 's/IS_SLOT_DEVICE=0;/is_slot_device=auto;/g' "${AK3}/anykernel.sh"
	fi

	# Full boot image (MTK / full-boot workflows): the AK3 package flashes
	# boot.img straight to the boot partition, so the raw kernel is not needed.
	if is_true "${BUILD_BOOT_IMG:-false}" && [ -f "${WORKSPACE}/boot.img" ]; then
		cp "${WORKSPACE}/boot.img" "${AK3}/" \
			|| die "boot.img missing for AnyKernel3 package"
	else
		cp "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${AK3}/" \
			|| die "kernel image missing at ${BOOT_OUT}/${KERNEL_IMAGE_NAME}"
	fi
	if is_true "${CHECK_DTBO_IS_OK:-false}"; then
		cp "${BOOT_OUT}/dtbo.img" "${AK3}/"
	fi
	rm -rf "${AK3}/.git" "${AK3}/.github" "${AK3}/README.md"

	ok "AnyKernel3 package assembled"
	endgroup
}

make_boot_image() {
	is_true "${BUILD_BOOT_IMG:-false}" || return 0
	group "Repacking boot image"

	local src_img="${WORKSPACE}/boot-source.img"
	if [ -f "${SOURCE_BOOT_IMAGE}" ]; then
		# A path inside the repo (e.g. boot/cannon-boot.img) -- no fetch needed.
		cp "${SOURCE_BOOT_IMAGE}" "$src_img"
	else
		fetch "${SOURCE_BOOT_IMAGE:?SOURCE_BOOT_IMAGE required}" "$src_img"
	fi

	# BOOT_REPACK=mtk: MediaTek boot images use an 8-byte "ANDROID!" magic
	# (fields shifted -8 vs AOSP) which the stock unpack_bootimg.py misparses.
	# The in-repo repacker validates the layout and swaps in the new kernel.
	if [ "${BOOT_REPACK:-standard}" = "mtk" ]; then
		# MTK LK inflates the kernel into a buffer sized for the STOCK
		# kernel; a larger kernel crashes LK (bootreason=lk_crash). Gate the
		# inflated size and pad up to the stock size when needed.
		if [ -n "${STOCK_KERNEL_INFLATED_SIZE:-}" ]; then
			python3 "$(dirname "${BASH_SOURCE[0]}")/mtk_kernel_gate.py" \
				--kernel "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" \
				--target "${STOCK_KERNEL_INFLATED_SIZE}" \
				|| die "kernel too large for MTK LK (see mtk_kernel_gate output)"
		fi
		python3 "$(dirname "${BASH_SOURCE[0]}")/mtk_boot_repack.py" \
			--source "$src_img" \
			--kernel "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" \
			--output "${WORKSPACE}/boot.img" \
			|| die "MTK boot image repack failed"
		[ -s "${WORKSPACE}/boot.img" ] || die "boot.img was not produced"
		ok "boot.img built ($(du -h "${WORKSPACE}/boot.img" | cut -f1))"
		export_env MAKE_BOOT_IMAGE_IS_OK true
		endgroup
		return 0
	fi

	local tools="${WORKSPACE}/tools"
	[ -x "${tools}/unpack_bootimg.py" ] || [ -f "${tools}/unpack_bootimg.py" ] \
		|| die "mkbootimg tools not found at ${tools}"

	cd "$WORKSPACE"
	local fmt
	fmt=$(python3 "${tools}/unpack_bootimg.py" --boot_img boot-source.img --format mkbootimg) \
		|| die "failed to read the source boot image"
	info "source boot image args: ${fmt}"

	python3 "${tools}/unpack_bootimg.py" --boot_img boot-source.img >/dev/null \
		|| die "failed to unpack the source boot image"

	cp "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${WORKSPACE}/out/kernel" \
		|| die "could not stage the new kernel into the unpacked ramdisk"

	# shellcheck disable=SC2086
	python3 "${tools}/mkbootimg.py" $fmt -o boot.img || die "mkbootimg failed"
	[ -s "${WORKSPACE}/boot.img" ] || die "boot.img was not produced"

	ok "boot.img built ($(du -h "${WORKSPACE}/boot.img" | cut -f1))"
	export_env MAKE_BOOT_IMAGE_IS_OK true
	endgroup
}

write_summary() {
	summary ""
	summary "### Build artifacts"
	summary ""
	summary "| Artifact | Size |"
	summary "| --- | --- |"
	local f
	for f in "${BOOT_OUT}/${KERNEL_IMAGE_NAME}" "${BOOT_OUT}/dtbo.img" "${WORKSPACE}/boot.img"; do
		[ -f "$f" ] && summary "| \`$(basename "$f")\` | $(du -h "$f" | cut -f1) |"
	done
	[ -d "$AK3" ] && summary "| \`AnyKernel3\` (flashable zip) | $(du -sh "$AK3" | cut -f1) |"
	summary ""
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		anykernel3) make_anykernel3 ;;
		bootimg)    make_boot_image ;;
		all)        make_boot_image; make_anykernel3; write_summary ;;
		*) die "unknown package step '$1'" ;;
	esac
fi
