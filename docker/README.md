# Docker Containers

These scripts are used to generate Linux containers for [Kitura](https://www.kitura.dev) related [Swift](https://swift.org) build environments.

### Container Tags

These default to Ubuntu 18.04 and Swift 5.3.3 at this time.  This may change in the future without notice.

* *kitura/swift-ci* - Minimal containers intended for Kitura CI builds
* *kitura/swift-dev* - Intended for general Kitura development (contains build and networking tools)

There are also OS-specific versions as well (where X represents the OS version):

* *kitura/centosX-swift-ci*
* *kitura/centosX-swift-dev*
* *kitura/ubuntuX-swift-ci*
* *kitura/ubuntuX-swift-dev*

You can find them on [Docker HUB](https://hub.docker.com/orgs/kitura/repositories).

In general, these are derived from the [Swift docker images](https://hub.docker.com/_/swift) with additional/updated packges.

### Versioning

The *kitura/\*-swift-\** tags are versioned to assume the latest patch of any given release.  For example, specifying `kitura/swift-dev:5` will give you `kitura/swift-dev:5.3.3`, which is the latest Swift 5 version at this time.  If you require a specific version, you should specify the entire version number.  (Note: At this time, not all versions are specified)


### Pushing updated docker images

To update the images on Docker HUB:

```swift
./build.swift -v --enable-centos --enable-build --enable-aliases --enable-push

```

To also update to a private registry:

```swift
./build.swift -v --enable-centos --enable-build --enable-aliases \
   --registry '***registry_url***' \
   --enable-push \
   --registry-password '***password***'

```

Where the registry URL should be of the form:

* `https://private.registry.domain/`
* `https://username@private.registry.domain:CutomPort/`

