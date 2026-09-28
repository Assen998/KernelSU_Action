#!/usr/bin/env bash
# Fetch the compiler toolchain and export the make flags that use it.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKSPACE=${WORKSPACE:?WORKSPACE must be set}

CLANG_DIR="${WORKSPACE}/clang"
GCC64_DIR="${WORKSPACE}/gcc-64"
GCC32_DIR="${WORKSPACE}/gcc-32"

AOSP_CLANG_BASE="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"

# Fallback sources. android.googlesource.com's gitiles '+archive' endpoint
# generates multi-GB tarballs on the fly and has had multi-hour outages in
# which every request returns 503 (observed 2026-09-28, from both GitHub
# runners and other networks). The fallbacks below use hosts that do not
# generate anything on the fly:
#   * the NDK zip on dl.google.com is a static CDN object (Clang 16 in r25c,
#     same generation LineageOS CI uses for maintained legacy trees),
#   * the runner image ships GNU cross binutils (apt packages), the exact
#     tool generation 4.4/4.9 trees were historically built with.
NDK_FALLBACK_VERSION=${CLANG_NDK_VERSION:-r25c}
NDK_FALLBACK_URL="https://dl.google.com/android/repository/android-ndk-${NDK_FALLBACK_VERSION}-linux.zip"

# Known-good AOSP clang branch/version pairs, verified 2026-07-27.
#
# This table exists because the AOSP prebuilt repo is a minefield: every
# kernel-build branch lists *every* clang version directory in its tree, but
# only the one or two it was actually cut for contain a real toolchain. The
# rest are either absent or contain nothing but a `.keep` placeholder, and the
# generated tarball for those downloads happily with HTTP 200 -- it is just a
# valid, ~165-byte, empty archive. So a typo'd version does not 404; it
# produces an empty clang/ directory and a baffling "clang: not found" later.
#
#   branch                    version     approx clang
#   main-kernel               r596125     newest
#   main-kernel-2026          r584948c
#   main-kernel-2025          r547379     <- default
#   main-kernel-2025          r536225
#   main-kernel-build-2024    r510928
#   master-kernel-build-2022  r450784e    last of the master-* era
#
# Note the branch naming changed twice: master-kernel-build-YYYY became
# main-kernel-build-YYYY in 2023, then main-kernel-YYYY from 2025 on.
clang_known_good() {
	case "$1/$2" in
		main-kernel/r596125 | \
		main-kernel/r547379 | \
		main-kernel-2026/r584948c | \
		main-kernel-2025/r547379 | \
		main-kernel-2025/r536225 | \
		main-kernel-build-2024/r510928 | \
		main-kernel-build-2023/r498229b | \
		master-kernel-build-2022/r450784e | \
		master-kernel-build-2021/r416183b) return 0 ;;
		*) return 1 ;;
	esac
}

# gitiles_alive REPO_URL -- 0 if the gitiles web frontend answers 2xx, 1 if
# it is refusing (the multi-hour 503 outage mode, in which *every* request to
# the service 503s within a second). A cheap 15s probe, used to skip straight
# to the fallbacks instead of burning minutes of retries on a dead endpoint.
gitiles_alive() {
	local code
	code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$1" 2>/dev/null) || return 1
	case "$code" in
		2*) return 0 ;;
		*) return 1 ;;
	esac
}

# find_clang_bin DIR -- print the path to a usable clang inside an extracted
# toolchain tree. Handles the AOSP layout (bin/clang at the tree root) and the
# NDK layout (<root>/toolchains/llvm/prebuilt/linux-x86_64/bin/clang).
find_clang_bin() {
	local root=$1 cand
	if [ -x "${root}/bin/clang" ]; then
		printf '%s' "${root}/bin/clang"
		return 0
	fi
	cand=$(find "$root" -maxdepth 7 -type f -path '*/bin/clang' 2>/dev/null | awk 'NR==1')
	if [ -n "$cand" ] && [ -x "$cand" ]; then
		printf '%s' "$cand"
		return 0
	fi
	return 1
}

# setup_clang_ndk_fallback DEST -- download the NDK zip (static CDN object)
# and leave its extracted tree in DEST. Returns 1 when it cannot provide a
# clang; the caller decides what to do. The fetch runs in a subshell because
# fetch() hard-exits on failure (die) and that must not take this script down.
setup_clang_ndk_fallback() {
	local dest=$1
	group "Fallback: NDK ${NDK_FALLBACK_VERSION} from dl.google.com"
	local zip="${WORKSPACE}/ndk-${NDK_FALLBACK_VERSION}.zip"
	rm -rf "$dest"; mkdir -p "$dest"
	( fetch "$NDK_FALLBACK_URL" "$zip" ) \
		|| { warn "NDK download failed: ${NDK_FALLBACK_URL}"; return 1; }
	extract_archive "$zip" "$dest"
	find_clang_bin "$dest" >/dev/null
}

setup_clang() {
	rm -rf "$CLANG_DIR"; mkdir -p "$CLANG_DIR"

	local clang_bin=""
	if is_true "${USE_CUSTOM_CLANG:-false}"; then
		group "Downloading custom Clang"
		local src=${CUSTOM_CLANG_SOURCE:?CUSTOM_CLANG_SOURCE required}
		case "$src" in
			*.tar.gz | *.tgz | *.tar.xz | *.tar.zst | *.tar.bz2)
				fetch "$src" "${WORKSPACE}/clang-archive"
				# Name the temp file by extension so extract_archive can route it.
				local ext="${src##*/}"; ext="${ext#*.}"
				mv "${WORKSPACE}/clang-archive" "${WORKSPACE}/clang.${ext}"
				extract_archive "${WORKSPACE}/clang.${ext}" "$CLANG_DIR" ;;
			*.zip)
				fetch "$src" "${WORKSPACE}/clang.zip"
				extract_archive "${WORKSPACE}/clang.zip" "$CLANG_DIR" ;;
			*git*)
				retry 3 git clone -q --depth=1 ${CUSTOM_CLANG_BRANCH:+-b "$CUSTOM_CLANG_BRANCH"} \
					"$src" "$CLANG_DIR" || die "failed to clone ${src}" ;;
			*)
				fetch "$src" "${WORKSPACE}/clang.zip"
				extract_archive "${WORKSPACE}/clang.zip" "$CLANG_DIR" ;;
		esac
		clang_bin=$(find_clang_bin "$CLANG_DIR") \
			|| die "no usable clang found under ${CLANG_DIR} after custom download.
        The archive extracted to: $(ls -A "$CLANG_DIR" 2>/dev/null | awk 'NR<=5' | tr '\n' ' ')"
	else
		group "Downloading AOSP Clang"
		local branch=${CLANG_BRANCH:-main-kernel-2025}
		local version=${CLANG_VERSION:-r547379}

		if ! clang_known_good "$branch" "$version"; then
			warn "clang ${version} on branch ${branch} is not in the verified-good table."
			warn "AOSP lists many version directories per branch but only populates a few;"
			warn "an unpopulated one downloads as a valid but EMPTY archive."
			warn "Verified pairs: main-kernel/r596125, main-kernel-2026/r584948c,"
			warn "main-kernel-2025/r547379, main-kernel-build-2024/r510928,"
			warn "master-kernel-build-2022/r450784e"
		fi

		local aosp_url="${AOSP_CLANG_BASE}/+archive/refs/heads/${branch}/clang-${version}.tar.gz"
		# fetch() hard-exits (die) on failure, so every AOSP attempt runs in a
		# subshell: its exit stays inside the subshell and the fallback chain
		# below still gets its turn.
		local dl_ok=false
		if gitiles_alive "$AOSP_CLANG_BASE"; then
			( fetch "$aosp_url" "${WORKSPACE}/clang.tar.gz" \
				&& extract_archive "${WORKSPACE}/clang.tar.gz" "$CLANG_DIR" ) \
				&& dl_ok=true
		else
			warn "gitiles is refusing requests (503 outage mode); skipping AOSP clang download."
		fi
		if [ "$dl_ok" = true ]; then
			# Empty-archive trap: an unpopulated version directory downloads as
			# a valid ~165-byte tarball. A real toolchain is ~2GB.
			local size
			size=$(stat -c%s "${WORKSPACE}/clang.tar.gz" 2>/dev/null || echo 0)
			[ "$size" -gt 1048576 ] \
				|| die "downloaded clang archive is only ${size} bytes: ${branch}/${version} is an empty placeholder.
        Pick a verified pair (see scripts/toolchain.sh)."
			clang_bin=$(find_clang_bin "$CLANG_DIR") || clang_bin=""
		fi

		if [ -z "$clang_bin" ] && gitiles_alive "$AOSP_CLANG_BASE"; then
			warn "retrying AOSP clang once in case the outage flapped..."
			rm -rf "$CLANG_DIR"; mkdir -p "$CLANG_DIR"
			( fetch "$aosp_url" "${WORKSPACE}/clang.tar.gz" \
				&& extract_archive "${WORKSPACE}/clang.tar.gz" "$CLANG_DIR" ) \
				&& dl_ok=true
			if [ "$dl_ok" = true ]; then
				size=$(stat -c%s "${WORKSPACE}/clang.tar.gz" 2>/dev/null || echo 0)
				[ "$size" -gt 1048576 ] \
					|| die "downloaded clang archive is only ${size} bytes: ${branch}/${version} is an empty placeholder.
        Pick a verified pair (see scripts/toolchain.sh)."
				clang_bin=$(find_clang_bin "$CLANG_DIR") || clang_bin=""
			fi
		fi

		if [ -z "$clang_bin" ]; then
			if setup_clang_ndk_fallback "$CLANG_DIR" \
				&& clang_bin=$(find_clang_bin "$CLANG_DIR"); then
				warn "using NDK ${NDK_FALLBACK_VERSION} toolchain (Clang 16) instead of AOSP clang ${version}."
			fi
		fi

		[ -n "$clang_bin" ] \
			|| die "no usable clang. AOSP gitiles (${aosp_url}) and the NDK fallback (${NDK_FALLBACK_URL}) both failed.
        If this is the known gitiles 503 outage, wait for it to clear, or pin a
        working version with CLANG_NDK_VERSION."
	fi

	local ver
	ver=$("$clang_bin" --version | head -n1)
	ok "clang ready: ${ver}"
	export_env CLANG_PATH "$(dirname "$clang_bin")"
	summary "| Compiler | \`${ver}\` |"
	endgroup
}

# AOSP's GCC 4.9 prebuilts are still the binutils of choice for pre-5.x trees
# that cannot yet use LLVM's integrated assembler. When gitiles is down, the
# GNU cross binutils from the runner image (apt) stand in: same tool
# generation, and a kernel build only ever touches as/ld from the toolchain.
setup_gcc() {
	local gcc_tag=${AOSP_GCC_TAG:-android-12.1.0_r27}

	if is_true "${USE_CUSTOM_GCC_64:-false}"; then
		group "Downloading custom GCC (arm64)"
		fetch_toolchain_generic "${CUSTOM_GCC_64_SOURCE}" "${CUSTOM_GCC_64_BRANCH:-}" "$GCC64_DIR"
		export_env GCC_64 "CROSS_COMPILE=${GCC64_DIR}/bin/${CUSTOM_GCC_64_BIN:-aarch64-linux-android-}"
		endgroup
	elif is_true "${ENABLE_GCC_ARM64:-false}"; then
		group "Downloading AOSP GCC (arm64)"
		local repo64="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"
		local url64="${repo64}/+archive/refs/tags/${gcc_tag}.tar.gz"
		local ok64=false
		mkdir -p "$GCC64_DIR"
		if gitiles_alive "$repo64"; then
			( fetch "$url64" "${WORKSPACE}/gcc-aarch64.tar.gz" \
				&& extract_archive "${WORKSPACE}/gcc-aarch64.tar.gz" "$GCC64_DIR" ) \
				&& ok64=true
		else
			warn "gitiles is refusing requests (503 outage mode); skipping AOSP GCC (arm64) download."
		fi
		if [ "$ok64" = true ] && [ -x "${GCC64_DIR}/bin/aarch64-linux-android-ld" ]; then
			export_env GCC_64 "CROSS_COMPILE=${GCC64_DIR}/bin/aarch64-linux-android-"
		else
			warn "AOSP GCC (arm64) unavailable. Using system aarch64-linux-gnu binutils."
			if ! command -v aarch64-linux-gnu-ld >/dev/null 2>&1; then
				sudo apt-get update -qq || true
				sudo apt-get install -y --no-install-recommends binutils-aarch64-linux-gnu \
					|| die "cannot install binutils-aarch64-linux-gnu"
			fi
			export_env GCC_64 "CROSS_COMPILE=aarch64-linux-gnu-"
		fi
		endgroup
	fi

	if is_true "${USE_CUSTOM_GCC_32:-false}"; then
		group "Downloading custom GCC (arm32)"
		fetch_toolchain_generic "${CUSTOM_GCC_32_SOURCE}" "${CUSTOM_GCC_32_BRANCH:-}" "$GCC32_DIR"
		export_env GCC_32 "CROSS_COMPILE_ARM32=${GCC32_DIR}/bin/${CUSTOM_GCC_32_BIN:-arm-linux-androideabi-}"
		endgroup
	elif is_true "${ENABLE_GCC_ARM32:-false}"; then
		group "Downloading AOSP GCC (arm32)"
		local repo32="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9"
		local url32="${repo32}/+archive/refs/tags/${gcc_tag}.tar.gz"
		local ok32=false
		mkdir -p "$GCC32_DIR"
		if gitiles_alive "$repo32"; then
			( fetch "$url32" "${WORKSPACE}/gcc-arm.tar.gz" \
				&& extract_archive "${WORKSPACE}/gcc-arm.tar.gz" "$GCC32_DIR" ) \
				&& ok32=true
		else
			warn "gitiles is refusing requests (503 outage mode); skipping AOSP GCC (arm32) download."
		fi
		if [ "$ok32" = true ] && [ -x "${GCC32_DIR}/bin/arm-linux-androideabi-ld" ]; then
			export_env GCC_32 "CROSS_COMPILE_ARM32=${GCC32_DIR}/bin/arm-linux-androideabi-"
		else
			warn "AOSP GCC (arm32) unavailable. Using system arm-linux-gnueabi binutils."
			if ! command -v arm-linux-gnueabi-ld >/dev/null 2>&1; then
				sudo apt-get install -y --no-install-recommends binutils-arm-linux-gnueabi \
					|| die "cannot install binutils-arm-linux-gnueabi"
			fi
			export_env GCC_32 "CROSS_COMPILE_ARM32=arm-linux-gnueabi-"
		fi
		endgroup
	fi
}

fetch_toolchain_generic() {
	local src=$1 branch=$2 dest=$3
	rm -rf "$dest"; mkdir -p "$dest"
	case "$src" in
		*.tar.gz | *.tgz | *.tar.xz | *.tar.zst)
			local ext="${src##*/}"; ext="${ext#*.}"
			fetch "$src" "${WORKSPACE}/tc.${ext}"
			extract_archive "${WORKSPACE}/tc.${ext}" "$dest" ;;
		*.zip)
			fetch "$src" "${WORKSPACE}/tc.zip"
			extract_archive "${WORKSPACE}/tc.zip" "$dest" ;;
		*git*)
			retry 3 git clone -q --depth=1 ${branch:+-b "$branch"} "$src" "$dest" \
				|| die "failed to clone ${src}" ;;
		*)
			fetch "$src" "${WORKSPACE}/tc.zip"
			extract_archive "${WORKSPACE}/tc.zip" "$dest" ;;
	esac
}

# mkbootimg is only needed when repacking a boot image.
setup_mkbootimg() {
	is_true "${BUILD_BOOT_IMG:-false}" || return 0
	group "Downloading mkbootimg tools"
	local dir="${WORKSPACE}/tools"
	rm -rf "$dir"
	retry 3 git clone -q --depth=1 -b main-kernel \
		https://android.googlesource.com/platform/system/tools/mkbootimg "$dir" \
		|| die "failed to clone mkbootimg"
	ok "mkbootimg ready"
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	setup_clang
	setup_gcc
	setup_mkbootimg
fi
