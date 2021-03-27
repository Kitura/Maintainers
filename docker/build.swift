#!/usr/bin/swift sh
import Version          // @mrackwitz
import Foundation
import ArgumentParser   // https://github.com/apple/swift-argument-parser.git
import SwiftShell       // @kareman
import Rainbow          // @onevcat

let SwiftVersions = ["5.0.3", "5.1.5", "5.2.5", "5.3.3"]

/// Given a target swift version, what aliases should exist?
let SwiftAliases = [
    "5.3.3" : [ "5.3", "5", "latest" ],
    "5.2.5" : [ "5.2" ],
    "5.1.5" : [ "5.1" ],
    "5.0.3" : [ "5.0" ]
    ]

/// CentOS Versions to build
let CentOSVersions = [ "8", "7" ]
let CentOSMinimumSwiftVersion = "5.2.5"

struct BuildCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "build",
        abstract: "A utility to initialize Docker images used by the Kitura project")

    @Flag(name: .shortAndLong, help: "Enable verbose mode")
    var verbose: Bool = false
        
    @Flag(inversion: .prefixedEnableDisable, help: "Build docker images")
    var build: Bool = false
    
    @Flag(inversion: .prefixedEnableDisable, help: "Push docker images to public registry")
    var push: Bool = false

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

    @Option(name: [.customLong("registry-password")], help: "Registry password")
    var registryPasswordFromArg: String?

    @Flag(name: [.customLong("registry-password-stdin")], help: "Read registry password from stdin")
    var enableReadRegistryPasswordFromStdin: Bool = false
    
    mutating func run() throws {
        var registryPasswordFromStdin: String? = nil
        
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
            actions = CompositeAction([PrintAction()])
        } else if verbose {
            actions = CompositeAction([PrintAction(), RealAction()])
        } else {
            actions = CompositeAction([RealAction()])
        }
        
        for swiftVersion in SwiftVersions {
            // Determine targets to build
            var dockerTargets: [DockerCreator] = []
            
            if ubuntu {
                let buildCI = DockerCreator.ubuntuCI(osVersion: "", swiftVersion: swiftVersion, systemAction: actions)
                dockerTargets.append(buildCI)

                let buildDev = DockerCreator.ubuntuDev(osVersion: "", swiftVersion: swiftVersion, systemAction: actions)
                dockerTargets.append(buildDev)
            }
            
            if centos {
                for centOSVersion in CentOSVersions {
                    let swiftV = try! Version(swiftVersion)
                    guard try! swiftV >= Version(CentOSMinimumSwiftVersion) else {
                        break
                    }
                    let build = DockerCreator.centosCI(centOSVersion: centOSVersion, swiftVersion: swiftVersion, systemAction: actions)
                    
                    dockerTargets.append(build)
                }
            }

            // Perform Build
            for target in dockerTargets {
                actions.section("Preparing targets for \(target.dockerRef)")
                var aliasesToPush: [DockerCreator] = []
                
                if build {
                    actions.phase("Build docker image")
                    try target.build()
                }

                if aliases {
                    if let swiftAliases = SwiftAliases[swiftVersion] {
                        actions.phase("Create public aliases")
                        let newAliases = try target.aliases(tags: swiftAliases)
                        aliasesToPush.append(contentsOf: newAliases)
                    }
                }

                if push {
                    actions.phase("Push docker image to public registry")
                    try target.push()
                    try aliasesToPush.push()
                }
                
                
                // Support pushing to private registry
                if let registryUrl = registryUrl {
                    let host = registryUrl.host!
                    
                    if let user = registryUrl.user,
                       let password = registryPasswordFromStdin ?? registryPasswordFromArg ?? registryUrl.password {

                        actions.phase("Login to private docker registry")

                        // TODO: Support --password-stdin
                        print("Attempt to log in: \(user)  pass: \(password)")
                        try actions.runAndPrint(command: "docker", "login", host, "-u", user, "-p", password)
                    }

                    actions.phase("Create tag for private registry")
                    let privateTarget = try target.tag(hostname: host, port: registryUrl.port)
                    var aliasesToPush: [DockerCreator] = []

                    if aliases {
                       if let aliases = SwiftAliases[swiftVersion] {
                            actions.phase("Create aliases for private registry")
                            let newAliases = try privateTarget.aliases(tags: aliases)
                            aliasesToPush.append(contentsOf: newAliases)
                       }
                    }

                        
                    if push {
                        actions.phase("Pushing alias to private registry")
                        try aliasesToPush.push()
                    }

                }
            }
        }
    }

}

BuildCommand.main()

/// Abstract protocol for creating docker images
struct DockerCreator {
    let os: String
    let osVersion: String
    let systemAction: SystemAction
    let dockerRef: DockerImageRef
    let dockerFile: String
    
    public func with(tag newTag: String) -> DockerCreator {
        
        let newDockerRef = self.dockerRef.with(tag: newTag)
        
        return self.with(ref: newDockerRef)
    }
    
    public func with(ref newDockerRef: DockerImageRef) -> DockerCreator {
        return DockerCreator(os: self.os,
                             osVersion: self.osVersion,
                             systemAction: self.systemAction,
                             dockerRef: newDockerRef,
                             dockerFile: self.dockerFile)
    }
    
    public func with(hostname: String, port: Int?) -> DockerCreator {
        let newDockerRef = self.dockerRef.with(hostname: hostname, port: port)
        return self.with(ref: newDockerRef)
    }
    
    private func create(file: URL) throws {
        try self.systemAction.createFile(fileUrl: file) {
            return self.dockerFile
        }
    }
    
    func build() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        
        try self.systemAction.createDirectory(url: tmpDir)
        
        let dockerFileUrl = tmpDir.appendingPathComponent("Dockerfile")
        
        try self.systemAction.createFile(fileUrl: dockerFileUrl) {
            self.dockerFile
        }

        try self.systemAction.runAndPrint(path: tmpDir.path, command: "docker", "build", "-t", "\(self.dockerRef)", tmpDir.path)
    }
    
    /// Create an alias of a docker ref with a new tag
    ///
    /// - Parameter tag: New tag to use
    /// - Returns: DockerCreator with the new tag
    @discardableResult
    func alias(tag: String) throws -> DockerCreator {
        let newDockerRef = self.dockerRef.with(tag: tag)
        let existingRef = self.dockerRef.description
        
        try self.systemAction.runAndPrint(command: "docker", "tag", existingRef, newDockerRef.tag)

        return self.with(ref: newDockerRef)
    }
    
    /// Create multiple aliases
    /// - Parameter tags: New tags to create
    /// - Returns: An array of `DockerCreator` containing all tags created
    func aliases(tags: [String]) throws -> [DockerCreator] {
        return try tags.map { try self.alias(tag: $0) }
    }
    
    /// Perform a `docker push`
    /// - Throws: Errors from executing `docker push`
    func push() throws {
        try self.systemAction.runAndPrint(command: "docker", "push", "\(self.dockerRef)")
    }

    
    /// Create a tag for a private Docker registry
    /// - Parameters:
    ///   - hostname: Hostname of the private registry
    ///   - port: Optional port number for the private registry
    /// - Throws: Any errors from `docker tag`
    /// - Returns: new `DockerCreator`
    func tag(hostname: String, port: Int?) throws -> DockerCreator {
        let existingRef = self.dockerRef
        let newDockerCreator = self.with(hostname: hostname, port: port)
        let newRef = newDockerCreator.dockerRef
        
        try self.systemAction.runAndPrint(command: "docker", "tag", "\(existingRef)", "\(newRef)")
        
        return newDockerCreator
    }
}

// MARK: - Build Swift CI

// MARK: Ubuntu

extension DockerCreator {
    
    /// Create Ubuntu based docker image suitable for CI builds.
    /// This is intended to be the minimum necessary to build Kitura projects for CI.
    static func ubuntuCI(osVersion: String, swiftVersion: String, systemAction: SystemAction) -> DockerCreator {
        let dockerRef = DockerImageRef(name: "kitura/swift-ci", tag: swiftVersion)
        let dockerFile = """
            FROM swift:\(swiftVersion)
            
            RUN apt-get update && apt-get install -y \\
                git sudo wget pkg-config libcurl4-openssl-dev libssl-dev \\
                && rm -rf /var/lib/apt/lists/*
            
            RUN mkdir /project
            
            WORKDIR /project
            """
        
        return DockerCreator(os: "ubuntu", osVersion: osVersion, systemAction: systemAction, dockerRef: dockerRef, dockerFile: dockerFile)
    }
    
    /// Create docker image suitable for local (non-CI) development builds.
    /// This is intended to be a build with packages convenient for local development of Kitura projects.
    static func ubuntuDev(osVersion: String, swiftVersion: String, systemAction: SystemAction) -> DockerCreator {
        let dockerRef = DockerImageRef(name: "kitura/swift-dev", tag: swiftVersion)
        let dockerFile = """
            FROM kitura/swift-ci:\(swiftVersion)
            
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

    static func centosCI(centOSVersion: String, swiftVersion: String, systemAction: SystemAction) -> DockerCreator {
        let dockerRef = DockerImageRef(name: "kitura/centos\(centOSVersion)/swift-ci", tag: swiftVersion)
        let swiftUrl = URL(string: "https://swift.org/builds/swift-\(swiftVersion)-release/centos\(centOSVersion)/swift-\(swiftVersion)-RELEASE/swift-\(swiftVersion)-RELEASE-centos\(centOSVersion).tar.gz")!
        let swiftTgzFilename = swiftUrl.lastPathComponent
        let swiftDirname = swiftTgzFilename.components(separatedBy: ".")[0]

        let dockerFile = """
            FROM swift:\(swiftVersion)-centos\(centOSVersion)
                
                RUN yum -y install deltarpm || yum -y update && yum -y install \\
                    git sudo wget pkgconfig libcurl-devel openssl-devel \\
                    python2-libs \\
                    && yum clean all
                            
                RUN mkdir /project
            
                WORKDIR /project
            """

        return DockerCreator(os: "centos", osVersion: centOSVersion, systemAction: systemAction, dockerRef: dockerRef, dockerFile: dockerFile)
    }
    
    /// Create CentOS based docker image suitable for development
    /// This is intended to be a build with packages convenient for local development of Kitura projects.
    static func centosDev(centOSVersion: String, swiftVersion: String, systemAction: SystemAction) -> DockerCreator {
        let dockerRef = DockerImageRef(name: "kitura/centos\(centOSVersion)/swift-dev", tag: swiftVersion)
        let swiftUrl = URL(string: "https://swift.org/builds/swift-\(swiftVersion)-release/centos\(centOSVersion)/swift-\(swiftVersion)-RELEASE/swift-\(swiftVersion)-RELEASE-centos\(centOSVersion).tar.gz")!
        let swiftTgzFilename = swiftUrl.lastPathComponent
        let swiftDirname = swiftTgzFilename.components(separatedBy: ".")[0]
        let dockerFile = """
            FROM kitura/centos\(centOSVersion)/swift-dev:\(swiftVersion)
            
            RUN yum -y update && yum -y install \\
                net-tools iproute nmap \\
                vim-enhanced \\
                && yum clean all
                        
            RUN mkdir /project
            
            WORKDIR /project
            """
        
        return DockerCreator(os: "centos", osVersion: centOSVersion, systemAction: systemAction, dockerRef: dockerRef, dockerFile: dockerFile)
    }
}


extension Array where Element == DockerCreator {
    func push() throws {
        for dockerCreator in self {
            try dockerCreator.push()
        }
    }
}


// MARK: - SystemAction
/// A protocol for high level operations we may perform on the system.
/// The intent of this protocol is to make it easier to perform "dry-run" operations.
enum Heading {
    case section
    case phase
}

protocol SystemAction {
    func heading(_ type: Heading, _ string: String)
    func createDirectory(url: URL) throws
    func createFile(fileUrl: URL, content: String) throws
    func runAndPrint(path: String?, command: [String]) throws
}

extension SystemAction {
    /// Print the title of a section
    /// - Parameter string: title to print
    func section(_ string: String) {
        self.heading(.section, string)
    }
    
    /// Print the title of a phase
    /// - Parameter string: title to print
    func phase(_ string: String) {
        self.heading(.phase, string)
    }
    
    /// Create a file at a given path.
    ///
    /// This will overwrite existing files.
    /// - Parameters:
    ///   - file: fileURL to create
    ///   - contentBuilder: A closure that returns the content to write into the file.
    /// - Throws: any problems in creating file.
    func createFile(fileUrl: URL, _ contentBuilder: ()->String) throws {
        let content = contentBuilder()
        try self.createFile(fileUrl: fileUrl, content: content)
    }
    
    /// Execute the given command and show the results
    /// - Parameters:
    ///   - path: If not-nil, this will be the current working directory when the command is exectued.
    ///   - command: Command to execute
    /// - Throws: any problems in executing the command or if the command has a non-0 return code
    func runAndPrint(path: String?=nil, command: String...) throws {
        try self.runAndPrint(path: path, command: command)
    }
}

/// Actually perform the function
class RealAction: SystemAction {
    func heading(_ type: Heading, _ string: String) {
        // do nothing
    }
    
    func createDirectory(url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }
    
    /// Create a file at a given path.
    ///
    /// This will overwrite existing files.
    /// - Parameters:
    ///   - file: fileURL to create
    ///   - content: Content of file
    /// - Throws: any problems in creating file.
    func createFile(fileUrl: URL, content: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: fileUrl)
        try content.write(to: fileUrl, atomically: false, encoding: .utf8)
    }
    
    func runAndPrint(path: String?, command: [String]) throws {
        var context = CustomContext(main)
        if let path = path {
            context.currentdirectory = path
        }
        let cmd = command.first!
        var args = command
        args.removeFirst()
        try context.runAndPrint(cmd, args)
    }
}

/// Only print the actions
class PrintAction: SystemAction {
    func heading(_ type: Heading, _ string: String) {
        switch type {
        case .section:
            print(" == Section: \(string)".yellow.bold)
        case .phase:
            print(" -- Phase: \(string)".cyan.bold)
        }
    }
    func createDirectory(url: URL) throws {
        print(" > Creating directory at path: \(url.path)".bold)
    }
    
    func createFile(fileUrl: URL, content: String) throws {
        print(" > Creating file at path: \(fileUrl.path)".bold)
        print(content.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n").yellow)
    }
    func runAndPrint(path: String?, command: [String]) throws {
        print(" > Executing command: \(command.joined(separator: " "))".bold)
        if let path = path {
            print("   Working Directory: \(path)".bold)
        }
    }
}

/// Allow actions to be composited and performed one after another.
/// Actions will be performed in the order they are specified in the initializer
class CompositeAction: SystemAction {
    var actions: [SystemAction]
    
    init(_ actions: [SystemAction] = []) {
        self.actions = actions
    }
    
    func heading(_ type: Heading, _ string: String) {
        self.actions.forEach {
            $0.heading(type, string)
        }
    }
    func createDirectory(url: URL) throws {
        try self.actions.forEach {
            try $0.createDirectory(url: url)
        }
    }
    
    func createFile(fileUrl: URL, content: String) throws {
        try self.actions.forEach {
            try $0.createFile(fileUrl: fileUrl, content: content)
        }
    }

    func runAndPrint(path: String?, command: [String]) throws {
        try self.actions.forEach {
            try $0.runAndPrint(path: path, command: command)
        }
    }
}

// MARK: Docker Image Ref

public struct DockerImageRef {
    public struct HostInfo {
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
