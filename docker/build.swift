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
            var dockerTargets: [CreateDocker] = []
            
            if ubuntu {
                let buildCI = BuildSwiftCI(swiftVersion: swiftVersion, systemAction: actions)
                dockerTargets.append(buildCI)

                let buildDev = BuildSwiftDev(swiftVersion: swiftVersion, systemAction: actions)
                dockerTargets.append(buildDev)
            }
            
            if centos {
                for centOSVersion in CentOSVersions {
                    let swiftV = try! Version(swiftVersion)
                    guard try! swiftV >= Version(CentOSMinimumSwiftVersion) else {
                        break
                    }
                    let build = BuildCentOSCI(centOSVersion: centOSVersion, swiftVersion: swiftVersion, systemAction: actions)
                    
                    dockerTargets.append(build)
                }
            }

            // Perform Build
            for target in dockerTargets {
//            let build = BuildSwiftCI(swiftVersion: swiftVersion, systemAction: actions)
                actions.section("Preparing targets for \(target.dockerTag)")
                if build {
                    actions.phase("Build docker image")
                    try target.build()
                }

                if aliases {
                    if let aliases = SwiftAliases[swiftVersion] {
                        actions.phase("Create public aliases")
                        for aliasVersion in aliases {
                            try target.alias(version: swiftVersion, alias: aliasVersion)
                        }
                    }
                }

                if push {
                    actions.phase("Push docker image to public registry")
                    try target.push()

                    if let aliases = SwiftAliases[swiftVersion] {
                        for aliasVersion in aliases {
                            try target.push(version: swiftVersion, alias: aliasVersion)
                        }
                    }

                }
                
                
                // Support pushing to private registry
                if let registryUrl = registryUrl {
                    let host = registryUrl.host!
                    
                    if let user = registryUrl.user,
                       let password = registryPasswordFromStdin ?? registryPasswordFromArg ?? registryUrl.password {

                        // TODO: Support --password-stdin
                        print("Attempt to log in: \(user)  pass: \(password)")
                        try actions.runAndPrint(command: "docker", "login", host, "-u", user, "-p", password)
                    }

                    actions.phase("Push docker image to private registry")

                    try actions.runAndPrint(command: "docker", "tag", target.dockerTag, "\(host)/\(target.dockerTag)")
                    
                    try target.push(host: host)

                }
            }
        }
    }

}

BuildCommand.main()

// MARK: CreateDocker

/// Abstract protocol for creating docker images
protocol CreateDocker {
    var systemAction: SystemAction { get set }
    var swiftVersion: String { get }
    var dockerTag: String { get }

    func create(file: URL) throws
//    func build() throws
//    func push() throws
//    func push(host: String) throws
//    func alias(version: String, alias: String) throws
//    func alias(host: String, version: String, alias: String) throws
//    func push(version: String, alias: String) throws
//    func push(host: String, version: String, alias: String) throws
}

extension CreateDocker {
    func build() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        try self.systemAction.createDirectory(url: tmpDir)
        
        let dockerFileUrl = tmpDir.appendingPathComponent("Dockerfile")
        
        try self.create(file: dockerFileUrl)
        
        try self.systemAction.runAndPrint(path: tmpDir.path, command: "docker", "build", "-t", self.dockerTag, tmpDir.path)
    }
    
    func push() throws {
        try self._push()
    }
    
    func push(host: String) throws {
        try self._push(host: host)
    }
    
    private func _push(host: String? = nil) throws {
        let tag: String
        if let host = host {
            tag = "\(host)/\(self.dockerTag)"
        } else {
            tag = self.dockerTag
        }
        try self.systemAction.runAndPrint(command: "docker", "push", tag)
    }
    func alias(version: String, alias: String) throws {
        try self._alias(version: version, alias: alias)
    }
    
    func alias(host: String, version: String, alias: String) throws {
        try self._alias(host: host, version: version, alias: alias)
    }
    
    private func _aliasName(host: String? = nil, version: String, alias: String) -> (String, String) {
        let existingTag: String
        let aliasTag: String
        
        let dockerBaseTag = self.dockerTag.components(separatedBy: ":")[0]
        
        if let host = host {
            existingTag = "\(host)/\(dockerBaseTag):\(version)"
            aliasTag = "\(host)/\(dockerBaseTag):\(alias)"
        } else {
            existingTag = "\(dockerBaseTag):\(version)"
            aliasTag = "\(dockerBaseTag):\(alias)"
        }

        return (existingTag, aliasTag)
    }
    
    private func _alias(host: String? = nil, version: String, alias: String) throws {
        
        let (existingTag, aliasTag) = _aliasName(host: host, version: version, alias: alias)
        
        try self.systemAction.runAndPrint(command: "docker", "tag", existingTag, aliasTag)

    }

    public func push(host: String? = nil, version: String, alias: String) throws {
        
        let (existingTag, aliasTag) = _aliasName(host: host, version: version, alias: alias)
        
        try self.systemAction.runAndPrint(command: "docker", "push", aliasTag)
    }
}

// MARK: - Build Swift CI

// MARK: Ubuntu

/// Create Ubuntu based docker image suitable for CI builds.
/// This is intended to be the minimum necessary to build Kitura projects for CI.
class BuildSwiftCI: CreateDocker {
    let swiftVersion: String
    let dockerTag: String
    var systemAction: SystemAction
    
    init(swiftVersion: String, systemAction: SystemAction = RealAction()) {
        self.swiftVersion = swiftVersion
        self.dockerTag = "kitura/swift-ci:\(swiftVersion)"
        self.systemAction = systemAction
    }
    
    func create(file: URL) throws {
        try self.systemAction.createFile(fileUrl: file) {
            """
            FROM swift:\(self.swiftVersion)
            
            RUN apt-get update && apt-get install -y \\
                git sudo wget pkg-config libcurl4-openssl-dev libssl-dev \\
                && rm -rf /var/lib/apt/lists/*
            
            RUN mkdir /project
            
            WORKDIR /project
            """
        }
    }
}

/// Create docker image suitable for local (non-CI) development builds.
/// This is intended to be a build with packages convenient for local development of Kitura projects.
class BuildSwiftDev: CreateDocker {
    let swiftVersion: String
    let dockerTag: String
    var systemAction: SystemAction
    
    init(swiftVersion: String, systemAction: SystemAction = RealAction()) {
        self.swiftVersion = swiftVersion
        self.dockerTag = "kitura/swift-dev:\(swiftVersion)"
        self.systemAction = systemAction
    }
    
    func create(file: URL) throws {
        try self.systemAction.createFile(fileUrl: file) {
            """
            FROM kitura/swift-ci:\(self.swiftVersion)
            
            RUN apt-get update && apt-get install -y \\
                curl net-tools iproute2 netcat \\
                vim \\
                && rm -rf /var/lib/apt/lists/*
            
            WORKDIR /project
            """
        }
    }
}

// MARK: CentOS

/// Create CentOS based docker image suitable for CI
/// This is intended to be the minimum necessary to build Kitura projects for CI.
class BuildCentOSCI: CreateDocker {
    let centOSVersion: String
    let swiftVersion: String
    let dockerTag: String
    var systemAction: SystemAction
    
    init(centOSVersion: String, swiftVersion: String, systemAction: SystemAction = RealAction()) {
        self.centOSVersion = centOSVersion
        self.swiftVersion = swiftVersion
        self.dockerTag = "kitura/centos\(centOSVersion)/swift-ci:\(swiftVersion)"
        self.systemAction = systemAction
    }
    
    func create(file: URL) throws {
        let swiftUrl = URL(string: "https://swift.org/builds/swift-\(swiftVersion)-release/centos\(centOSVersion)/swift-\(swiftVersion)-RELEASE/swift-\(swiftVersion)-RELEASE-centos\(centOSVersion).tar.gz")!
        let swiftTgzFilename = swiftUrl.lastPathComponent
        let swiftDirname = swiftTgzFilename.components(separatedBy: ".")[0]
        
        try self.systemAction.createFile(fileUrl: file) {
            """
            FROM swift:\(swiftVersion)-centos\(centOSVersion)
            
            RUN yum -y install deltarpm || yum -y update && yum -y install \\
                git sudo wget pkgconfig libcurl-devel openssl-devel \\
                python2-libs \\
                && yum clean all
                        
            RUN mkdir /project

            WORKDIR /project
            """
        }
    }
}

/// Create CentOS based docker image suitable for development
/// This is intended to be a build with packages convenient for local development of Kitura projects.
class BuildCentOSDev: CreateDocker {
    let centOSVersion: String
    let swiftVersion: String
    let dockerTag: String
    var systemAction: SystemAction
    
    init(centOSVersion: String, swiftVersion: String, systemAction: SystemAction = RealAction()) {
        self.centOSVersion = centOSVersion
        self.swiftVersion = swiftVersion
        self.dockerTag = "kitura/centos\(centOSVersion)/swift-dev:\(swiftVersion)"
        self.systemAction = systemAction
    }
    
    func create(file: URL) throws {
        let swiftUrl = URL(string: "https://swift.org/builds/swift-\(swiftVersion)-release/centos\(centOSVersion)/swift-\(swiftVersion)-RELEASE/swift-\(swiftVersion)-RELEASE-centos\(centOSVersion).tar.gz")!
        let swiftTgzFilename = swiftUrl.lastPathComponent
        let swiftDirname = swiftTgzFilename.components(separatedBy: ".")[0]
        
        try self.systemAction.createFile(fileUrl: file) {
            """
            FROM kitura/centos\(centOSVersion)/swift-dev:\(swiftVersion)
            
            RUN yum -y update && yum -y install \\
                net-tools iproute nmap \\
                vim-enhanced \\
                && yum clean all
                        
            RUN mkdir /project
            
            WORKDIR /project
            """
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

// MARK: Version Extensions
extension Version {
    var majorMinorString: String {
        return "\(self.major).\(self.minor)"
    }
    var majorString: String {
        return "\(self.major)"
    }
}
