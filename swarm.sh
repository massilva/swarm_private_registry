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

MANAGERNAME="master"
WORKERS=2
WORKERNAME="worker-"
REGISTRYPORT="5001"

function setup {

    echo "Creating swarm vms"
    docker-machine create --driver $DOCKERMACHINEDRIVER $MANAGERNAME
    for i in $(seq 1 $WORKERS)
    do
    	docker-machine create --driver $DOCKERMACHINEDRIVER $WORKERNAME$i
    done

    echo "Setup manager node for the swarm"
    MANAGERID=$(docker-machine ls --filter "name=$MANAGERNAME" --format {{.URL}} | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}")
    docker-machine ssh $MANAGERNAME "docker swarm init --advertise-addr $MANAGERID" 1>/dev/null
    WORKERJOINTOKEN=$(docker-machine ssh $MANAGERNAME  "docker swarm join-token worker -q")

    echo "Setup worker nodes for the swarm"
    for i in $(seq 1 $WORKERS)
    do
    	echo "Joining $WORKERNAME$i to $MANAGERNAME"
    	docker-machine ssh $WORKERNAME$i "docker swarm join --token $WORKERJOINTOKEN $MANAGERID" 1>/dev/null
    done

    echo "Update node labels"
    docker-machine ssh $MANAGERNAME "docker node update --label-add registry=true $MANAGERNAME" 1>/dev/null

    echo "creating registry certs"
    mkdir -p certs
    openssl req -batch -subj /CN=$HOSTNAME\
          -newkey rsa:4096 -nodes -sha256 -keyout certs/domain.key \
          -x509 -days 365 -out certs/domain.crt

    echo "Copying registry certs to each machine"
    docker-machine scp ./certs/domain.crt $MANAGERNAME:/tmp/ca.crt
    docker-machine ssh $MANAGERNAME "sudo mkdir -p /etc/docker/certs.d/$HOSTNAME$i:$REGISTRYPORT/"
    docker-machine ssh $MANAGERNAME "sudo mv /tmp/ca.crt /etc/docker/certs.d/$HOSTNAME$i:$REGISTRYPORT/ca.crt"

    for i in $(seq 1 $WORKERS)
    do
        docker-machine scp ./certs/domain.crt $WORKERNAME$i:/tmp/ca.crt
        docker-machine ssh $WORKERNAME$i "sudo mkdir -p /etc/docker/certs.d/$HOSTNAME$i:$REGISTRYPORT/"
        docker-machine ssh $WORKERNAME$i "sudo mv /tmp/ca.crt /etc/docker/certs.d/$HOSTNAME$i:$REGISTRYPORT/ca.crt"
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
    echo "Tear down $MANAGERNAME ..."
    docker-machine ssh $MANAGERNAME "docker swarm leave --force"
}

function remove_vms {
    echo "Tear down the vms"
    for i in $(seq 1 $WORKERS)
    do
        docker-machine rm $WORKERNAME$i
    done
    docker-machine rm $MANAGERNAME
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
    sudo -- sh -c -e "echo '$WORKERIP\t$HOSTNAME' >> /etc/hosts"
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
    echo "Deploying the $STACKNAME stack"
    docker stack deploy $STACKNAME --prune --compose-file docker-compose.yaml #2>/dev/null
    docker stack ps $STACKNAME
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
    echo $"Usage: $0 {init|build|deploy|stop|status|teardown|leave}"
    echo ""
    echo "\tCreate or destroy a local $STACKNAME docker swarm."
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
    *)
        usage
        exit 1
esac
