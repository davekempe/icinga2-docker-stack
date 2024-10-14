#!/bin/bash


docker compose down
docker builder prune --all --force
docker image prune --all --force

sudo rm -rf data/
