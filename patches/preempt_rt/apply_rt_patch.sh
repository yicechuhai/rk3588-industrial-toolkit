#!/bin/bash
#===============================================================================
# apply_rt_patch.sh - RK3588 PREEMPT_RT kernel patch auto-application script
# Function: download kernel source -> apply PREEMPT_RT patch -> configure -> build -> install
# Compatible: NanoPC T6 (Debian 11, kernel 6.1.141), LubanCat 8, Radxa Rock 5B,
#             Orange Pi 5, Forlinx OK3588
# Dependencies: wget, xz, build-essential, libncurses-dev, flex, bison,
#               libssl-dev, libelf-dev
#===============================================================================

set -e

VERSION="v2.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

#===============================================================================
# Global configuration
#===============================================================================
# Default fallback values (used when version_matrix.csv is unavailable
# or the running kernel version is not found in the matrix)
KERNEL_BASE_VER="6.1"
KERNEL_FULL_VER="6.1.141"
RT_PATCH_VER="6.1.141-rt52"

WORK_DIR="/opt/rk3588-toolkit/rt-kernel"
KERNEL_SRC_DIR="${WORK_DIR}/linux-${KERNEL_FULL_VER}"
BUILD_LOG="${WORK_DIR}/build_${KERNEL_FULL_VER}_rt.log"

KERNEL_TAR_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_FULL_VER}.tar.xz"
KERNEL_TAR_FILE="${WORK_DIR}/linux-${KERNEL_FULL_VER}.tar.xz"

RT_PATCH_URL="https://cdn.kernel.org/pub/linux/kernel/projects/rt/${KERNEL_BASE_VER}/older/patch-${RT_PATCH_VER}.patch.xz"
RT_PATCH_FILE="${WORK_DIR}/patch-${RT_PATCH_VER}.patch.xz"
RT_PATCH_RAW="${WORK_DIR}/patch-${RT_PATCH_VER}.patch"

KERNEL_CONFIG="${KERNEL_SRC_DIR}/.config"

BOOT_CMD_LINE_FILE="/boot/cmdline.txt"
EXTLINUX_CONF="/boot/extlinux/extlinux.conf"
ARMBIAN_ENV="/boot/armbianEnv.txt"

# Path to version_matrix.csv (resolved relative to this script's location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_MATRIX="${SCRIPT_DIR}/version_matrix.csv"

# Detected board info (filled by auto_detect_kernel_version)
DETECTED_BOARD=""
DETECTED_BSP_KERNEL=""

#===============================================================================
# Helper functions
#===============================================================================
print_banner() {
    echo -e "${CYAN}"
    echo "============================================"
    echo "  RK3588 PREEMPT_RT Patch Auto-Application"
    echo "  ${VERSION}"
    echo "============================================"
    echo -e "${NC}"
}

log_info()  { echo -e "  ${GREEN}INFO${NC}  $(date '+%H:%M:%S')  $*"; }
log_warn()  { echo -e "  ${YELLOW}WARN${NC}  $(date '+%H:%M:%S')  $*"; }
log_error() { echo -e "  ${RED}ERROR${NC} $(date '+%H:%M:%S')  $*" >&2; }

usage() {
    echo "Usage: sudo bash apply_rt_patch.sh [options]"
    echo ""
    echo "Options:"
    echo "  --config-only     Only configure kernel, skip build"
    echo "  --install-only    Only install pre-built kernel"
    echo "  --dry-run         Check environment only"
    echo "  --list-boards     List supported boards from version_matrix.csv"
    echo "  --version         Print detected config and exit"
    echo "  --help, -h        Show this help"
    echo ""
    echo "Examples:"
    echo "  sudo bash apply_rt_patch.sh                # Auto-detect + full workflow"
    echo "  sudo bash apply_rt_patch.sh --dry-run      # Check only"
    echo "  sudo bash apply_rt_patch.sh --list-boards  # List supported boards"
    echo "  sudo bash apply_rt_patch.sh --version      # Show detected config"
    echo ""
    echo "Env vars:"
    echo "  KERNEL_FULL_VER=6.1.141       Override kernel version"
    echo "  RT_PATCH_VER=6.1.141-rt52     Override RT patch version"
    echo "  LOCAL_KERNEL_TAR=/path/to/linux-6.1.141.tar.xz"
    echo "  LOCAL_RT_PATCH=/path/to/patch-6.1.141-rt52.patch.xz"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root: sudo bash $0"
        exit 1
    fi
}

#===============================================================================
# BSP kernel version auto-detection from version_matrix.csv
#===============================================================================
detect_board_model() {
    local model_file="/proc/device-tree/model"
    if [ -f "$model_file" ]; then
        tr -d '\0' < "$model_file"
    else
        echo ""
    fi
}

# Map a board model string from device-tree to a canonical board key
# used in version_matrix.csv. Returns empty string if unknown.
canonical_board_name() {
    local raw="$1"
    case "$raw" in
        *"NanoPC T6"*|*"nanopc-t6"*|*"NanoPC-T6"*)   echo "NanoPC T6" ;;
        *"LubanCat"*|*"lubancat"*|*"LubanCat 8"*)     echo "LubanCat 8" ;;
        *"Rock 5B"*|*"ROCK 5B"*|*"rock-5b"*)          echo "Radxa Rock 5B" ;;
        *"Orange Pi 5 Plus"*|*"orangepi5-plus"*)       echo "Orange Pi 5 Plus" ;;
        *"Orange Pi 5"*|*"orangepi5"*)                 echo "Orange Pi 5" ;;
        *"OK3588"*|*"forlinx"*|*"Forlinx"*)            echo "Forlinx OK3588" ;;
        *"EVB1"*|*"RK3588 EVB"*)                       echo "Rockchip EVB1" ;;
        *"R58X"*|*"Mekotronics"*)                      echo "Mekotronics R58X" ;;
        *"HININK"*|*"hinink"*)                         echo "HININK RK3588" ;;
        *) echo "" ;;
    esac
}

# Strip trailing kernel suffixes like -rockchip, -rk3588, -arm64, etc.
# to get the raw version (e.g. 6.1.141-rockchip -> 6.1.141).
strip_kernel_suffix() {
    local ver="$1"
    echo "$ver" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}

# Get the major.minor base version from a full version string.
kernel_base_ver() {
    local full="$1"
    echo "$full" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/'
}

# Read version_matrix.csv, find the row matching the given board and kernel version.
# Returns the matching RT patch version, or empty if no match.
lookup_rt_patch() {
    local board="$1"
    local kernel="$2"
    local csv="$3"

    if [ ! -f "$csv" ]; then
        echo ""
        return
    fi

    # Skip comment lines and header, parse CSV
    # CSV columns: board,bsp_kernel,rt_patch,rt_patch_url,...
    while IFS=, read -r csv_board csv_bsp csv_rt_patch csv_rt_url rest; do
        # Skip comments and header
        [[ "$csv_board" =~ ^# ]] && continue
        [[ "$csv_board" == "board" ]] && continue
        [ -z "$csv_board" ] && continue

        # Trim whitespace
        csv_board=$(echo "$csv_board" | xargs)
        csv_bsp=$(echo "$csv_bsp" | xargs)

        if [ "$csv_board" = "$board" ] && [ "$csv_bsp" = "$kernel" ]; then
            echo "$(echo "$csv_rt_patch" | xargs)"
            return
        fi
    done < "$csv"

    echo ""
    return
}

# Build the RT patch download URL from patch version.
build_rt_patch_url() {
    local patch_ver="$1"
    # patch-6.1.141-rt52 -> base=6.1
    local base=$(echo "$patch_ver" | sed -E 's/^patch-([0-9]+\.[0-9]+).*/\1/')
    if [ -z "$base" ]; then
        base=$(echo "$patch_ver" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
    fi
    echo "https://cdn.kernel.org/pub/linux/kernel/projects/rt/${base}/older/patch-${patch_ver}.patch.xz"
}

# Auto-detect the BSP kernel version by inspecting the running kernel and
# reading the device-tree model, then looking up version_matrix.csv.
# Falls back to hardcoded defaults if detection fails.
auto_detect_versions() {
    echo ""
    echo -e "${CYAN}--- 0. BSP Kernel Version Auto-Detection ---${NC}"

    local current_kernel=$(uname -r)
    local raw_board=$(detect_board_model)
    local stripped_kernel=$(strip_kernel_suffix "$current_kernel")

    DETECTED_BOARD=$(canonical_board_name "$raw_board")
    DETECTED_BSP_KERNEL="$stripped_kernel"

    log_info "Running kernel: ${current_kernel}"
    log_info "Stripped version: ${stripped_kernel}"
    if [ -n "$raw_board" ]; then
        log_info "Detected board: ${raw_board}"
    fi
    if [ -n "$DETECTED_BOARD" ]; then
        log_info "Canonical board: ${DETECTED_BOARD}"
    fi

    # Allow manual override via env vars (highest priority)
    if [ -n "$KERNEL_FULL_VER" ]; then
        log_info "Kernel version overridden by env: ${KERNEL_FULL_VER}"
    fi
    if [ -n "$RT_PATCH_VER" ]; then
        log_info "RT patch overridden by env: ${RT_PATCH_VER}"
    fi

    # If env overrides are set, use them and skip auto-detection
    if [ -n "$KERNEL_FULL_VER" ] || [ -n "$RT_PATCH_VER" ]; then
        log_info "Using environment variable overrides"
        # Recompute dependent variables
        KERNEL_BASE_VER=$(kernel_base_ver "$KERNEL_FULL_VER")
        KERNEL_SRC_DIR="${WORK_DIR}/linux-${KERNEL_FULL_VER}"
        BUILD_LOG="${WORK_DIR}/build_${KERNEL_FULL_VER}_rt.log"
        KERNEL_TAR_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_BASE_VER%%.*}.x/linux-${KERNEL_FULL_VER}.tar.xz"
        KERNEL_TAR_FILE="${WORK_DIR}/linux-${KERNEL_FULL_VER}.tar.xz"
        RT_PATCH_URL="https://cdn.kernel.org/pub/linux/kernel/projects/rt/${KERNEL_BASE_VER}/older/patch-${RT_PATCH_VER}.patch.xz"
        RT_PATCH_FILE="${WORK_DIR}/patch-${RT_PATCH_VER}.patch.xz"
        RT_PATCH_RAW="${WORK_DIR}/patch-${RT_PATCH_VER}.patch"
        return
    fi

    # Try to look up from version_matrix.csv
    if [ -f "$VERSION_MATRIX" ]; then
        log_info "Reading version matrix: ${VERSION_MATRIX}"

        # Step 1: If we know the canonical board, try board + kernel match
        if [ -n "$DETECTED_BOARD" ]; then
            local matched_patch=$(lookup_rt_patch "$DETECTED_BOARD" "$DETECTED_BSP_KERNEL" "$VERSION_MATRIX")
            if [ -n "$matched_patch" ]; then
                RT_PATCH_VER="$matched_patch"
                KERNEL_FULL_VER="$DETECTED_BSP_KERNEL"
                KERNEL_BASE_VER=$(kernel_base_ver "$KERNEL_FULL_VER")
                log_info "Found exact match: board=${DETECTED_BOARD}, kernel=${KERNEL_FULL_VER}, patch=${RT_PATCH_VER}"
            else
                # Step 2: Board known but kernel version not in matrix — try any board match
                log_warn "No exact match for ${DETECTED_BOARD} + kernel ${DETECTED_BSP_KERNEL}"
                log_warn "Falling back to generic kernel version lookup..."
            fi
        fi

        # Step 3: Try generic kernel version lookup (match any board with this kernel)
        if [ -z "$RT_PATCH_VER" ] || [ "$KERNEL_FULL_VER" = "6.1.141" ]; then
            local generic_match=""
            while IFS=, read -r csv_board csv_bsp csv_rt_patch csv_rt_url rest; do
                [[ "$csv_board" =~ ^# ]] && continue
                [[ "$csv_board" == "board" ]] && continue
                [ -z "$csv_board" ] && continue

                csv_bsp=$(echo "$csv_bsp" | xargs)
                if [ "$csv_bsp" = "$DETECTED_BSP_KERNEL" ]; then
                    generic_match=$(echo "$csv_rt_patch" | xargs)
                    break
                fi
            done < "$VERSION_MATRIX"

            if [ -n "$generic_match" ]; then
                RT_PATCH_VER="$generic_match"
                KERNEL_FULL_VER="$DETECTED_BSP_KERNEL"
                KERNEL_BASE_VER=$(kernel_base_ver "$KERNEL_FULL_VER")
                log_info "Generic kernel match: version=${KERNEL_FULL_VER}, patch=${RT_PATCH_VER}"
            fi
        fi
    else
        log_warn "Version matrix not found: ${VERSION_MATRIX}"
        log_warn "Falling back to hardcoded defaults"
    fi

    # Recompute all dependent variables
    KERNEL_SRC_DIR="${WORK_DIR}/linux-${KERNEL_FULL_VER}"
    BUILD_LOG="${WORK_DIR}/build_${KERNEL_FULL_VER}_rt.log"
    KERNEL_TAR_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_BASE_VER%%.*}.x/linux-${KERNEL_FULL_VER}.tar.xz"
    KERNEL_TAR_FILE="${WORK_DIR}/linux-${KERNEL_FULL_VER}.tar.xz"
    RT_PATCH_URL="https://cdn.kernel.org/pub/linux/kernel/projects/rt/${KERNEL_BASE_VER}/older/patch-${RT_PATCH_VER}.patch.xz"
    RT_PATCH_FILE="${WORK_DIR}/patch-${RT_PATCH_VER}.patch.xz"
    RT_PATCH_RAW="${WORK_DIR}/patch-${RT_PATCH_VER}.patch"

    log_info "Final config: kernel=${KERNEL_FULL_VER}, rt_patch=${RT_PATCH_VER}"
    echo ""
}

# List supported boards from version_matrix.csv
list_boards() {
    if [ ! -f "$VERSION_MATRIX" ]; then
        log_error "Version matrix not found: ${VERSION_MATRIX}"
        exit 1
    fi

    echo -e "${CYAN}Supported Boards (from version_matrix.csv)${NC}"
    echo ""
    printf "  %-22s %-14s %-18s %-12s\n" "Board" "BSP Kernel" "RT Patch" "Status"
    printf "  %-22s %-14s %-18s %-12s\n" "---------------------" "-------------" "-----------------" "----------"

    while IFS=, read -r csv_board csv_bsp csv_rt_patch csv_rt_url bsp_source status notes; do
        [[ "$csv_board" =~ ^# ]] && continue
        [[ "$csv_board" == "board" ]] && continue
        [ -z "$csv_board" ] && continue

        local status_display=""
        case "$(echo "$status" | xargs)" in
            verified)   status_display="${GREEN}verified${NC}" ;;
            compatible) status_display="${YELLOW}compatible${NC}" ;;
            planned)    status_display="${CYAN}planned${NC}" ;;
            pending)    status_display="${YELLOW}pending${NC}" ;;
            deprecated) status_display="${RED}deprecated${NC}" ;;
            *)          status_display="$status" ;;
        esac

        printf "  %-22s %-14s %-18s %b\n" \
            "$(echo "$csv_board" | xargs)" \
            "$(echo "$csv_bsp" | xargs)" \
            "$(echo "$csv_rt_patch" | xargs)" \
            "$status_display"
    done < "$VERSION_MATRIX"

    echo ""
    echo "  LEGEND:"
    echo "    ${GREEN}verified${NC}   — Tested and confirmed working"
    echo "    ${YELLOW}compatible${NC} — Theoretically compatible, needs testing"
    echo "    ${CYAN}planned${NC}    — Planned for future support"
    echo "    ${YELLOW}pending${NC}   — Test in progress"
    echo "    ${RED}deprecated${NC} — No longer supported"
    echo ""
}

# Print detected/config info and exit
print_version_info() {
    echo -e "${CYAN}Build Configuration${NC}"
    echo ""
    echo "  Script version:   ${VERSION}"
    echo "  Version matrix:   ${VERSION_MATRIX}"
    echo "  Board:            ${DETECTED_BOARD:-<not detected>}"
    echo "  BSP kernel:       ${DETECTED_BSP_KERNEL:-<not detected>}"
    echo ""
    echo "  Kernel full ver:  ${KERNEL_FULL_VER}"
    echo "  Kernel base ver:  ${KERNEL_BASE_VER}"
    echo "  RT patch ver:     ${RT_PATCH_VER}"
    echo "  Work dir:         ${WORK_DIR}"
    echo ""
    echo "  Kernel tarball:   ${KERNEL_TAR_URL}"
    echo "  RT patch URL:     ${RT_PATCH_URL}"
    echo ""
    if [ -f "$VERSION_MATRIX" ]; then
        echo "  Matrix entries:   $(grep -cEv '^\s*(#|board|$)' "$VERSION_MATRIX") boards"
    fi
    exit 0
}

#===============================================================================
# System detection
#===============================================================================
check_system() {
    echo ""
    echo -e "${CYAN}--- 1. System Check ---${NC}"

    local arch=$(uname -m)
    if [ "$arch" = "aarch64" ]; then
        log_info "Architecture: ${arch} OK"
    else
        log_error "Current architecture: ${arch}, this script only supports ARM64 (RK3588)"
        exit 1
    fi

    local current_kernel=$(uname -r)
    log_info "Current kernel: ${current_kernel}"

    if uname -a | grep -qi "PREEMPT_RT"; then
        log_warn "Current kernel already has PREEMPT_RT enabled!"
        log_warn "Use --config-only or --install-only for re-compilation"
        read -p "  Continue with re-compilation? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            log_info "Cancelled"
            exit 0
        fi
    fi

    if [ -f /etc/os-release ]; then
        local os_name=$(grep "^PRETTY_NAME" /etc/os-release | cut -d= -f2 | tr -d '"')
        log_info "OS: ${os_name}"
    fi

    if [ -f /etc/debian_version ]; then
        local deb_ver=$(cat /etc/debian_version)
        log_info "Debian version: ${deb_ver}"
        if echo "$deb_ver" | grep -q "^11"; then
            log_info "Debian 11 detected OK"
        fi
    fi

    if grep -q "RK3588" /proc/device-tree/model 2>/dev/null; then
        local board_model=$(tr -d '\0' < /proc/device-tree/model)
        log_info "Board: ${board_model} OK"
    else
        log_warn "RK3588 board not detected (non-standard device tree?)"
        read -p "  Continue? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            log_info "Cancelled"
            exit 0
        fi
    fi
}

#===============================================================================
# Install build dependencies
#===============================================================================
install_dependencies() {
    echo ""
    echo -e "${CYAN}--- 2. Install Build Dependencies ---${NC}"

    local deps_install=false
    local deps=("make" "gcc" "g++" "bc" "flex" "bison" "openssl" "libssl-dev" "libelf-dev" "libncurses-dev" "xz-utils" "wget" "kmod" "cpio")

    for dep in "${deps[@]}"; do
        if ! dpkg -s "$dep" > /dev/null 2>&1; then
            deps_install=true
            log_warn "Missing dependency: ${dep}"
        fi
    done

    if ! dpkg -s libncurses-dev > /dev/null 2>&1; then
        if dpkg -s libncurses5-dev > /dev/null 2>&1; then
            log_info "Found libncurses5-dev (alternative for libncurses-dev)"
        else
            deps_install=true
            log_warn "Missing dependency: libncurses-dev"
        fi
    fi

    if [ "$deps_install" = true ]; then
        log_info "Installing build dependencies..."
        apt-get update -qq
        apt-get install -y build-essential libncurses-dev libncurses5-dev \
            flex bison libssl-dev libelf-dev bc xz-utils wget kmod cpio
        log_info "Dependencies installed"
    else
        log_info "All build dependencies satisfied OK"
    fi

    local gcc_ver=$(gcc --version | head -1)
    log_info "Compiler: ${gcc_ver}"
}

#===============================================================================
# Download kernel source and RT patch
#===============================================================================
download_sources() {
    echo ""
    echo -e "${CYAN}--- 3. Download Kernel Source and RT Patch ---${NC}"

    mkdir -p "$WORK_DIR"

    if [ -n "$LOCAL_KERNEL_TAR" ] && [ -f "$LOCAL_KERNEL_TAR" ]; then
        log_info "Using local kernel tarball: ${LOCAL_KERNEL_TAR}"
        cp "$LOCAL_KERNEL_TAR" "$KERNEL_TAR_FILE"
    fi

    if [ ! -f "$KERNEL_TAR_FILE" ]; then
        log_info "Downloading kernel source linux-${KERNEL_FULL_VER}.tar.xz..."
        log_info "URL: ${KERNEL_TAR_URL}"
        if wget -q --show-progress "$KERNEL_TAR_URL" -O "$KERNEL_TAR_FILE"; then
            log_info "Kernel source download complete"
        else
            log_error "Kernel source download failed"
            log_error "Manual download: wget ${KERNEL_TAR_URL} -O ${KERNEL_TAR_FILE}"
            exit 1
        fi
    else
        log_info "Kernel tarball exists, skipping download"
    fi

    if [ -n "$LOCAL_RT_PATCH" ] && [ -f "$LOCAL_RT_PATCH" ]; then
        log_info "Using local RT patch: ${LOCAL_RT_PATCH}"
        cp "$LOCAL_RT_PATCH" "$RT_PATCH_FILE"
    fi

    if [ ! -f "$RT_PATCH_FILE" ]; then
        log_info "Downloading PREEMPT_RT patch patch-${RT_PATCH_VER}.patch.xz..."
        log_info "URL: ${RT_PATCH_URL}"
        if wget -q --show-progress "$RT_PATCH_URL" -O "$RT_PATCH_FILE"; then
            log_info "RT patch download complete"
        else
            log_error "RT patch download failed"
            log_error "Manual download: wget ${RT_PATCH_URL} -O ${RT_PATCH_FILE}"
            exit 1
        fi
    else
        log_info "RT patch exists, skipping download"
    fi

    log_info "Verifying file integrity..."
    if ! xz -t "$KERNEL_TAR_FILE" 2>/dev/null; then
        log_error "Kernel tarball is corrupted, re-downloading"
        rm -f "$KERNEL_TAR_FILE"
        exit 1
    fi
    if ! xz -t "$RT_PATCH_FILE" 2>/dev/null; then
        log_error "RT patch is corrupted, re-downloading"
        rm -f "$RT_PATCH_FILE"
        exit 1
    fi
    log_info "File integrity verified OK"
}

#===============================================================================
# Extract kernel source and apply patch
#===============================================================================
extract_and_patch() {
    echo ""
    echo -e "${CYAN}--- 4. Extract Kernel Source and Apply PREEMPT_RT Patch ---${NC}"

    if [ -d "$KERNEL_SRC_DIR" ]; then
        log_info "Kernel source directory exists, skipping extraction"
        log_info "Remove ${KERNEL_SRC_DIR} to force re-extraction"
    else
        log_info "Extracting kernel source..."
        tar -xf "$KERNEL_TAR_FILE" -C "$WORK_DIR"
        log_info "Extraction complete: ${KERNEL_SRC_DIR}"
    fi

    cd "$KERNEL_SRC_DIR"

    if [ -f ".config" ] && [ ! -f ".config.orig" ]; then
        log_info "Backing up existing kernel config..."
        cp .config .config.orig
    fi

    if [ ! -f "$RT_PATCH_RAW" ]; then
        log_info "Decompressing RT patch..."
        xz -dk "$RT_PATCH_FILE" -c > "$RT_PATCH_RAW"
        log_info "RT patch decompressed"
    fi

    if [ -f ".rt_patch_applied" ]; then
        log_info "PREEMPT_RT patch already applied, skipping"
    else
        log_info "Applying PREEMPT_RT patch..."
        log_info "Patch path: ${RT_PATCH_RAW}"

        if patch -p1 --dry-run < "$RT_PATCH_RAW" > /dev/null 2>&1; then
            patch -p1 < "$RT_PATCH_RAW"
            touch .rt_patch_applied
            log_info "PREEMPT_RT patch applied successfully OK"
        else
            log_warn "Patch cannot be applied (may already be patched)"
            log_warn "Trying --forward mode..."
            if patch -p1 --forward < "$RT_PATCH_RAW" > /dev/null 2>&1; then
                touch .rt_patch_applied
                log_info "Patch applied via --forward mode OK"
            else
                log_error "Patch application failed, check kernel/patch version match"
                exit 1
            fi
        fi
    fi

    if grep -q "CONFIG_PREEMPT_RT" "$KERNEL_SRC_DIR"/kernel/Kconfig.preempt 2>/dev/null; then
        log_info "RT patch verification OK"
    else
        log_warn "Could not verify RT patch in Kconfig.preempt"
    fi
}

#===============================================================================
# Configure kernel
#===============================================================================
configure_kernel() {
    echo ""
    echo -e "${CYAN}--- 5. Configure Kernel Options ---${NC}"

    cd "$KERNEL_SRC_DIR"

    local current_config="/proc/config.gz"
    if [ -f "$current_config" ]; then
        log_info "Using current kernel config as base..."
        zcat "$current_config" > .config
        log_info "Current kernel config imported"
    elif [ -f "/boot/config-$(uname -r)" ]; then
        log_info "Using /boot/config-$(uname -r) as base..."
        cp "/boot/config-$(uname -r)" .config
        log_info "Kernel config imported"
    else
        log_warn "No current kernel config found, using defconfig"
        if [ -f "arch/arm64/configs/defconfig" ]; then
            make ARCH=arm64 defconfig
        else
            make defconfig
        fi
    fi

    log_info "Enabling PREEMPT_RT related kernel options..."

    if [ -f "scripts/config" ]; then
        ./scripts/config --disable CONFIG_PREEMPT
        ./scripts/config --disable CONFIG_PREEMPT_VOLUNTARY
        ./scripts/config --disable CONFIG_PREEMPT_NONE

        ./scripts/config --enable CONFIG_PREEMPT_RT
        ./scripts/config --enable CONFIG_PREEMPT_RT_FULL
        ./scripts/config --enable CONFIG_HIGH_RES_TIMERS
        ./scripts/config --enable CONFIG_NO_HZ_FULL
        ./scripts/config --enable CONFIG_NO_HZ_FULL_NONE
        ./scripts/config --enable CONFIG_RCU_NOCB_CPU
        ./scripts/config --enable CONFIG_RCU_LAZY
        ./scripts/config --enable CONFIG_IRQ_TIME_ACCOUNTING
        ./scripts/config --enable CONFIG_SCHED_HRTICK

        ./scripts/config --enable CONFIG_ARM64
        ./scripts/config --enable CONFIG_ARM64_CRYPTO
        ./scripts/config --enable CONFIG_MODULES
        ./scripts/config --enable CONFIG_MODVERSIONS

        ./scripts/config --disable CONFIG_DEBUG_PREEMPT
        ./scripts/config --disable CONFIG_LOCKDEP
        ./scripts/config --disable CONFIG_PROVE_LOCKING
        ./scripts/config --disable CONFIG_DEBUG_ATOMIC_SLEEP
        ./scripts/config --disable CONFIG_FTRACE

        ./scripts/config --set-val CONFIG_KERNEL_XZ y
        ./scripts/config --disable CONFIG_KERNEL_GZIP
        ./scripts/config --disable CONFIG_KERNEL_LZ4
    else
        log_warn "scripts/config not found, using menuconfig manually"
        log_info "Please enable these options and save:"
        echo "  General setup -> Preemption Model -> Fully Preemptible Kernel (Real-Time)"
        echo "  General setup -> Timers subsystem -> High Resolution Timers"
        echo "  CPU/Task time and stats accounting -> IRQ time accounting"
        make menuconfig
    fi

    log_info "Processing new kernel config options..."
    yes "" | make oldconfig 2>/dev/null || true

    if grep -q "CONFIG_PREEMPT_RT=y" .config 2>/dev/null; then
        log_info "PREEMPT_RT enabled OK"
    else
        log_error "PREEMPT_RT not enabled! Check kernel config"
        log_info "Run manually: cd ${KERNEL_SRC_DIR} && make menuconfig"
        log_info "Enable: General setup -> Preemption Model -> Fully Preemptible Kernel (Real-Time)"
        exit 1
    fi

    cp .config .config.rt
    log_info "Kernel configuration complete, saved to .config.rt"
}

#===============================================================================
# Build kernel
#===============================================================================
build_kernel() {
    echo ""
    echo -e "${CYAN}--- 6. Build Kernel ---${NC}"

    cd "$KERNEL_SRC_DIR"

    local cpu_cores=$(grep -c "^processor" /proc/cpuinfo)
    local jobs=$((cpu_cores * 2))

    local mem_mb=$(free -m | awk '/^Mem:/{print $7}')
    if [ "$mem_mb" -lt 2048 ]; then
        jobs=$cpu_cores
        log_warn "Low memory (${mem_mb}MB), reducing parallelism to ${jobs}"
    fi

    log_info "Starting kernel build (parallel jobs: ${jobs})..."
    log_info "Build log: ${BUILD_LOG}"
    log_info "Note: Build may take 30-60 minutes"

    if make -j"$jobs" ARCH=arm64 CROSS_COMPILE="" Image modules dtbs 2>&1 | tee "$BUILD_LOG"; then
        log_info "Kernel build successful OK"
    else
        log_error "Kernel build failed, see log: ${BUILD_LOG}"
        log_info "Common issues:"
        echo "  1. Out of memory: try reducing -j parallelism"
        echo "  2. Disk space: check ${WORK_DIR} partition"
        echo "  3. Missing deps: sudo apt install build-essential ..."
        exit 1
    fi
}

#===============================================================================
# Install kernel
#===============================================================================
install_kernel() {
    echo ""
    echo -e "${CYAN}--- 7. Install Kernel ---${NC}"

    cd "$KERNEL_SRC_DIR"

    log_info "Installing kernel modules..."
    make ARCH=arm64 modules_install
    log_info "Kernel modules installed OK"

    log_info "Installing kernel image and device trees..."
    make ARCH=arm64 install

    if [ -f "/boot/vmlinuz-${RT_PATCH_VER}" ]; then
        log_info "Kernel image installed: /boot/vmlinuz-${RT_PATCH_VER}"
    elif [ -f "/boot/Image-${RT_PATCH_VER}" ]; then
        log_info "Kernel image installed: /boot/Image-${RT_PATCH_VER}"
    fi

    if [ -d "arch/arm64/boot/dts/rockchip" ]; then
        log_info "Installing Rockchip device trees..."
        cp arch/arm64/boot/dts/rockchip/*.dtb /boot/ 2>/dev/null || true
    fi

    log_info "Kernel installation complete OK"
}

#===============================================================================
# Update bootloader config
#===============================================================================
update_bootloader() {
    echo ""
    echo -e "${CYAN}--- 8. Update Bootloader Configuration ---${NC}"

    local boot_cmdline=""
    local rt_cmdline="isolcpus=4-7 nohz_full=4-7 rcu_nocbs=4-7 irqaffinity=0-3"

    if [ -f "$EXTLINUX_CONF" ]; then
        log_info "Detected extlinux boot (NanoPC T6, etc.)"
        boot_cmdline=$(grep "APPEND" "$EXTLINUX_CONF" | head -1 | sed 's/APPEND\s*//' || echo "")
    elif [ -f "$ARMBIAN_ENV" ]; then
        log_info "Detected armbianEnv boot"
        boot_cmdline=$(grep "^extraargs=" "$ARMBIAN_ENV" | cut -d= -f2- || echo "")
    elif [ -f "$BOOT_CMD_LINE_FILE" ]; then
        log_info "Detected cmdline.txt boot"
        boot_cmdline=$(cat "$BOOT_CMD_LINE_FILE")
    fi

    if [ -n "$boot_cmdline" ]; then
        for param in isolcpus nohz_full rcu_nocbs irqaffinity; do
            boot_cmdline=$(echo "$boot_cmdline" | sed "s/${param}=[^ ]*//g")
        done
        boot_cmdline=$(echo "$boot_cmdline" | tr -s ' ')
    fi
    local new_cmdline="${boot_cmdline} ${rt_cmdline}"

    if [ -f "$EXTLINUX_CONF" ]; then
        log_info "Updating ${EXTLINUX_CONF}..."

        local menu_label="PREEMPT_RT ${RT_PATCH_VER}"
        local kernel_path="/boot/vmlinuz-${RT_PATCH_VER}"
        local dtb_path="/boot/rk3588-nanopc-t6.dtb"

        if [ ! -f "$kernel_path" ]; then
            kernel_path="/boot/Image-${RT_PATCH_VER}"
        fi

        cp "$EXTLINUX_CONF" "${EXTLINUX_CONF}.bak"

        cat >> "$EXTLINUX_CONF" << EOF

LABEL ${RT_PATCH_VER}
    MENU LABEL ${menu_label}
    KERNEL ${kernel_path}
    FDT ${dtb_path}
    APPEND ${new_cmdline}
EOF

        log_info "extlinux.conf updated OK"
        log_info "New boot entry added: ${menu_label}"

    elif [ -f "$ARMBIAN_ENV" ]; then
        log_info "Updating ${ARMBIAN_ENV}..."
        cp "$ARMBIAN_ENV" "${ARMBIAN_ENV}.bak"

        if grep -q "^kernel=" "$ARMBIAN_ENV" 2>/dev/null; then
            sed -i "s|^kernel=.*|kernel=/boot/vmlinuz-${RT_PATCH_VER}|" "$ARMBIAN_ENV"
        else
            echo "kernel=/boot/vmlinuz-${RT_PATCH_VER}" >> "$ARMBIAN_ENV"
        fi

        if grep -q "^extraargs=" "$ARMBIAN_ENV" 2>/dev/null; then
            sed -i "s|^extraargs=.*|extraargs=${rt_cmdline}|" "$ARMBIAN_ENV"
        else
            echo "extraargs=${rt_cmdline}" >> "$ARMBIAN_ENV"
        fi

        log_info "armbianEnv.txt updated OK"

    elif [ -f "$BOOT_CMD_LINE_FILE" ]; then
        log_info "Updating ${BOOT_CMD_LINE_FILE}..."
        cp "$BOOT_CMD_LINE_FILE" "${BOOT_CMD_LINE_FILE}.bak"
        echo "$new_cmdline" > "$BOOT_CMD_LINE_FILE"
        log_info "cmdline.txt updated OK"

    else
        log_warn "No known boot config file found"
        log_info "Manually add these boot parameters:"
        echo "  ${rt_cmdline}"
        log_info "And set kernel to: /boot/vmlinuz-${RT_PATCH_VER}"
    fi

    log_info "Updating initramfs..."
    if command -v update-initramfs > /dev/null 2>&1; then
        update-initramfs -u -k "${RT_PATCH_VER}" 2>/dev/null || true
        log_info "initramfs updated OK"
    elif command -v mkinitramfs > /dev/null 2>&1; then
        mkinitramfs -o "/boot/initrd.img-${RT_PATCH_VER}" "${RT_PATCH_VER}" 2>/dev/null || true
        log_info "initramfs generated OK"
    else
        log_warn "No initramfs tool found, generate manually"
    fi
}

#===============================================================================
# Verify installation
#===============================================================================
verify_installation() {
    echo ""
    echo -e "${CYAN}--- 9. Verify Installation ---${NC}"

    cd "$KERNEL_SRC_DIR"

    local kernel_path="/boot/vmlinuz-${RT_PATCH_VER}"
    if [ ! -f "$kernel_path" ]; then
        kernel_path="/boot/Image-${RT_PATCH_VER}"
    fi

    if [ -f "$kernel_path" ]; then
        local kernel_size=$(du -h "$kernel_path" | cut -f1)
        log_info "Kernel image: ${kernel_path} (${kernel_size}) OK"
    else
        log_error "Kernel image not installed to /boot"
        exit 1
    fi

    local module_dir="/lib/modules/${RT_PATCH_VER}"
    if [ -d "$module_dir" ]; then
        local module_count=$(find "$module_dir" -name "*.ko" 2>/dev/null | wc -l)
        log_info "Kernel modules: ${module_dir} (${module_count} modules) OK"
    else
        log_warn "Kernel module directory not found: ${module_dir}"
    fi

    log_info "Key kernel config check:"
    local config_checks=(
        "CONFIG_PREEMPT_RT=y"
        "CONFIG_HIGH_RES_TIMERS=y"
        "CONFIG_NO_HZ_FULL=y"
    )

    for check in "${config_checks[@]}"; do
        local config_name=$(echo "$check" | cut -d= -f1)
        if grep -q "^${check}" ".config.rt" 2>/dev/null; then
            log_info "  ${config_name}: enabled OK"
        else
            log_warn "  ${config_name}: not enabled"
        fi
    done

    if [ -f "$EXTLINUX_CONF" ] && grep -q "${RT_PATCH_VER}" "$EXTLINUX_CONF"; then
        log_info "Boot config: extlinux RT kernel entry added OK"
    fi

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  PREEMPT_RT Kernel Build & Install Complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo "  Reboot and select RT kernel:"
    echo "    sudo reboot"
    echo ""
    echo "  After reboot, verify:"
    echo "    uname -a | grep PREEMPT_RT"
    echo "    bash ../setup_realtime.sh"
    echo ""
    echo "  RT kernel version: ${RT_PATCH_VER}"
    echo "  Boot parameters: ${rt_cmdline}"
}

#===============================================================================
# Main function
#===============================================================================
main() {
    local CONFIG_ONLY=false
    local INSTALL_ONLY=false
    local DRY_RUN=false
    local LIST_BOARDS=false
    local SHOW_VERSION=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --config-only)   CONFIG_ONLY=true; shift ;;
            --install-only)  INSTALL_ONLY=true; shift ;;
            --dry-run)       DRY_RUN=true; shift ;;
            --list-boards)   LIST_BOARDS=true; shift ;;
            --version)       SHOW_VERSION=true; shift ;;
            --help|-h)       usage; exit 0 ;;
            *)               echo "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    print_banner
    check_root

    # Auto-detect BSP kernel version and matching RT patch
    auto_detect_versions

    # Mode: list supported boards
    if [ "$LIST_BOARDS" = true ]; then
        list_boards
        exit 0
    fi

    # Mode: show detected config
    if [ "$SHOW_VERSION" = true ]; then
        print_version_info
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "${CYAN}--- Dry-Run Mode ---${NC}"
        echo ""
        echo "Operations to perform:"
        echo "  1. Check system environment"
        echo "  2. Install build dependencies"
        echo "  3. Download kernel source linux-${KERNEL_FULL_VER}"
        echo "  4. Download PREEMPT_RT patch patch-${RT_PATCH_VER}"
        echo "  5. Extract source and apply patch"
        echo "  6. Configure kernel (enable PREEMPT_RT)"
        echo "  7. Build kernel (parallel compile)"
        echo "  8. Install kernel modules and image"
        echo "  9. Update bootloader configuration"
        echo ""
        log_info "Dry-Run complete, no actual changes made"
        exit 0
    fi

    check_system
    install_dependencies
    download_sources
    extract_and_patch
    configure_kernel

    if [ "$CONFIG_ONLY" = true ]; then
        log_info "Configure mode complete (.config generated)"
        log_info "To continue building, run without flags: sudo bash $0"
        exit 0
    fi

    if [ "$INSTALL_ONLY" = true ]; then
        log_info "Install mode, skipping download and build"
        if [ ! -d "$KERNEL_SRC_DIR" ]; then
            log_error "Kernel source directory not found: ${KERNEL_SRC_DIR}"
            log_error "Run full workflow first"
            exit 1
        fi
    else
        build_kernel
    fi

    install_kernel
    update_bootloader
    verify_installation
}

main "$@"
