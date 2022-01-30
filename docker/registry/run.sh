#!/bin/sh
# Create docker registry

podman container stop kitura-registry
podman container rm kitura-registry

podman run --name kitura-registry \
    -p 8880:5000 \
    -p 8443:443 \
    -v $(pwd)/registry:/var/lib/registry:rw \
    -v $(pwd)/config:/etc/docker/registry:ro \
    -v $(pwd)/certs:/etc/docker/certs:ro \
    -e REGISTRY_HTTP_SECRET='whatisthissecretfor?' \
    -e REGISTRY_AUTH=htpasswd \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/etc/docker/config/htpasswd \
    -e REGISTRY_AUTH_HTPASSWD_REALM="Kitura Private Registry" \
    --rm \
    -it \
    "${@}" \
    registry:2.7.0 \
    /bin/sh

#    --restart=always \
#    -e REGISTRY_HTTP_TLS_CERTIFICATE=/etc/docker/certs/kituraci.crt \
#    -e REGISTRY_HTTP_TLS_KEY=/etc/docker/certs/kituraci.key \
