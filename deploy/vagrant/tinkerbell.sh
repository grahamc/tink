#!/bin/bash

# abort this script on errors
set -euxo pipefail

whoami

cd /vagrant

setup_docker() (
	# steps from https://docs.docker.com/engine/install/ubuntu/
	sudo apt-get install -y \
	     apt-transport-https \
	     ca-certificates \
	     curl \
	     gnupg-agent \
	     software-properties-common

	curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
		| sudo apt-key add -

	local repo
	repo=$(
		printf "deb [arch=amd64] https://download.docker.com/linux/ubuntu %s stable" \
		       "$(lsb_release -cs)"
	    )
	sudo add-apt-repository "$repo"

	sudo apt-get update
	sudo apt-get install -y docker-ce docker-ce-cli containerd.io

       	sudo usermod -aG docker "$USER"

	newgrp
)

setup_docker_compose() (
	# from https://docs.docker.com/compose/install/
	sudo curl -L \
	     "https://github.com/docker/compose/releases/download/1.26.0/docker-compose-$(uname -s)-$(uname -m)" \
	     -o /usr/local/bin/docker-compose

	sudo chmod +x /usr/local/bin/docker-compose
)

make_certs_writable() (
	local certdir="/etc/docker/certs.d/$TINKERBELL_HOST_IP"
	sudo mkdir -p "$certdir"
	sudo chown -R "$USER" "$certdir"
)

secure_certs() (
	local certdir="/etc/docker/certs.d/$TINKERBELL_HOST_IP"
	sudo chown "root" "$certdir"
)

command_exists() (
	command -v "$@" >/dev/null 2>&1
)

mirror_hello_world() (
	# push the hello-world workflow action image
	docker pull hello-world
	docker tag hello-world "$TINKERBELL_HOST_IP/hello-world"
	docker push "$TINKERBELL_HOST_IP/hello-world"
)

main() (
	export DEBIAN_FRONTEND=noninteractive

	apt-get update

	if ! command_exists docker; then
		setup_docker
	fi

	if ! command_exists docker-compose; then
		setup_docker_compose
	fi

	if ! command_exists jq; then
		sudo apt-get install -y jq
	fi

	if [ ! -f ./envrc ]; then
 		./generate-envrc.sh eth1 > envrc
	fi

	. ./envrc

	make_certs_writable

	./setup.sh

	secure_certs

	mirror_hello_world

	cd deploy
	docker-compose up -d

	provisioner_ip_address=$TINKERBELL_HOST_IP

# create the hello-world workflow template
docker exec -i deploy_tink-cli_1 sh -c 'cat >/tmp/hello-world.tmpl' <<EOF
version: '0.1'
global_timeout: 60
tasks:
  - name: hello-world
    worker: {{.device_1}}
    actions:
      - name: hello-world
        image: hello-world
        timeout: 60
EOF
template_output="$(docker exec -i deploy_tink-cli_1 tink template create --name hello-world --path /tmp/hello-world.tmpl)"
template_id="$(echo "$template_output" | perl -n -e '/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/ && print $1')"
docker exec -i deploy_tink-cli_1 tink template get "$template_id"

# setup worker hardware and respective workflow
worker_host_number=11
worker_ip_address="$(echo $provisioner_ip_address | cut -d "." -f 1).$(echo $provisioner_ip_address | cut -d "." -f 2).$(echo $provisioner_ip_address | cut -d "." -f 3).$worker_host_number"
worker_mac_address="08:00:27:00:00:01"

# create the hardware.
docker exec -i deploy_tink-cli_1 tink hardware push <<EOF
{
  "id": "870fe43f-a58e-4f69-af39-0d612a6587c1",
  "arch": "x86_64",
  "allow_pxe": true,
  "allow_workflow": true,
  "facility_code": "onprem",
  "ip_addresses": [
    {
      "enabled": true,
      "address_family": 4,
      "address": "$worker_ip_address",
      "netmask": "255.255.255.248",
      "gateway": "$provisioner_ip_address",
      "management": true,
      "public": false
    }
  ],
  "network_ports": [
    {
      "data": {
        "mac": "$worker_mac_address"
      },
      "name": "eth0",
      "type": "data"
    }
  ]
}
EOF
docker exec -i deploy_tink-cli_1 tink hardware mac "$worker_mac_address" | jq .

# create the workflow.
workflow_output="$(docker exec -i deploy_tink-cli_1 tink workflow create -t "$template_id" -r "{\"device_1\": \"$worker_mac_address\"}")"
workflow_id="$(echo "$workflow_output" | perl -n -e '/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/ && print $1')"
docker exec -i deploy_tink-cli_1 tink workflow get "$workflow_id"

# show summary
# e.g. inet 192.168.121.160/24 brd 192.168.121.255 scope global dynamic eth0
host_ip_address="$(ip addr show eth0 | perl -n -e'/ inet (\d+(\.\d+)+)/ && print $1')"
cat <<EOF

#################################################
#
# tink envrc
#

$(cat /root/tink/envrc)

#################################################
#
# addresses
#

kibana: http://$host_ip_address:5601

EOF
)

main
