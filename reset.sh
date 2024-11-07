#!/bin/bash

echo "this command is really destructive, probably. be careful!"

docker compose down
docker builder prune --all --force
docker image prune --all --force
pushd netbox-docker
docker compose down
popd


sudo rm -rf data/
