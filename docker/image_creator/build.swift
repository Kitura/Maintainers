#!/usr/bin/swift sh
//  Created by Danny Sung on 2021-03-14
//
// 	Licensed under the Apache License, Version 2.0 (the "License");
// 	you may not use this file except in compliance with the License.
// 	You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// 	Unless required by applicable law or agreed to in writing, software
// 	distributed under the License is distributed on an "AS IS" BASIS,
// 	WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// 	See the License for the specific language governing permissions and
// 	limitations under the License.
//

import Version              // @mrackwitz
import Foundation
import ArgumentParser       // https://github.com/apple/swift-argument-parser.git
import SwiftShell           // @kareman
import Rainbow              // @onevcat
import SwiftShellUtilities  // @Kitura

let SwiftVersions = ["5.1.5", "5.2.5", "5.3.3", "5.4.1", "5.5.2" ]

/// Given a target swift version, what aliases should exist?
let SwiftAliases = [
    "5.5.2" : [ "5.5", "5", "latest" ],
    "5.4.1" : [ "5.4" ],
    "5.3.3" : [ "5.3" ],
    "5.2.5" : [ "5.2" ],
    "5.1.5" : [ "5.1" ],
    ]

/// Ubuntu Versions to build
let UbuntuVersions = [ "16.04", "18.04", "20.04" ] // first in this list will be the "default"

/// CentOS Versions to build
let CentosVersions = [ "8", "7" ]
let CentosMinimumSwiftVersion = "5.2.5"
let ContainerCommand = "podman"

struct BuildCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "build",
        abstract: "A utility to initialize Docker images used by the Kitura project")

    @Flag(name: .shortAndLong, help: "Enable verbose mode")
    var verbose: Bool = false

    @Flag(inversion: .prefixedEnableDisable, help: "Build docker images")
    var build: Bool = false

    @Flag(inversion: .prefixedEnableDisable, help: "Push docker images to registry")
    var push: Bool = false

    @Flag(inversion: .prefixedEnableDisable, help: "Push docker images to public registry")
    var pushPublic: Bool = false

    @Flag(inversion: .prefixedEnableDisable, help: "Push docker images to private registry")
    var pushPrivate: Bool = false

    @Flag(inversion: .prefixedEnableDisable, help: "Tag and push convenience aliases")
    var aliases: Bool = false

    @Flag(inversion: .prefixedEnableDisable, help: "Build Ubuntu images (required for CI)")
    var ubuntu: Bool = true

    @Flag(inversion: .prefixedEnableDisable, help: "Build CentOS images")
    var centos: Bool = false

    @Flag(name: [.customLong("dry-run"), .customShort("n")], help: "Dry-run (print but do not execute commands)")
    var enableDryRun: Bool = false

    @Option(name: [.customLong("registry")], help: "Specify a private registry (https://[user[:password]@]registry.url)")
    var registryUrlString: String?
    var registryUrl: URL?

    @Option(name: [.customLong("push-delay")], help: "Seconds before push")
    var pushDelay: TimeInterval = 3

    @Option(name: [.customLong("registry-password")], help: "Registry password")
    var registryPasswordFromArg: String?

    @Flag(name: [.customLong("registry-password-stdin")], help: "Read registry password from stdin")
    var enableReadRegistryPasswordFromStdin: Bool = false

    mutating func run() throws {
        var registryPasswordFromStdin: String? = nil
        var targetsToBuild: [DockerCreator] = []
        var targetsToAlias: [DockerAlias] = []
        var targetsToAliasFromSource: [DockerAlias] = []

        if let urlString = self.registryUrlString {
            self.registryUrl = URL(string: urlString)
        }
        
        if enableReadRegistryPasswordFromStdin {
            print("Enter registry password: ")
            let input = SwiftShell.main.stdin.lines()
            registryPasswordFromStdin = input.first(where: { _ in
                    return true
            })
        }
        
        let actions: SystemAction
        
        if enableDryRun {
            actions = SystemActionComposite([SystemActionPrint()])
            pushDelay = 0
        } else if verbose {
            actions = SystemActionComposite([SystemActionPrint(), SystemActionReal()])
        } else {
            actions = SystemActionComposite([SystemActionReal()])
        }
        

        for swiftVersion in SwiftVersions {
            // Determine targets to build
            
            if ubuntu {
                for osVersion in UbuntuVersions {
                    if try! Version(osVersion) >= Version("20.04") && Version(swiftVersion) <= Version("5.2") {
                        // Need a smarter way to do this, but for now just explicitly skip old Swift versions
                        continue
                    }

                    let buildCI = DockerCreator.ubuntuCI(osVersion: osVersion, swiftVersion: swiftVersion, systemAction: actions)
                    targetsToBuild.append(buildCI)

                    let buildDev = DockerCreator.ubuntuDev(osVersion: osVersion, swiftVersion: swiftVersion, systemAction: actions)
                    targetsToBuild.append(buildDev)
                    
                    
                    // Setup "default" refs that do not have the OS label attached
                    if osVersion == UbuntuVersions.first {
                        // Need to save them in defaultTargets[] because they don't exist until after the build phase
                        let defaultCIRef = DockerImageRef(name: "kitura/swift-ci", tag: swiftVersion)
                        let defaultDevRef = DockerImageRef(name: "kitura/swift-dev", tag: swiftVersion)

                        targetsToAliasFromSource.append(.init(dockerCreator: buildCI, targetRef: defaultCIRef))
                        targetsToAliasFromSource.append(.init(dockerCreator: buildDev, targetRef: defaultDevRef))
                        
                    }
                }
            }
            
            if centos {
                for osVersion in CentosVersions {
                    guard try! Version(swiftVersion) >= Version(CentosMinimumSwiftVersion) else {
                        break
                    }
                    targetsToBuild.append(contentsOf: [
                        DockerCreator.centosCI(centosVersion: osVersion, swiftVersion: swiftVersion, systemAction: actions),
                        DockerCreator.centosDev(centosVersion: osVersion, swiftVersion: swiftVersion, systemAction: actions),
                    ])
                }
            }
                            
        }
        
        if build {
            actions.section("Build docker image for public registry")
            for target in targetsToBuild {
                actions.phase("Preparing targets for \(target.dockerRef)")

                try target.build()
            }
        }

        /// Create version aliases for currently defined aliases and targets
        let targetsPublic = targetsToBuild + targetsToAliasFromSource.map { $0.dockerCreator } + targetsToAlias.map { $0.targetCreator }
        targetsToAlias = targetsPublic.swiftVersionAliases()

        if aliases {
            actions.section("Create public aliases")

            try targetsToAlias.tag()
        }
        
        if push || pushPublic {
            actions.section("Push docker image to public registry")
            
            try targetsPublic.push(delay: pushDelay)
            try targetsToAlias.push(delay: pushDelay)
        }
        
        // Support pushing to private registry
        if let registryUrl = registryUrl,
           let host = registryUrl.host
        {
            let port = registryUrl.port
            let targetsPrivateAliases = targetsToAlias.map { $0.dockerCreator }.aliasesForRegistry(url: registryUrl)
            let targetsPrivate = targetsPrivateAliases.map { $0.dockerCreator.with(ref: $0.targetRef) }
            let privateTargetsToAlias = targetsPrivate.swiftVersionAliases()
 
            if let user = registryUrl.user,
               let password = registryPasswordFromStdin ?? registryPasswordFromArg ?? registryUrl.password {
                
                actions.phase("Login to private docker registry")

                try actions.runAndPrint(command: ContainerCommand, "login", host, "-u", user, "-p", password)
            }
            
            if aliases {
                actions.section("Create private aliases")
                try targetsPrivateAliases.tag()
                
                actions.section("Create private aliases for swift versions")
                try privateTargetsToAlias.tag()
            }
            
            if push || pushPrivate {
                actions.section("Push docker images to private registry")
                try targetsPrivate.push(delay: pushDelay)
                
                actions.section("Push docker images for swift versions to private registry")
                try privateTargetsToAlias.push(delay: pushDelay)
            }
        }
    
    }
    
}

BuildCommand.main()


// MARK: - DockerCreator

/// Helper manage docker container variants
struct DockerCreator {
    let os: String
    let osVersion: String
    let systemAction: SystemAction
    let dockerRef: DockerImageRef
    let dockerFile: String
    
    public func with(ref newDockerRef: DockerImageRef) -> DockerCreator {
        return DockerCreator(os: self.os,
                             osVersion: self.osVersion,
                             systemAction: self.systemAction,
                             dockerRef: newDockerRef,
                             dockerFile: self.dockerFile)
    }
    
    private func create(file: URL) throws {
        try self.systemAction.createFile(fileUrl: file) {
            return self.dockerFile
        }
    }
    
    /// Build the docker
    ///
    /// Perform a `docker build`
    /// - Throws: Any errors running `docker tag` or creating the `Dockerfile`
    func build() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        
        try self.systemAction.createDirectory(url: tmpDir)
        
        let dockerFileUrl = tmpDir.appendingPathComponent("Dockerfile")
        
        try self.systemAction.createFile(fileUrl: dockerFileUrl) {
            self.dockerFile
        }

        try self.systemAction.runAndPrint(workingDir: tmpDir.path, command: ContainerCommand, "build", "-t", "\(self.dockerRef)", tmpDir.path)
    }
    
    /// Tag with a new name entirely.
    ///
    /// Perform a `docker tag`
    /// - Parameter newDockerRef: New docker ref to tag with
    /// - Throws: Any errors running `docker tag`
    /// - Returns: `DockerCreator` with the new `DockerImageRef`
    @discardableResult
    func tag(ref newDockerRef: DockerImageRef) throws -> DockerCreator {
        let existingRef = self.dockerRef
        
        try self.systemAction.runAndPrint(command: ContainerCommand, "tag", "\(existingRef)", "\(newDockerRef)")
        
        return self.with(ref: newDockerRef)
    }
    
    /// Push to registry.
    ///
    /// Perform a `docker push`
    /// - Throws: Errors from executing `docker push`
    func push(delay: TimeInterval) throws {
        sleep(UInt32(delay))
        try self.systemAction.runAndPrint(command: ContainerCommand, "push", "\(self.dockerRef)")
    }
    
    /// Remove the docker image
    ///
    /// Perform a `docker rmi`
    func clean() {
        try? self.systemAction.runAndPrint(command: ContainerCommand, "rmi", "\(self.dockerRef)")
    }
}

// MARK: Docker Alias
struct DockerAlias {
    let dockerCreator: DockerCreator
    let targetRef: DockerImageRef
    
    init(dockerCreator: DockerCreator, targetRef: DockerImageRef) {
        self.dockerCreator = dockerCreator
        self.targetRef = targetRef
    }
    
    var targetCreator: DockerCreator {
        return self.dockerCreator.with(ref: self.targetRef)
    }
    
    /// Create the alias
    /// - Throws: Any errors from `docker tag`
    func tag() throws {
        try self.dockerCreator.tag(ref: self.targetRef)
    }
    
    /// Push the alias to the registry
    /// - Throws: Any errors from `docker push`
    func push(delay: TimeInterval) throws {
        try self.targetCreator.push(delay: delay)
    }
    
    /// Remove the aliased image.
    func clean() {
        self.targetCreator.clean()
    }
}

extension Array where Element == DockerAlias {
    
    /// An array of `DockerCreator` with the target `DockerImageRef`
    var targetCreators: [DockerCreator] {
        return self.map { $0.targetCreator }
    }
    
    /// Create all aliases
    /// - Throws: Any errors from `docker tag`
    func tag() throws {
        for alias in self {
            try alias.tag()
        }
    }
    
    /// Push all aliases to the registry
    /// - Throws: Any errors from `docker push`
    func push(delay: TimeInterval) throws {
        for alias in self {
            try alias.push(delay: delay)
        }
    }
    
    /// Clean all aliases
    func clean() {
        for alias in self {
            alias.clean()
        }
    }
}


// MARK: DockerCreator Alias Helpers

extension DockerCreator {
    /// Create Swift Version aliases for a given target
    /// - Parameter target: DockerCreator (should have a full version number)
    /// - Returns: New aliases
    func createSwiftVersionAliases() -> [DockerAlias] {
        let source = self
        var aliases: [DockerAlias] = []
        let currentSwiftVersion = source.dockerRef.tag
        let swiftAliases = SwiftAliases[currentSwiftVersion] ?? []
        
        for swiftVersion in swiftAliases {
            let targetRef = source.dockerRef.with(tag: swiftVersion)
            aliases.append(.init(dockerCreator: source, targetRef: targetRef))
        }
        return aliases
    }
    

}

// MARK: - Misc Helper Functions

/// Determine if the given swift version is the "latest".
///
/// The latest is determined by whether the alias contains the "latest" keyword
/// - Parameter swiftVersion: Swift Version to check
/// - Returns: true if it is "latest"
func swiftVersionIsLatest(_ swiftVersion: String) -> Bool {
    guard let aliases = SwiftAliases[swiftVersion] else {
        return false
    }
    return aliases.contains("latest")
}


// MARK: - Container descriptions

extension DockerCreator {
    
    // MARK: Ubuntu
    
    private static func ubuntuOSName(version: String) -> String? {
        switch version {
        case "20.04": return "focal"
        case "18.04": return "bionic"
        case "16.04": return "xenial"
        default:
            return nil
        }
    }
    
    /// Create Ubuntu based docker image suitable for CI builds.
    /// This is intended to be the minimum necessary to build Kitura projects for CI.
    static func ubuntuCI(osVersion: String, swiftVersion: String, systemAction: SystemAction) -> DockerCreator {
        let ubuntuOSName = self.ubuntuOSName(version: osVersion)!
        
        let dockerRef = DockerImageRef(name: "kitura/swift-ci-ubuntu\(osVersion)", tag: swiftVersion)
        let dockerFile = """
            FROM swift:\(swiftVersion)-\(ubuntuOSName)
            
            RUN apt-get update && apt-get install -y \\
                git sudo wget pkg-config libcurl4-openssl-dev libssl-dev \\
                && rm -rf /var/lib/apt/lists/*

            RUN git clone https://github.com/mxcl/swift-sh.git && \
                (cd swift-sh && swift build -c release) && \
                cp swift-sh/.build/release/swift-sh /usr/local/bin/swift-sh && \
                rm -rf swift-sh
            
            RUN mkdir /project
            
            WORKDIR /project
            """
        
        return DockerCreator(os: "ubuntu", osVersion: osVersion, systemAction: systemAction, dockerRef: dockerRef, dockerFile: dockerFile)
    }
    
    /// Create docker image suitable for local (non-CI) development builds.
    /// This is intended to be a build with packages convenient for local development of Kitura projects.
    static func ubuntuDev(osVersion: String, swiftVersion: String, systemAction: SystemAction) -> DockerCreator {
        let dockerRef = DockerImageRef(name: "kitura/swift-dev-ubuntu\(osVersion)", tag: swiftVersion)
        let dockerFile = """
            FROM kitura/swift-ci-ubuntu\(osVersion):\(swiftVersion)
            
            RUN apt-get update && apt-get install -y \\
                curl net-tools iproute2 netcat \\
                vim \\
                && rm -rf /var/lib/apt/lists/*
            
            WORKDIR /project
            """
        
        return DockerCreator(os: "ubuntu", osVersion: osVersion, systemAction: systemAction, dockerRef: dockerRef, dockerFile: dockerFile)
    }
    
    // MARK: CentOS
    
    /// Create CentOS based docker image suitable for CI
    /// This is intended to be the minimum necessary to build Kitura projects for CI.

    static func centosCI(centosVersion: String, swiftVersion: String, systemAction: SystemAction) -> DockerCreator {
        let dockerRef = DockerImageRef(name: "kitura/swift-ci-centos\(centosVersion)", tag: swiftVersion)
//        let swiftUrl = URL(string: "https://swift.org/builds/swift-\(swiftVersion)-release/centos\(centosVersion)/swift-\(swiftVersion)-RELEASE/swift-\(swiftVersion)-RELEASE-centos\(centosVersion).tar.gz")!
//        let swiftTgzFilename = swiftUrl.lastPathComponent
//        let swiftDirname = swiftTgzFilename.components(separatedBy: ".")[0]

        let dockerFile = """
            FROM swift:\(swiftVersion)-centos\(centosVersion)
                
                RUN yum -y install deltarpm || yum -y update && yum -y install \\
                    git sudo wget pkgconfig libcurl-devel openssl-devel \\
                    python2-libs \\
                    && yum clean all

            RUN git clone https://github.com/mxcl/swift-sh.git && \
                (cd swift-sh && swift build -c release) && \
                cp swift-sh/.build/release/swift-sh /usr/local/bin/swift-sh && \
                rm -rf swift-sh
            
                RUN mkdir /project
            
                WORKDIR /project
            """

        return DockerCreator(os: "centos", osVersion: centosVersion, systemAction: systemAction, dockerRef: dockerRef, dockerFile: dockerFile)
    }
    
    /// Create CentOS based docker image suitable for development
    /// This is intended to be a build with packages convenient for local development of Kitura projects.
    static func centosDev(centosVersion: String, swiftVersion: String, systemAction: SystemAction) -> DockerCreator {
        let dockerRef = DockerImageRef(name: "kitura/swift-dev-centos\(centosVersion)", tag: swiftVersion)

        let dockerFile = """
            FROM kitura/swift-ci-centos\(centosVersion):\(swiftVersion)
            
            RUN yum -y update && yum -y install \\
                net-tools iproute nmap \\
                vim-enhanced \\
                && yum clean all
            
            WORKDIR /project
            """
        
        return DockerCreator(os: "centos", osVersion: centosVersion, systemAction: systemAction, dockerRef: dockerRef, dockerFile: dockerFile)
    }
}


extension Array where Element == DockerCreator {
    /// Convenience method to  apply push() to an array of `DockerCreator`s
    /// - Throws: Any errors on `docker push`
    func push(delay: TimeInterval) throws {
        for dockerCreator in self {
            try dockerCreator.push(delay: delay)
        }
    }
    
    /// Create SwiftVersion aliases for each DockerCreator
    /// - Returns: All aliases
    func swiftVersionAliases() -> [DockerAlias] {
        return self.flatMap { $0.createSwiftVersionAliases() }
    }
    
    /// Create aliases for a private registry
    /// - Parameter url: URL must contain a valid hostname and an option port
    /// - Returns: an empty array of `url` is invalid.  Otherwise a list of alises
    func aliasesForRegistry(url: URL?) -> [DockerAlias] {
        guard let url = url else { return [] }
        let hostname = url.host!
        let port = url.port
        var aliases: [DockerAlias] = []
        
        for target in self {
            let newDockerRef = target.dockerRef.with(hostname: hostname, port: port)
            let alias =  DockerAlias(dockerCreator: target, targetRef: newDockerRef)
            
            aliases.append(alias)
        }
        
        return aliases
    }
}


// MARK: Docker Image Ref

public struct DockerImageRef: Hashable {
    public struct HostInfo: Hashable {
        let hostname: String
        let port: Int?
    }
    let host: HostInfo?
    let name: String
    let tag: String
    
    public init(host: HostInfo? = nil, name: String, tag: String = "latest") {
        self.host = host
        self.name = name
        self.tag = tag
    }
    
    /// Duplicate a DockerImageRef and assign a private registry.
    ///
    /// The newly created DockerImageRef will have the same name and tag as the original.
    /// - Parameters:
    ///   - hostname: hostname of private registry
    ///   - port: optional port for private registry
    /// - Returns: new DockerImageRef
    public func with(hostname: String, port: Int?=nil) -> DockerImageRef {
        let hostInfo = HostInfo(hostname: hostname, port: port)
        return DockerImageRef(host: hostInfo, name: self.name, tag: self.tag)
    }
    
    /// Duplicate a DockerImageRef and assign a new tag.
    ///
    /// The newly created DockerImageRef will have the same name and private registery (if one previously specified).
    /// - Parameter tag: Tag to assign to new DockerImageRef
    /// - Returns: new DockerImageRef
    public func with(tag newTag: String) -> DockerImageRef {
        return DockerImageRef(host: self.host, name: self.name, tag: newTag)
    }
}

extension DockerImageRef.HostInfo: CustomStringConvertible {
    public var description: String {
        if let port = port {
            return "\(hostname):\(port)"
        } else {
            return "\(hostname)"
        }
    }
}

extension DockerImageRef: CustomStringConvertible {
    public var description: String {
        if let host = host {
            return "\(host)/\(name):\(tag)"
        } else {
            return "\(name):\(tag)"
        }
    }
}

// MARK: Version Extensions
extension Version {
    var majorMinorString: String {
        return "\(self.major).\(self.minor)"
    }
    var majorString: String {
        return "\(self.major)"
    }
}
