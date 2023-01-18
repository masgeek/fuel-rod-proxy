#!/usr/bin/env bash

docker build -f flask_app/Dockerfile -t app flask_app/. && docker build -f nginx/Dockerfile -t my-nginx nginx/.