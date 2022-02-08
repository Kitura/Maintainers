# Container registry for Kitura CI

This directory is used to setup a container registry for Kitura CI systems.

* `docker.kitura.net` hosts a docker registry and web frontend.
* `build.kitura.net` is used to store access credentials needed for CI builds.  This is done so that pull requests from non-maintainers will still be able to pull the docker images.  In addition the credentials may be randomized, allowing for CI builds to function without change.
* The hosts above require SSL and can only be accessed via an SSL proxy, which also has IP address filtering to limit access.

This script relies on storing the container images in an S3 compatible storage system.

1. Create a `secrets` file that contains the relevant S3 parameters:
    * REGISTRY_STORAGE_S3_REGIONENDPOINT
    * REGISTRY_STORAGE_S3_REGION
    * REGISTRY_STORAGE_S3_ACCESSKEY
    * REGISTRY_STORAGE_S3_SECRETKEY
    * REGISTRY_STORAGE_S3_BUCKET
    * REGISTRY_STORAGE_S3_ROOTDIRECTORY
2. Create an `auth/htpassword` file that contains all the users you would like to have access to the registry:

    ```sh
    htpasswwd -bcB auth/htpasswd
    ```

3. Execute the `run.sh` script.
5. Add `kitura-registry.conf` to your apache configuration.
4. Ensure you have an https proxy enabled (such as Cloudflare)


### References

Some useful references

* https://docs.planetary-quantum.com/examples/example-docker-registry-minio/
* https://icicimov.github.io/blog/docker/Docker-Private-Registry-with-S3-backend-on-AWS/
* https://github.com/kwk/docker-registry-frontend
* https://docs.docker.com/registry/storage-drivers/s3/

