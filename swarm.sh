#!/bin/bash
#
# Author: Lucas Roesler <lucas@contiamo.com>
# Usage: ./swarm {deploy|teardown|leave|status}
#
# Examples:
#
# To create a new swarm:
#
#       $ ./swarm deploy
#
# To see the current state of the vms in the swarm
#
#       $ ./swarm status
#
# To teardown the swarm and vms
#
#       $ ./swarm teardown
#
# To teardown the swarm but keep the vms
#
#       $ ./swarm leave
#
# Updated by: Marcos Silva <massilva@outlook.com.br>

STACKNAME="privateregistry" #nome do serviço descrito no arquivo `docker-compose`
HOSTNAME="myregistry.com"
DOCKERMACHINEDRIVER="virtualbox"

MANAGERS=3
MANAGERNAMEPREFIX="manager-"
MANAGERNAME=$MANAGERNAMEPREFIX"1"
WORKERS=2
WORKERNAME="worker-"
REGISTRYPORT="5001"

function ssh_cp {
    docker-machine scp ./certs/domain.crt $1:/tmp/ca.crt
    docker-machine scp ./certs/cert.pem $1:/tmp/cert.pem
    docker-machine scp ./certs/domain.key $1:/tmp/domain.key
    docker-machine ssh $1 "sudo mkdir -p /etc/docker/certs.d/$HOSTNAME$i:$REGISTRYPORT/"
    docker-machine ssh $1 "sudo mkdir -p /home/docker/certs/"
    docker-machine ssh $1 "sudo cp /tmp/ca.crt /home/docker/certs/ca.pem"
    docker-machine ssh $1 "sudo cp /tmp/domain.key /home/docker/certs/key.pem"
    docker-machine ssh $1 "sudo cp /tmp/cert.pem /home/docker/certs/cert.pem"
    docker-machine ssh $1 "sudo mv /tmp/ca.crt /etc/docker/certs.d/$HOSTNAME$i:$REGISTRYPORT/ca.crt"
    docker-machine ssh $1 "sudo mv /tmp/domain.key /etc/docker/certs.d/$HOSTNAME$i:$REGISTRYPORT/client.key"
    docker-machine ssh $1 "sudo mv /tmp/cert.pem /etc/docker/certs.d/$HOSTNAME$i:$REGISTRYPORT/cert.pem"
    docker-machine ssh $1 "sudo chmod 644 certs/key.pem && sudo chown -R docker certs"
    docker-machine ssh $1 "sudo mkdir -p /home/docker/auth/"
    docker-machine ssh $1 "sudo [ -e /home/docker/auth/registry.password ] && sudo rm /home/docker/auth/registry.password"
    docker-machine scp ./auth/registry.password $1:/home/docker/auth/registry.password
}

function setup {

    echo "Creating swarm vms"
    for i in $(seq 1 $MANAGERS)
    do
	MANAGERNAME=$MANAGERNAMEPREFIX$i
	docker-machine create --driver $DOCKERMACHINEDRIVER $MANAGERNAME
    done

    for i in $(seq 1 $WORKERS)
    do
    	docker-machine create --driver $DOCKERMACHINEDRIVER $WORKERNAME$i
    done

    echo "Setup manager node for the swarm"
    MANAGERNAME=$MANAGERNAMEPREFIX"1"
    MANAGERID=$(docker-machine ls --filter "name=$MANAGERNAME" --format {{.URL}} | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}")
    docker-machine ssh $MANAGERNAME "docker swarm init --advertise-addr $MANAGERID" 1>/dev/null
    WORKERJOINTOKEN=$(docker-machine ssh $MANAGERNAME  "docker swarm join-token worker -q")
    MANAGERJOINTOKEN=$(docker-machine ssh $MANAGERNAME  "docker swarm join-token manager -q")

    echo "Setup manager nodes for the swarm"
    for i in $(seq 2 $MANAGERS)
    do
	MANAGERNAME=$MANAGERNAMEPREFIX$i
        echo "Joining $MANAGERNAME to $MANAGERNAMEPREFIX""1"
        docker-machine ssh $MANAGERNAME "docker swarm join --token $MANAGERJOINTOKEN $MANAGERID" 1>/dev/null
    done

    MANAGERNAME=$MANAGERNAMEPREFIX"1"
    echo "Setup worker nodes for the swarm"
    for i in $(seq 1 $WORKERS)
    do
    	echo "Joining $WORKERNAME$i to $MANAGERNAME"
    	docker-machine ssh $WORKERNAME$i "docker swarm join --token $WORKERJOINTOKEN $MANAGERID" 1>/dev/null
    done

    echo "Update node labels"
    docker-machine ssh $MANAGERNAME "docker node update --label-add registry=true $MANAGERNAME" 1>/dev/null

    mkdir -p certs
    echo "creating registry certs"
    openssl req -batch -subj /CN=$HOSTNAME\
           -newkey rsa:4096 -nodes -sha256 -keyout certs/domain.key \
           -x509 -days 365 -out certs/domain.crt
    cp certs/domain.crt certs/cert.pem

    echo "Copying registry certs to each machine"
    for i in $(seq 1 $MANAGERS)
    do
	MANAGERNAME=$MANAGERNAMEPREFIX$i
        ssh_cp "$MANAGERNAME"
    done

    for i in $(seq 1 $WORKERS)
    do
        ssh_cp "$WORKERNAME$i"
    done

    echo "# Run this command to configure your docker environment to use the $MANAGERNAME vm:"
    echo "# eval \$(docker-machine env $MANAGERNAME)"

    read -p "Would you like us to add $HOSTNAME name to your /etc/hosts for you? " yn
    case $yn in
        [Yy]* )
            addhost
            exit
            ;;
        * )
            echo "You must manually add this line to your /etc/hosts file"
            echo "    $(docker-machine ls --filter "name=$MANAGERNAME" --format {{.URL}} | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}")\t$HOSTNAME"
            echo "To use the default '$HOSTNAME' name in your browser."
            ;;
    esac
    exit
}

function leave_swarm {
    echo "Tear down the swarm"
    for i in $(seq 1 $WORKERS)
    do
        echo "Tear down $WORKERNAME$i ..."
        docker-machine ssh $WORKERNAME$i "docker swarm leave"
    done

    for i in $(seq 1 $MANAGERS)
    do
	MANAGERNAME=$MANAGERNAMEPREFIX$i
        echo "Tear down $MANAGERNAME ..."
        docker-machine ssh $MANAGERNAME "docker swarm leave --force"
    done
}

function remove_vms {
    echo "Tear down the vms"
    for i in $(seq 1 $WORKERS)
    do
	echo "Removing $WORKERNAME$i"
        docker-machine rm $WORKERNAME$i -y
    done
    for i in $(seq 1 $MANAGERS)
    do
	MANAGERNAME=$MANAGERNAMEPREFIX$i
	echo "Removing $MANAGERNAME"
        docker-machine rm $MANAGERNAME -y
    done
}

function teardown {
    leave_swarm
    remove_vms
    removehost
    exit
}

function status {
    docker-machine ssh $MANAGERNAME "docker node ls"
}

function addhost {
    echo "Adding $HOSTNAME to your /etc/hosts, this will require your sudo password"
    WORKERIP=$(docker-machine ls --filter "name=$MANAGERNAME" --format {{.URL}} | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}")
    if ! grep -q "$WORKERIP\t$HOSTNAME" /etc/hosts; then
        sudo -- sh -c -e "echo '$WORKERIP\t$HOSTNAME' >> /etc/hosts"
    fi
}

function removehost {
    if [ -n "$(grep $HOSTNAME /etc/hosts)" ]
    then
        read -p "Would you like remove $HOSTNAME from your /etc/hosts? " yn
        if [[ $yn =~ [Yy]* ]]
        then
            echo "This requires your sudo password"
            sudo  -- sh -c -e "sed -i '.bak' '/$HOSTNAME/d' /etc/hosts >> /etc/hosts"
        fi
    else
        echo "$HOSTNAME was not found in your /etc/hosts";
    fi
}

function deploy_stack {
    for i in $(seq 1 $WORKERS)
    do
	    MANAGERNAME=$MANAGERNAMEPREFIX$i

	    echo "Deploying the $STACKNAME stack $MANAGERNAME:"
	    docker-machine ssh $MANAGERNAME "mkdir -p certs/"
	    docker-machine ssh $MANAGERNAME "mkdir -p auth/"
	    docker-machine ssh $MANAGERNAME "mkdir -p data/"

	    docker-machine scp docker-compose.yml $MANAGERNAME:/home/docker/
	    echo ""
	    echo "Copying to $MANAGERNAME"
	    ssh_cp "$MANAGERNAME"
    done

    MANAGERNAME=$MANAGERNAMEPREFIX"1"

    for i in $(seq 1 $WORKERS)
    do
        echo ""
        echo "Copying to $WORKERNAME$i"
        docker-machine scp docker-compose.yml $MANAGERNAME:/home/docker/
        ssh_cp "$WORKERNAME$i"
    done
    docker-machine ssh $MANAGERNAME "docker stack deploy $STACKNAME --prune --compose-file docker-compose.yml #2>/dev/null"
    docker-machine ssh $MANAGERNAME "docker stack ps $STACKNAME"
    echo "Done"
}

function build_image {
    if [ -z "$1" ] || [ -z "$2" ]
    then
        echo $"Usage: $0 build <DOCKERFILE> <IMAGENAME>:<VERSION>"
    else
        echo $"Building $2 using $1"
    	docker build -f $1 -t $2 .
    fi
}

function tag_image {
    if [ -z "$1" ] || [ -z "$2" ]
    then
        echo $"Usage: $0 tag SOURCE_IMAGE[:TAG] TARGET_IMAGE[:TAG]"
    else
        echo $"Tagging $1 to $2"
    	docker tag $1 $2
    fi
}

function stop {
    docker stack rm $STACHNAME
}

function usage {
    echo $"Usage: $0 {init|build|deploy|stop|status|teardown|leave|tag|viz}"
    echo ""
    echo "\tCreate or destroy a local $STACKNAME docker swarm."
}

function viz_service {
    echo "Deploy visualization service"
    docker-machine ssh $MANAGERNAME "docker service create \
	--name=viz \
	--publish=8080:8080 \
	--constraint=node.role==manager \
	--mount=type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
	dockersamples/visualizer"
}

case "$1" in
    init)
        setup
        ;;
    leave)
        leave_swarm
        ;;
    teardown)
        teardown
        ;;
    status)
        status
        ;;
    deploy)
        eval $(docker-machine env $MANAGERNAME)
        deploy_stack
        ;;
    stop)
        eval $(docker-machine env $MANAGERNAME)
        stop
        ;;
    build)
        build_image "$2" "$3"
        ;;
    tag)
        tag_image "$2" "$3"
        ;;
    viz)
        viz_service
        ;;
    addhost)
        addhost
        ;;
    *)
        usage
        exit 1
esac
