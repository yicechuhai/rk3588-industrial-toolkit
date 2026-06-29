#!/bin/bash
#===============================================================================
# build_offline.sh - 离线部署包构建脚本
# 功能：打包所有依赖为 tar.gz，支持离线环境一键部署
#===============================================================================

set -e

VERSION="v1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../" && pwd)"
OUTPUT_DIR="${PROJECT_ROOT}/release"
PACK_NAME="rk3588-toolkit-offline-${VERSION}"
PACK_DIR="${OUTPUT_DIR}/${PACK_NAME}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

DEB_LIST=("librga2" "librga-dev" "libdrm-dev" "librockchip-mpp-dev" "rockchip-mpp" "libopen62541-dev" "libmodbus-dev" "libyaml-cpp-dev" "rt-tests" "stress-ng")
PIP_LIST=("rknn-toolkit-lite2>=2.0.0" "numpy" "opencv-python-headless" "pyyaml")

print_banner() {
    echo "============================================"
    echo "  RK3588 Toolkit 离线部署包构建工具 ${VERSION}"
    echo "============================================"
    echo ""
}

download_debs() {
    echo -e "${CYAN}[PACK] 下载 .deb 依赖包...${NC}"
    mkdir -p "${PACK_DIR}/debs"
    cd "${PACK_DIR}/debs"
    for pkg in "${DEB_LIST[@]}"; do
        echo -n "  -> ${pkg} ... "
        apt-get download "$pkg" 2>/dev/null && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}SKIP${NC}"
    done
}

download_pip() {
    echo -e "${CYAN}[PACK] 下载 Python 依赖...${NC}"
    mkdir -p "${PACK_DIR}/wheels"
    for pkg in "${PIP_LIST[@]}"; do
        echo -n "  -> ${pkg} ... "
        pip3 download -d "${PACK_DIR}/wheels" "$pkg" 2>/dev/null && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}SKIP${NC}"
    done
}

copy_project_files() {
    echo -e "${CYAN}[PACK] 复制项目文件...${NC}"
    mkdir -p "${PACK_DIR}/toolkit"
    for dir in deploy_scripts deploy tools patches configs; do
        [ -d "${PROJECT_ROOT}/${dir}" ] && cp -r "${PROJECT_ROOT}/${dir}" "${PACK_DIR}/toolkit/" && echo "  -> ${dir}/"
    done
    [ -f "${PROJECT_ROOT}/install.sh" ] && cp "${PROJECT_ROOT}/install.sh" "${PACK_DIR}/toolkit/" && echo "  -> install.sh"
    [ -f "${PROJECT_ROOT}/README.md" ] && cp "${PROJECT_ROOT}/README.md" "${PACK_DIR}/toolkit/" && echo "  -> README.md"
}

generate_offline_installer() {
    echo -e "${CYAN}[PACK] 生成离线安装脚本...${NC}"
    cat > "${PACK_DIR}/install_offline.sh" << 'INSTALLER'
#!/bin/bash
set -e
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G='\033[0;32m'; C='\033[0;36m'; N='\033[0m'
echo "============================================"
echo "  RK3588 Toolkit Offline Installer"
echo "============================================"
echo -e "${C}[1/3] Installing .deb packages...${N}"
ls "${SD}/debs/"*.deb &>/dev/null && dpkg -i "${SD}/debs/"*.deb 2>/dev/null || true
echo -e "${C}[2/3] Installing Python packages...${N}"
ls "${SD}/wheels/"*.whl &>/dev/null && pip3 install --no-index --find-links="${SD}/wheels" rknn-toolkit-lite2 numpy opencv-python-headless pyyaml 2>/dev/null || true
echo -e "${C}[3/3] Installing Toolkit...${N}"
[ -f "${SD}/toolkit/install.sh" ] && bash "${SD}/toolkit/install.sh"
echo -e "${G}Done!${N}"
INSTALLER
    chmod +x "${PACK_DIR}/install_offline.sh"
    echo -e "  [${GREEN}DONE${NC}]"
}

generate_readme() {
    cat > "${PACK_DIR}/README.md" << 'README'
# RK3588 Toolkit Offline Pack
## Usage
```bash
tar -xzf rk3588-toolkit-offline-*.tar.gz
cd rk3588-toolkit-offline-*
sudo bash install_offline.sh
```
README
}

pack_tarball() {
    echo -e "${CYAN}[PACK] 打包 tar.gz ...${NC}"
    cd "${OUTPUT_DIR}"
    tar -czf "${PACK_NAME}.tar.gz" "${PACK_NAME}"
    echo -e "  [${GREEN}DONE${NC}] ${OUTPUT_DIR}/${PACK_NAME}.tar.gz ($(du -h ${PACK_NAME}.tar.gz | cut -f1))"
}

NO_CLEANUP=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-cleanup) NO_CLEANUP=true; shift ;;
        --help) echo "Usage: $0 [--no-cleanup]"; exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

print_banner
mkdir -p "${OUTPUT_DIR}"
download_debs
download_pip
copy_project_files
generate_offline_installer
generate_readme
pack_tarball
[ "$NO_CLEANUP" = false ] && rm -rf "${PACK_DIR}"
echo -e "${GREEN}Done! / 离线部署包构建完成!${NC}"