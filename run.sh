docker volume create graph
docker run --name=imageprovidertest --privileged --rm -e DOCKER_IN_DOCKER_ENABLED="true" -v /lib/modules:/lib/modules -v /sys/fs/cgroup:/sys/fs/cgroup -v $(pwd):/workspace -v graph:/docker-graph --entrypoint /usr/local/bin/runner.sh fedepaol/sriovjob:v1 bash -c "./diskimageprovidertest/setup.sh"
