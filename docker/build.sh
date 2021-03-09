#!/bin/sh
TMPDIR=/tmp/swift-build.tmp.$$
mkdir -p "${TMPDIR}"

#SWIFT_VERSIONS=(5.0.3)
SWIFT_VERSIONS=(5.0.3 5.1.5 5.2.5 5.3.3)

for version in "${SWIFT_VERSIONS[@]}"; do
    echo " == Building CI version ${version} =="
    cat > "${TMPDIR}/Dockerfile" << EOF
FROM swift:${version}

RUN apt-get update && apt-get install -y \
    git sudo wget pkg-config libcurl4-openssl-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir /project

WORKDIR /project
EOF
    docker build -t kitura/swift-ci:${version} "${TMPDIR}"
    docker push kitura/swift-ci:${version}


    echo " == Building Dev version ${version} =="
    cat > "${TMPDIR}/Dockerfile" << EOF
FROM kitura/swift-ci:${version}

RUN apt-get update && apt-get install -y \
    curl net-tools iproute2 netcat \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /project
EOF
    docker build -t kitura/swift-dev:${version} "${TMPDIR}"
    docker push kitura/swift-dev:${version}
done

# Create variants and push to Docker HUB

for variant in ci dev; do
    docker tag kitura/swift-${variant}:5.0.3 kitura/swift-${variant}:5.0
    docker push kitura/swift-${variant}:5.0
    docker tag kitura/swift-${variant}:5.1.5 kitura/swift-${variant}:5.1
    docker push kitura/swift-${variant}:5.1
    docker tag kitura/swift-${variant}:5.2.5 kitura/swift-${variant}:5.2
    docker push kitura/swift-${variant}:5.2
    docker tag kitura/swift-${variant}:5.3.3 kitura/swift-${variant}:5.3
    docker push kitura/swift-${variant}:5.3
    docker tag kitura/swift-${variant}:5.3   kitura/swift-${variant}:5
    docker push kitura/swift-${variant}:5
    docker tag kitura/swift-${variant}:5     kitura/swift-${variant}
    docker push kitura/swift-${variant}
done

# If private repo available, push a copy there
if [ ! -z "${KITURA_REPO}" -a ! -z "${KITURA_REPO_USER}" -a ! -z "${KITURA_REPO_PASSWORD}" ]; then
    echo "Pushing to private repo: ${KITURA_REPO}"
    docker login "${KITURA_REPO}" -u "${KITURA_REPO_USER}" --password-stdin <<EOF
${KITURA_REPO_PASSWORD}
EOF
    for variant in ci dev; do
        for version in \
            5.0.3 5.1.5 5.2.5 5.3.3 \
            5.0 5.1 5.2 5.3 \
            5 \
            ; do

            base_tag="kitura/swift-${variant}:${version}"
            docker tag ${base_tag} "${KITURA_REPO}"/${base_tag}
            docker push "${KITURA_REPO}"/${base_tag}

        done
    done
fi
