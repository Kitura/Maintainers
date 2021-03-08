# Docker Containers

These scripts are used to generate Linux containers for Kitura related swift build environments.

### Container Tags

* *kitura/swift-ci* - Minimal containers intended for Kitura CI builds
* *kitura/swift-dev* - Intended for general Kitura development (contains build and networking tools)

### Versioning

The *kitura/swift-\** tags are versioned to assume the latest patch of any given release.  For example, specifying `kitura/swift-dev:5` will give you `kitura/swift-dev:5.3.3`, which is the latest Swift 5 version at this time.  If you require a specific version, you should specify the entire version number.  (Note: At this time, not all versions are specified)

