# Container registry for Kitura CI

This container registry is primarily used for Kitura CI systems.

This script relies on storing the container images in an S3 compatible storage system.

1. Create a `secrets` file that contains the relevant S3 parameters
2. Create an `auth/htpassword` file that contains all the users you would like to have access to the registry

    ```sh
    htpasswwd -bcB auth/htpasswd
    ```

3. Execute the run.sh script
4. Ensure you have an https proxy enabled (such as Cloudflare)

