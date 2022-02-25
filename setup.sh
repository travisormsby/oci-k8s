#!/bin/bash

NODETYPE = $1

apt update && apt upgrade -y

# Configure rerequisites for containerd
cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Let iptables see bridged traffic
cat <<EOF | tee /etc/modules-load.d/k8s.conf
br_netfilter
EOF

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF

sysctl --system

# Install containerd container runtime
apt-get install ca-certificates curl gnupg lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install containerd.io

# Configure containerd
mkdir -p /etc/containerd
cp config.toml /etc/containerd/config.toml
systemctl restart containerd

# Install Kubernetes components
apt-get install -y apt-transport-https ca-certificates curl
curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Disable swap (prerequisite for kubelet to run)
swapoff -a

# Save default iptables configuration to enable restore
iptables-save > iptables.txt
apt install firewalld -y

if [ $NODETYPE = control ]
then
    # Configure firewall
    firewall-cmd --zone=public --permanent --add-port=(6443/tcp, 2379-2380/tcp, 10259/tcp, 10257/tcp, 10250/tcp, 6783/tcp, 6783-6784/udp)
    firewall-cmd --reload
    firewall-cmd --zone=public --permanent --list-ports
    
    # Bootstrap cluster
    kubeadm init

    # Enable non-root user to use kubectl
    mkdir -p $HOME/.kube
    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    chown $(id -u):$(id -g) $HOME/.kube/config
    
    # Install weave-net pod network
    kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
    
    echo "Make note of the kubeadm join command above. Use it to join worker nodes to the cluster"

elif [ $NODETYPE = worker ]
then 
    # Configure firewall
    firewall-cmd --zone=public --permanent --add-port=(10250/tcp, 30000-32767/tcp, 6783/tcp, 6783-6784/udp)
    firewall-cmd --reload
    firewall-cmd --zone=public --permanent --list-ports
    
    echo "Most configuration complete. Join this node to the cluster with the command created when initializing the control plane"
else
    echo "Most configuration complete. Configure firewall before initializing the cluster or joining this node to an existing cluster."
fi