#!/bin/bash

CC_SERVICE_IN_TMP=/opt/azure/containers/cc-proxy.service.in
CC_SOCKET_IN_TMP=/opt/azure/containers/cc-proxy.socket.in
CNI_CONFIG_DIR="/etc/cni/net.d"
CNI_BIN_DIR="/opt/cni/bin"
CNI_DOWNLOADS_DIR="/opt/cni/downloads"
CONTAINERD_DOWNLOADS_DIR="/opt/containerd/downloads"
K8S_DOWNLOADS_DIR="/opt/kubernetes/downloads"
APMZ_DOWNLOADS_DIR="/opt/apmz/downloads"
UBUNTU_RELEASE=$(lsb_release -r -s)

removeEtcd() {
    if [[ $OS == $COREOS_OS_NAME ]]; then
        rm -rf /opt/bin/etcd
    else
        rm -rf /usr/bin/etcd
    fi
}

removeMoby() {
    apt-get purge -y moby-engine moby-cli
}

installEtcd() {
    CURRENT_VERSION=$(etcd --version | grep "etcd Version" | cut -d ":" -f 2 | tr -d '[:space:]')
    if [[ "$CURRENT_VERSION" == "${ETCD_VERSION}" ]]; then
        echo "etcd version ${ETCD_VERSION} is already installed, skipping download"
    else
        CLI_TOOL=$1
        if [[ $OS == $COREOS_OS_NAME ]]; then
            path="/opt/bin"
        else
            path="/usr/bin"
        fi
        CONTAINER_IMAGE=${ETCD_DOWNLOAD_URL}etcd:v${ETCD_VERSION}
        pullContainerImage $CLI_TOOL ${CONTAINER_IMAGE}
        removeEtcd
        if [[ "$CLI_TOOL" == "docker" ]]; then
            mkdir -p "$path"
            docker run --rm --entrypoint cat ${CONTAINER_IMAGE} /usr/local/bin/etcd > "$path/etcd"
            docker run --rm --entrypoint cat ${CONTAINER_IMAGE} /usr/local/bin/etcdctl > "$path/etcdctl"
        else
            img unpack -o "$path" ${CONTAINER_IMAGE}
        fi
        chmod a+x "$path/etcd" "$path/etcdctl"
    fi
}

installDeps() {
    retrycmd_if_failure_no_stats 120 5 25 curl -fsSL https://packages.microsoft.com/config/ubuntu/${UBUNTU_RELEASE}/packages-microsoft-prod.deb > /tmp/packages-microsoft-prod.deb || exit $ERR_MS_PROD_DEB_DOWNLOAD_TIMEOUT
    retrycmd_if_failure 60 5 10 dpkg -i /tmp/packages-microsoft-prod.deb || exit $ERR_MS_PROD_DEB_PKG_ADD_FAIL
    aptmarkWALinuxAgent hold
    apt_get_update || exit $ERR_APT_UPDATE_TIMEOUT
    apt_get_dist_upgrade || exit $ERR_APT_DIST_UPGRADE_TIMEOUT
    for apt_package in apache2-utils apt-transport-https blobfuse ca-certificates ceph-common cgroup-lite cifs-utils conntrack cracklib-runtime ebtables ethtool fuse git glusterfs-client htop iftop init-system-helpers iotop iproute2 ipset iptables jq libpam-pwquality libpwquality-tools mount nfs-common pigz socat sysstat traceroute util-linux xz-utils zip; do
      if ! apt_get_install 30 1 600 $apt_package; then
        journalctl --no-pager -u $apt_package
        exit $ERR_APT_INSTALL_TIMEOUT
      fi
    done
    if [[ "${AUDITD_ENABLED}" == true ]]; then
      if ! apt_get_install 30 1 600 auditd; then
        journalctl --no-pager -u auditd
        exit $ERR_APT_INSTALL_TIMEOUT
      fi
    fi
}

installGPUDrivers() {
    mkdir -p $GPU_DEST/tmp
    retrycmd_if_failure_no_stats 120 5 25 curl -fsSL https://nvidia.github.io/nvidia-docker/gpgkey > $GPU_DEST/tmp/aptnvidia.gpg || exit $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
    wait_for_apt_locks
    retrycmd_if_failure 120 5 25 apt-key add $GPU_DEST/tmp/aptnvidia.gpg || exit $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
    wait_for_apt_locks
    retrycmd_if_failure_no_stats 120 5 25 curl -fsSL https://nvidia.github.io/nvidia-docker/ubuntu${UBUNTU_RELEASE}/nvidia-docker.list > $GPU_DEST/tmp/nvidia-docker.list || exit  $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
    wait_for_apt_locks
    retrycmd_if_failure_no_stats 120 5 25 cat $GPU_DEST/tmp/nvidia-docker.list > /etc/apt/sources.list.d/nvidia-docker.list || exit  $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
    apt_get_update
    retrycmd_if_failure 30 5 3600 apt-get install -y linux-headers-$(uname -r) gcc make dkms || exit $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
    retrycmd_if_failure 30 5 60 curl -fLS https://us.download.nvidia.com/tesla/$GPU_DV/NVIDIA-Linux-x86_64-${GPU_DV}.run -o ${GPU_DEST}/nvidia-drivers-${GPU_DV} || exit $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
    tmpDir=$GPU_DEST/tmp
    if ! (
      set -e -o pipefail
      cd "${tmpDir}"
      retrycmd_if_failure 30 5 3600 apt-get download nvidia-docker2="${NVIDIA_DOCKER_VERSION}+docker18.09.2-1" || exit $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
    ); then
      exit $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
    fi
}

installSGXDrivers() {
    echo "Installing SGX driver"
    local VERSION
    VERSION=$(grep DISTRIB_RELEASE /etc/*-release| cut -f 2 -d "=")
    case $VERSION in
    "18.04")
        SGX_DRIVER_URL="https://download.01.org/intel-sgx/dcap-1.2/linux/dcap_installers/ubuntuServer18.04/sgx_linux_x64_driver_1.12_c110012.bin"
        ;;
    "16.04")
        SGX_DRIVER_URL="https://download.01.org/intel-sgx/dcap-1.2/linux/dcap_installers/ubuntuServer16.04/sgx_linux_x64_driver_1.12_c110012.bin"
        ;;
    "*")
        echo "Version $VERSION is not supported"
        exit 1
        ;;
    esac

    local PACKAGES="make gcc dkms"
    wait_for_apt_locks
    retrycmd_if_failure 30 5 3600 apt-get -y install $PACKAGES  || exit $ERR_SGX_DRIVERS_INSTALL_TIMEOUT

    local SGX_DRIVER
    SGX_DRIVER=$(basename $SGX_DRIVER_URL)
    local OE_DIR=/opt/azure/containers/oe
    mkdir -p ${OE_DIR}

    retrycmd_if_failure 120 5 25 curl -fsSL ${SGX_DRIVER_URL} -o ${OE_DIR}/${SGX_DRIVER} || exit $ERR_SGX_DRIVERS_INSTALL_TIMEOUT
    chmod a+x ${OE_DIR}/${SGX_DRIVER}
    ${OE_DIR}/${SGX_DRIVER} || exit $ERR_SGX_DRIVERS_START_FAIL
}

installContainerRuntime() {
    if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
        installMoby
    fi
}

installMoby() {
    CURRENT_VERSION=$(dockerd --version | grep "Docker version" | cut -d "," -f 1 | cut -d " " -f 3)
    if [[ "$CURRENT_VERSION" == "${MOBY_VERSION}" ]]; then
        echo "dockerd $MOBY_VERSION is already installed, skipping Moby download"
    else
        removeMoby
        retrycmd_if_failure_no_stats 120 5 25 curl https://packages.microsoft.com/config/ubuntu/${UBUNTU_RELEASE}/prod.list > /tmp/microsoft-prod.list || exit $ERR_MOBY_APT_LIST_TIMEOUT
        retrycmd_if_failure 10 5 10 cp /tmp/microsoft-prod.list /etc/apt/sources.list.d/ || exit $ERR_MOBY_APT_LIST_TIMEOUT
        retrycmd_if_failure_no_stats 120 5 25 curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/microsoft.gpg || exit $ERR_MS_GPG_KEY_DOWNLOAD_TIMEOUT
        retrycmd_if_failure 10 5 10 cp /tmp/microsoft.gpg /etc/apt/trusted.gpg.d/ || exit $ERR_MS_GPG_KEY_DOWNLOAD_TIMEOUT
        apt_get_update || exit $ERR_APT_UPDATE_TIMEOUT
        MOBY_CLI=${MOBY_VERSION}
        if [[ "${MOBY_CLI}" == "3.0.4" ]]; then
            MOBY_CLI="3.0.3"
        fi
        apt_get_install 20 30 120 moby-engine=${MOBY_VERSION}* moby-cli=${MOBY_CLI}* --allow-downgrades || exit $ERR_MOBY_INSTALL_TIMEOUT
    fi
}

installKataContainersRuntime() {
    echo "Adding Kata Containers repository key..."
    ARCH=$(arch)
    BRANCH=stable-1.7
    KATA_RELEASE_KEY_TMP=/tmp/kata-containers-release.key
    KATA_URL=http://download.opensuse.org/repositories/home:/katacontainers:/releases:/${ARCH}:/${BRANCH}/xUbuntu_${UBUNTU_RELEASE}/Release.key
    retrycmd_if_failure_no_stats 120 5 25 curl -fsSL $KATA_URL > $KATA_RELEASE_KEY_TMP || exit $ERR_KATA_KEY_DOWNLOAD_TIMEOUT
    wait_for_apt_locks
    retrycmd_if_failure 30 5 30 apt-key add $KATA_RELEASE_KEY_TMP || exit $ERR_KATA_APT_KEY_TIMEOUT
    echo "Adding Kata Containers repository..."
    echo "deb http://download.opensuse.org/repositories/home:/katacontainers:/releases:/${ARCH}:/${BRANCH}/xUbuntu_${UBUNTU_RELEASE}/ /" > /etc/apt/sources.list.d/kata-containers.list
    echo "Installing Kata Containers runtime..."
    apt_get_update || exit $ERR_APT_UPDATE_TIMEOUT
    apt_get_install 120 5 25 kata-runtime || exit $ERR_KATA_INSTALL_TIMEOUT
}

installNetworkPlugin() {
    if [[ "${NETWORK_PLUGIN}" = "azure" ]]; then
        installAzureCNI
    fi
    installCNI
    rm -rf $CNI_DOWNLOADS_DIR &
}

downloadCNI() {
    mkdir -p $CNI_DOWNLOADS_DIR
    CNI_TGZ_TMP=$(echo ${CNI_PLUGINS_URL} | cut -d "/" -f 5)
    retrycmd_get_tarball 120 5 "$CNI_DOWNLOADS_DIR/${CNI_TGZ_TMP}" ${CNI_PLUGINS_URL} || exit $ERR_CNI_DOWNLOAD_TIMEOUT
}

downloadAzureCNI() {
    mkdir -p $CNI_DOWNLOADS_DIR
    CNI_TGZ_TMP=$(echo ${VNET_CNI_PLUGINS_URL} | cut -d "/" -f 5)
    retrycmd_get_tarball 120 5 "$CNI_DOWNLOADS_DIR/${CNI_TGZ_TMP}" ${VNET_CNI_PLUGINS_URL} || exit $ERR_CNI_DOWNLOAD_TIMEOUT
}

downloadContainerd() {
    CONTAINERD_DOWNLOAD_URL="${CONTAINERD_DOWNLOAD_URL_BASE}cri-containerd-${CONTAINERD_VERSION}.linux-amd64.tar.gz"
    mkdir -p $CONTAINERD_DOWNLOADS_DIR
    CONTAINERD_TGZ_TMP=$(echo ${CONTAINERD_DOWNLOAD_URL} | cut -d "/" -f 5)
    retrycmd_get_tarball 120 5 "$CONTAINERD_DOWNLOADS_DIR/${CONTAINERD_TGZ_TMP}" ${CONTAINERD_DOWNLOAD_URL} || exit $ERR_CONTAINERD_DOWNLOAD_TIMEOUT
}

ensureAPMZ() {
    local version=$1
    local apmz_url="https://upstreamartifacts.blob.core.windows.net/apmz/$version/binaries/apmz_linux_amd64.tar.gz" apmz_filepath="/usr/local/bin/apmz"
    if [[ -f "$apmz_filepath" ]]; then
        installed_version=$($apmz_filepath version)
        if [[ "$version" == "$installed_version" ]]; then
            # already installed, noop
            return
        fi
        # linked, but not the version we expect
    fi
    install_dir="$APMZ_DOWNLOADS_DIR/$version"
    download_path="$install_dir/apmz.gz"
    mkdir -p "$install_dir"
    retrycmd_get_tarball 120 5 "$download_path" "${apmz_url}"
    tar -xvf "$download_path" -C "$install_dir"
    bin_path="$install_dir/apmz_linux_amd64"
    chmod +x "$bin_path"
    ln -Ffs "$bin_path" "$apmz_filepath" # symlink apmz into /usr/local/bin/apmz
}

installCNI() {
    CNI_TGZ_TMP=${CNI_PLUGINS_URL##*/} # Use bash builtin ## to remove all chars ("*") up to the final "/"
    if [[ ! -f "$CNI_DOWNLOADS_DIR/${CNI_TGZ_TMP}" ]]; then
        downloadCNI
    fi
    mkdir -p $CNI_BIN_DIR
    tar -xzf "$CNI_DOWNLOADS_DIR/${CNI_TGZ_TMP}" -C $CNI_BIN_DIR
    chown -R root:root $CNI_BIN_DIR
    chmod -R 755 $CNI_BIN_DIR
}

installAzureCNI() {
    CNI_TGZ_TMP=${VNET_CNI_PLUGINS_URL##*/} # Use bash builtin ## to remove all chars ("*") up to the final "/"
    if [[ ! -f "$CNI_DOWNLOADS_DIR/${CNI_TGZ_TMP}" ]]; then
        downloadAzureCNI
    fi
    mkdir -p $CNI_CONFIG_DIR
    chown -R root:root $CNI_CONFIG_DIR
    chmod 755 $CNI_CONFIG_DIR
    mkdir -p $CNI_BIN_DIR
    tar -xzf "$CNI_DOWNLOADS_DIR/${CNI_TGZ_TMP}" -C $CNI_BIN_DIR
}

installContainerd() {
    CURRENT_VERSION=$(containerd -version | cut -d " " -f 3 | sed 's|v||')
    if [[ "$CURRENT_VERSION" == "${CONTAINERD_VERSION}" ]]; then
        echo "containerd is already installed, skipping install"
    else
        CONTAINERD_TGZ_TMP="cri-containerd-${CONTAINERD_VERSION}.linux-amd64.tar.gz"
        rm -Rf /usr/bin/containerd
        rm -Rf /var/lib/docker/containerd
        rm -Rf /run/docker/containerd
        if [[ ! -f "$CONTAINERD_DOWNLOADS_DIR/${CONTAINERD_TGZ_TMP}" ]]; then
            downloadContainerd
        fi
        tar -xzf "$CONTAINERD_DOWNLOADS_DIR/$CONTAINERD_TGZ_TMP" -C /
        sed -i '/\[Service\]/a ExecStartPost=\/sbin\/iptables -P FORWARD ACCEPT -w' /etc/systemd/system/containerd.service
        echo "Successfully installed cri-containerd..."
    fi
    rm -Rf $CONTAINERD_DOWNLOADS_DIR &
}

installImg() {
    img_filepath=/usr/local/bin/img
    retrycmd_get_executable 120 5 $img_filepath "https://upstreamartifacts.azureedge.net/img/img-linux-amd64-v0.5.6" ls || exit $ERR_IMG_DOWNLOAD_TIMEOUT
}

extractHyperkube() {
    CLI_TOOL=$1
    path="/home/hyperkube-downloads/${KUBERNETES_VERSION}"
    pullContainerImage $CLI_TOOL ${HYPERKUBE_URL}
    if [[ "$CLI_TOOL" == "docker" ]]; then
        mkdir -p "$path"
        # Check if we can extract kubelet and kubectl directly from hyperkube's binary folder
        if docker run --rm --entrypoint "" -v $path:$path ${HYPERKUBE_URL} /bin/bash -c "cp /usr/local/bin/{kubelet,kubectl} $path"; then
            mv "$path/kubelet" "/usr/local/bin/kubelet-${KUBERNETES_VERSION}"
            mv "$path/kubectl" "/usr/local/bin/kubectl-${KUBERNETES_VERSION}"
            return
        else
            docker run --rm -v $path:$path ${HYPERKUBE_URL} /bin/bash -c "cp /hyperkube $path"
        fi
    else
        img unpack -o "$path" ${HYPERKUBE_URL}
    fi

    if [[ $OS == $COREOS_OS_NAME ]]; then
        cp "$path/hyperkube" "/opt/kubelet"
        mv "$path/hyperkube" "/opt/kubectl"
        chmod a+x /opt/kubelet /opt/kubectl
    else
        cp "$path/hyperkube" "/usr/local/bin/kubelet-${KUBERNETES_VERSION}"
        mv "$path/hyperkube" "/usr/local/bin/kubectl-${KUBERNETES_VERSION}"
    fi
}

extractKubeBinaries() {
    KUBE_BINARY_URL=${KUBE_BINARY_URL:-"https://dl.k8s.io/v${KUBERNETES_VERSION}/kubernetes-node-linux-amd64.tar.gz"}
    # Split by "/" and get the last element
    K8S_TGZ_TMP=${KUBE_BINARY_URL##*/}
    mkdir -p "${K8S_DOWNLOADS_DIR}"
    retrycmd_get_tarball 120 5 "$K8S_DOWNLOADS_DIR/${K8S_TGZ_TMP}" ${KUBE_BINARY_URL} || exit $ERR_K8S_DOWNLOAD_TIMEOUT
    tar --transform="s|.*|&-${KUBERNETES_VERSION}|" --show-transformed-names -xzvf "$K8S_DOWNLOADS_DIR/${K8S_TGZ_TMP}" \
        --strip-components=3 -C /usr/local/bin kubernetes/node/bin/kubelet kubernetes/node/bin/kubectl
    rm -f "$K8S_DOWNLOADS_DIR/${K8S_TGZ_TMP}"
}

installKubeletAndKubectl() {
    if [[ ! -f "/usr/local/bin/kubectl-${KUBERNETES_VERSION}" ]]; then
        if version_gte ${KUBERNETES_VERSION} 1.17; then  # don't use hyperkube
            extractKubeBinaries
        else
            if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
                extractHyperkube "docker"
            else
                installImg
                extractHyperkube "img"
            fi
        fi
    fi
    mv "/usr/local/bin/kubelet-${KUBERNETES_VERSION}" "/usr/local/bin/kubelet"
    mv "/usr/local/bin/kubectl-${KUBERNETES_VERSION}" "/usr/local/bin/kubectl"
    chmod a+x /usr/local/bin/kubelet /usr/local/bin/kubectl
    rm -rf /usr/local/bin/kubelet-* /usr/local/bin/kubectl-* /home/hyperkube-downloads &
}

pullContainerImage() {
    CLI_TOOL=$1
    DOCKER_IMAGE_URL=$2
    retrycmd_if_failure 60 1 1200 $CLI_TOOL pull $DOCKER_IMAGE_URL || exit $ERR_CONTAINER_IMG_PULL_TIMEOUT
}

cleanUpContainerImages() {
    docker rmi $(docker images --format '{{OpenBraces}}.Repository{{CloseBraces}}:{{OpenBraces}}.Tag{{CloseBraces}}' | grep -v "${KUBERNETES_VERSION}$" | grep 'hyperkube') &
    docker rmi $(docker images --format '{{OpenBraces}}.Repository{{CloseBraces}}:{{OpenBraces}}.Tag{{CloseBraces}}' | grep -v "${KUBERNETES_VERSION}$" | grep 'cloud-controller-manager') &
    docker rmi $(docker images --format '{{OpenBraces}}.Repository{{CloseBraces}}:{{OpenBraces}}.Tag{{CloseBraces}}' | grep -v "${ETCD_VERSION}$" | grep 'etcd') &
    if [ "$IS_HOSTED_MASTER" = "false" ]; then
        echo "Cleaning up AKS container images, not an AKS cluster"
        docker rmi $(docker images --format '{{OpenBraces}}.Repository{{CloseBraces}}:{{OpenBraces}}.Tag{{CloseBraces}}' | grep 'hcp-tunnel-front') &
        docker rmi $(docker images --format '{{OpenBraces}}.Repository{{CloseBraces}}:{{OpenBraces}}.Tag{{CloseBraces}}' | grep 'kube-svc-redirect') &
        docker rmi $(docker images --format '{{OpenBraces}}.Repository{{CloseBraces}}:{{OpenBraces}}.Tag{{CloseBraces}}' | grep 'nginx') &
    fi

    docker rmi registry:2.7.1 &
}

cleanUpGPUDrivers() {
    rm -Rf $GPU_DEST
    rm -f /etc/apt/sources.list.d/nvidia-docker.list
}

cleanUpContainerd() {
    rm -Rf $CONTAINERD_DOWNLOADS_DIR
}

overrideNetworkConfig() {
    CONFIG_FILEPATH="/etc/cloud/cloud.cfg.d/80_azure_net_config.cfg"
    touch ${CONFIG_FILEPATH}
    cat << EOF >> ${CONFIG_FILEPATH}
datasource:
    Azure:
        apply_network_config: false
EOF
}
#EOF
