#!/bin/sh
# A script to use to get a Linux environment capable of running Swift

podman build -t kitura-docker-bootstrap:latest -<<EOF
FROM swift:latest

RUN apt-get update && apt-get install -y \
    vim \
    docker.io \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/mxcl/swift-sh.git && \
    (cd swift-sh && swift build -c release) && \
    cp swift-sh/.build/release/swift-sh /usr/local/bin/swift-sh && \
    rm -rf swift-sh
RUN mkdir /project && cd /project
RUN cd /project && \
    git clone https://github.com/Kitura/Maintainers.git && \
    (cd Maintainers/docker/image_creator && ./build.swift -h)

WORKDIR /project
ENTRYPOINT ["/bin/bash"]

EOF
#podman run --name swift -it -v .:/project:rw -w /project --rm swift:latest  /bin/bash
