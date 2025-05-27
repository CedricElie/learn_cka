#!/bin/bash

# Script to set up a single-node Kubernetes cluster with Docker as CRI
# Designed for Rocky Linux 8.10

# --- Configuration ---
KUBERNETES_VERSION="1.29.0" # Specify the Kubernetes version (e.g., 1.29.0, 1.28.0)
POD_NETWORK_CIDR="10.244.0.0/16" # Pod network CIDR for Flannel
HOSTNAME=$(hostname) # Get the hostname of the machine

# --- Pre-flight Checks and System Preparation ---

echo "--- Starting Kubernetes Single Node Installation Script on Rocky Linux 8.10 ---"

# Check if the script is run as root or with sudo
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo or as root."
  exit 1
fi

echo "Disabling swap..."
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab # Comment out swap entries in fstab

echo "Enabling kernel modules and sysctl parameters for Kubernetes..."
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# sysctl params required by setup, params persist across reboots
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# FIX FOR IPv6 IMAGE PULL ERROR: Prioritize IPv4 for DNS lookups
echo "Prioritizing IPv4 for DNS lookups to avoid IPv6 connectivity issues..."
echo "precedence ::ffff:0:0/96 100" | tee -a /etc/gai.conf

echo "Disabling SELinux (permissive mode) and Firewalld..."
# Set SELinux to permissive mode
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

# Disable and stop Firewalld
systemctl disable --now firewalld
echo "Firewalld disabled. Opening necessary ports (though firewalld is off, listing for reference):"
echo "  - 6443 (Kubernetes API server)"
echo "  - 10250 (Kubelet API)"
echo "  - 10251 (Kube-scheduler)"
echo "  - 10252 (Kube-controller-manager)"
echo "  - 30000-32767 (NodePort Services)"
echo "  - 8285 (Flannel VXLAN UDP)"
echo "  - 8472 (Flannel VXLAN UDP)"


# --- Install Docker (CRI) ---

echo "Installing Docker as Container Runtime Interface (CRI)..."

# Add Docker repository
dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo

dnf install -y docker-ce docker-ce-cli containerd.io

# Configure Docker to use systemd cgroup driver
mkdir -p /etc/docker
cat <<EOF | tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

systemctl enable docker
systemctl restart docker

# --- Configure containerd for Kubernetes CRI ---
echo "Configuring containerd for Kubernetes CRI..."

# Generate default containerd config.toml
containerd config default | tee /etc/containerd/config.toml

# Set SystemdCgroup to true in containerd config
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Restart containerd service to apply changes
systemctl restart containerd
systemctl enable containerd # Ensure it's enabled on boot

echo "Verifying Docker and Containerd status..."
docker run hello-world || { echo "Docker installation failed. Exiting."; exit 1; }
systemctl is-active containerd || { echo "Containerd is not running. Exiting."; exit 1; }


# --- Install Kubernetes Components (kubeadm, kubelet, kubectl) ---

echo "Installing Kubernetes components (kubeadm, kubelet, kubectl)..."

# Add Kubernetes repository
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION%.*}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION%.*}/rpm/repodata/repomd.xml.key
EOF

# Install yum-utils if not present (often needed for dnf config-manager)
dnf install -y yum-utils

dnf install -y kubelet-"${KUBERNETES_VERSION}" kubeadm-"${KUBERNETES_VERSION}" kubectl-"${KUBERNETES_VERSION}" --disableexcludes=kubernetes
systemctl enable --now kubelet

echo "Verifying Kubernetes components installation..."
kubeadm version || { echo "Kubeadm installation failed. Exiting."; exit 1; }
kubectl version --client || { echo "Kubectl installation failed. Exiting."; exit 1; }

# --- Initialize Kubernetes Cluster ---

echo "Initializing Kubernetes cluster with kubeadm..."
# Use the correct --cri-socket path for containerd
kubeadm init --pod-network-cidr=${POD_NETWORK_CIDR} \
             --apiserver-advertise-address=$(hostname -I | awk '{print $1}') \
             --ignore-preflight-errors=NumCPU \
             --cri-socket=unix:///var/run/containerd/containerd.sock # Explicitly tell kubeadm the socket

# Check if kubeadm init was successful
if [ $? -ne 0 ]; then
  echo "Kubeadm initialization failed. Please check the logs above. Exiting."
  exit 1
fi

# --- Configure kubectl for the current user ---

echo "Configuring kubectl for the current user..."
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -un):$(id -gn) $HOME/.kube/config

# If you want to use kubectl as root
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config

# --- Install Pod Network Add-on (Flannel) ---

echo "Installing Pod Network Add-on (Flannel)..."
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

# It happens after installing the flannel, the coredns still dont go running, edit the cordns config map
# kubectl -n kube-system edit configmap coredns
# Find the Corefile data. Look for the forward . /etc/resolv.conf
# (Recommended): Point to a public upstream DNS server
#        forward . 8.8.8.8 8.8.4.4 {
#           max_concurrent 1000
#       }

# --- Taint Removal for Single Node (Master can schedule pods) ---

echo "Untainting the master node to allow pod scheduling..."
# Get the node name
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

# Remove the control-plane taint
kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane:NoSchedule- || \
kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/master:NoSchedule- # For older versions of kubeadm

# --- Verification ---

echo "--- Kubernetes Cluster Setup Complete! ---"
echo "Waiting for all pods to be ready (this may take a few minutes)..."
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=300s

echo ""
echo "You can check the cluster status using:"
echo "  kubectl get nodes"
echo "    kubectl get pods --all-namespaces"
echo ""
echo "To access the Kubernetes dashboard (if installed), you'll need to install it separately."
echo "Remember to save the output of 'kubeadm init' if you ever need to add more nodes (though this is a single-node setup)."
echo ""
echo "Enjoy your single-node Kubernetes cluster on Rocky Linux!"
