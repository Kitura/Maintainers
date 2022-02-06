#!/bin/sh
# Create docker registry
. secrets

podman container stop kitura-registry
podman container rm kitura-registry

podman container stop kitura-registry-ui
podman container rm kitura-registry-ui

podman run --name kitura-registry-ui \
    -d \
    -p 8881:80 \
    -e ENV_DOCKER_REGISTRY_HOST=localhost \
    -e ENV_DOCKER_REGISTRY_PORT=5000 \
    -e ENV_REGISTRY_PROXY_FQDN=docker.kitura.net \
    -e ENV_REGISTRY_PROXY_PORT=443 \
    --rm \
    konradkleine/docker-registry-frontend:v2


podman run --name kitura-registry \
    -p 8880:5000 \
    -v $(pwd)/registry:/var/lib/registry:rw \
    -v $(pwd)/auth:/etc/docker/auth:ro \
    -e REGISTRY_HTTP_SECRET='whatisthissecretfor?' \
    -e REGISTRY_AUTH=htpasswd \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/etc/docker/auth/htpasswd \
    -e REGISTRY_AUTH_HTPASSWD_REALM="Kitura Private Registry" \
    -e REGISTRY_STORAGE=s3 \
    -e REGISTRY_STORAGE_S3_REGIONENDPOINT="${REGISTRY_STORAGE_S3_REGIONENDPOINT}" \
    -e REGISTRY_STORAGE_S3_REGION="${REGISTRY_STORAGE_S3_REGION}" \
    -e REGISTRY_STORAGE_S3_ACCESSKEY="${REGISTRY_STORAGE_S3_ACCESSKEY}" \
    -e REGISTRY_STORAGE_S3_SECRETKEY="${REGISTRY_STORAGE_S3_SECRETKEY}" \
    -e REGISTRY_STORAGE_S3_BUCKET="${REGISTRY_STORAGE_S3_BUCKET}" \
    -e REGISTRY_STORAGE_S3_ROOTDIRECTORY="${REGISTRY_STORAGE_S3_ROOTDIRECTORY}" \
    -e REGISTRY_STORAGE_S3_ENCRYPT=false \
    -e REGISTRY_STORAGE_S3_V4AUTH=true \
    -e REGISTRY_STORAGE_S3_CHUNKSIZE=5242880 \
    -e REGISTRY_STORAGE_S3_SECURE=true \
    --rm \
    "${@}" \
    registry:2.7.0


#    --restart=always \
#    -e REGISTRY_HTTP_TLS_CERTIFICATE=/etc/docker/certs/kituraci.crt \
#    -e REGISTRY_HTTP_TLS_KEY=/etc/docker/certs/kituraci.key \
#    -v $(pwd)/certs:/etc/docker/certs:ro \
#    -v $(pwd)/config:/etc/docker/registry:ro \


# Resources:
#  https://docs.docker.com/registry/storage-drivers/s3/
#
# h ttps://icicimov.github.io/blog/docker/Docker-Private-Registry-with-S3-backend-on-AWS/
#

