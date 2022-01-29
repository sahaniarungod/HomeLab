#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# PRESEED CONFIG: /machineConfigs/server/preseed.cfg
# ANSIBLE CONFIG: /ansible/k3s.yaml

# Setup DHCP Network
# virsh net-edit default
# <host mac='10:10:00:00:00:03' ip='10.10.10.3'/>
# <host mac='10:10:00:00:00:04' ip='10.10.10.4'/>
# <host mac='10:10:00:00:00:05' ip='10.10.10.5'/>
# <host mac='10:10:00:00:00:06' ip='10.10.10.6'/>
# <host mac='10:10:00:00:00:07' ip='10.10.10.7'/>
# <host mac='10:10:00:00:00:08' ip='10.10.10.8'/>
# virsh net-destroy default
# virsh net-start default

export LIBVIRT_DEFAULT_URI=qemu:///system
export PREFIX="sk3s"       # Sandbox k3s
export K3S_TOKEN=${PREFIX} # Sandbox k3s
export NODES="-master-0 -master-1 -master-2 -worker-0 -worker-1 -worker-2"
export START_IP=3
PASSWORD=${PASSWORD:-}

stop_cluster() {
	for NODE in ${NODES}; do
		if virsh destroy "${PREFIX}${NODE}"; then
			echo "Shutting Down:${PREFIX}${NODE}"
		fi
	done

}

start_cluster() {
	for NODE in ${NODES}; do
		virsh start "${PREFIX}${NODE}"
		echo "Started ${PREFIX}${NODE}"
	done
}

reboot_cluster() {
	for NODE in ${NODES}; do
		virsh reboot "${PREFIX}${NODE}"
		echo "Started ${PREFIX}${NODE}"
	done
}

delete_cluster() {
	stop_cluster
	for NODE in ${NODES}; do
		echo "${NODE}"
		if virsh undefine "${PREFIX}${NODE}" --remove-all-storage; then
			echo "Deleting: ${PREFIX}${NODE}"
		fi
	done
}

ansible() {
	if [ -z "${PASSWORD}" ]; then
		echo -n Password:
		read -r -s PASSWORD
		echo ""
	fi
	IP=${START_IP}
	# Create Ansible Inventory File
	echo "[k3s]" >/tmp/inventory
	for NODE in ${NODES}; do
		echo "10.10.10.${IP}" >>/tmp/inventory
		((IP++))
	done
	# Run Playbooks On All Machines
	ansible-playbook -i /tmp/inventory ansible/k3s.yaml --extra-vars "ansible_become_pass=${PASSWORD} ansible_ssh_pass=${PASSWORD}"
}

label_cluster() {
	load_kubeconfig

	for NODE in ${NODES}; do
		ZONE="EVEN"
		if ((${NODE##*-} % 2)); then
			ZONE="ODD"
		fi
		kubectl label node "${PREFIX}${NODE}" topology.kubernetes.io/zone="${ZONE}" --overwrite
		kubectl label node "${PREFIX}${NODE}" node.longhorn.io/create-default-disk=true --overwrite
	done

}

load_kubeconfig() {
	export KUBECONFIG=${HOME}/vm/${PREFIX}/${PREFIX}.yaml
}
install_cluster() {
	echo -n Password:
	read -r -s PASSWORD
	echo ""

	# IP Counter
	IP=${START_IP}

	# Delete Cluster If Exists
	delete_cluster

	mkdir -p "${HOME}/vm/${PREFIX}"

	for NODE in ${NODES}; do
		echo "${PREFIX}${NODE}"

		# Install VM
		#--debug \
		#--wait=-1 \
		virt-install \
			--noautoconsole \
			--name="${PREFIX}${NODE}" \
			--os-variant=debian11 \
			--vcpus sockets=1,cores=1,threads=2 \
			--ram=4096 \
			--disk "${HOME}/vm/${PREFIX}/${PREFIX}${NODE}".img,size=25 \
			--network network=default,model=virtio,mac="10:10:00:00:00:0${IP}" \
			--location=http://ftp.us.debian.org/debian/dists/stable/main/installer-amd64/ \
			--extra-args="\
	  auto=true priority=critical vga=normal hostname=${PREFIX}${NODE} \
	  url=http://10.0.0.3:7071/preseed.cfg"
		# https://crysol.org/recipe/2012-12-25/virtual-machine-unattended-debian-installations-with-libvirt-and-d-i-preseeding.html

		((IP++))
	done

	# Wait for Machines to Finish Installing OS, Then Boot Machines
	for NODE in ${NODES}; do
		# https://serverfault.com/a/386867
		finished="0"
		while [ "$finished" = "0" ]; do
			sleep 5
			if [ "$(virsh list --all | grep 'running' | grep "${PREFIX}${NODE}" | wc -c)" -eq 0 ]; then
				echo "Starting vm ${PREFIX}${NODE}"
				sleep 1
				virsh start "${PREFIX}${NODE}"
				finished=1
			fi
		done
	done

	# Add Machines to Known Hosts
	IP=${START_IP}
	for NODE in ${NODES}; do
		finished="0"
		while [ "$finished" = "0" ]; do
			sleep 1
			if nc -z 10.10.10.${IP} 22; then
				ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "10.10.10.${IP}"
				ssh-keyscan 10.10.10.${IP} >>"${HOME}/.ssh/known_hosts"
				finished=1
			fi
		done
		((IP++))
	done

	# Run Playbooks On All Machines
	ansible
	reboot_cluster

	IP=${START_IP}
	for NODE in ${NODES}; do
		finished="0"
		while [ "$finished" = "0" ]; do
			sleep 1
			if nc -z 10.10.10.${IP} 22; then
				echo "${PREFIX}${NODE} is up."
				finished=1
			fi
		done
		((IP++))
	done

	# Install & Setup k3s
	INSTALL="echo ${PASSWORD} | sudo -S ls; curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server --cluster-init --disable traefik --kubelet-arg system-reserved=cpu=125m,memory=250Mi --kubelet-arg kube-reserved=cpu=125m,memory=250Mi' K3S_TOKEN=${K3S_TOKEN} INSTALL_K3S_CHANNEL=v1.22 sh -"
	SERVER="echo ${PASSWORD} 	| sudo -S ls; curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server --server https://10.10.10.3:6443 --disable traefik --kubelet-arg system-reserved=cpu=125m,memory=250Mi --kubelet-arg kube-reserved=cpu=125m,memory=250Mi' K3S_TOKEN=${K3S_TOKEN} INSTALL_K3S_CHANNEL=v1.22 sh -"
	WORKER="echo ${PASSWORD}	| sudo -S ls; curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--kubelet-arg system-reserved=cpu=125m,memory=250Mi --kubelet-arg kube-reserved=cpu=125m,memory=250Mi' K3S_URL=https://10.10.10.3:6443 K3S_TOKEN=${K3S_TOKEN} INSTALL_K3S_CHANNEL=v1.22 sh -"

	IP=${START_IP}
	for NODE in ${NODES}; do
		KUBE=0
		if [[ "${NODE}" =~ "master" || "${NODE}" =~ "server" ]]; then
			if [ ${IP} -eq ${START_IP} ]; then
				CONFIG=${INSTALL}
				KUBE=1
			else
				CONFIG=${SERVER}
			fi
		elif [[ "${NODE}" =~ "worker" || "${NODE}" =~ "agent" ]]; then
			CONFIG=${WORKER}
		fi

		echo "${PREFIX}${NODE}"
		sshpass -p "${PASSWORD}" ssh -t 10.10.10.${IP} "${CONFIG}"

		if [ ${KUBE} -eq 1 ]; then
			CMD="echo ${PASSWORD} | sudo -S cp /etc/rancher/k3s/k3s.yaml /tmp; sudo chmod 777 /tmp/k3s.yaml"
			sshpass -p "${PASSWORD}" ssh -t 10.10.10.${START_IP} "${CMD}"
			sshpass -p "${PASSWORD}" scp 10.10.10.${START_IP}:/tmp/k3s.yaml "${HOME}/vm/${PREFIX}/${PREFIX}.yaml"
			sed -i "s,127.0.0.1,10.10.10.${START_IP},g" "${HOME}/vm/${PREFIX}/${PREFIX}.yaml"
		fi
		((IP++))
	done

	label_cluster

	echo ""
	echo "export KUBECONFIG=${HOME}/vm/${PREFIX}/${PREFIX}.yaml"
	echo "${PREFIX} k3s Install Complete"

}

"$@"
