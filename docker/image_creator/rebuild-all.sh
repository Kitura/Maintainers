#!/bin/sh

#podman login docker.io
#podman login docker.kitura.net

caffeinate -di  ./build.swift --registry https://docker.kitura.net --enable-build  --enable-push --enable-aliases --enable-ubuntu --enable-centos -v "${@}"
