#!/usr/bin/swift sh
import Version          // @mrackwitz
import Foundation
import ArgumentParser   // https://github.com/apple/swift-argument-parser.git
import SwiftShell       // @kareman
import Rainbow          // @onevcat

let SwiftVersions = ["5.0.3", "5.1.5", "5.2.5", "5.3.3"]

struct BuildCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "build",
        abstract: "A utility to initialize Docker images used by the Kitura project")

    @Flag(name: .shortAndLong, help: "Enable verbose mode")
    var verbose: Bool = false
        
    @Flag(name: [.customLong("enable-build")], help: "Build docker images")
    var enableBuild: Bool = false
    
    @Flag(name: [.customLong("enable-push")], help: "Push docker images")
    var enablePush: Bool = false

    mutating func run() throws {
        print("verbose: \(verbose)")
        print("enableBuild: \(enableBuild)")
        print("enablePush: \(enablePush)")
        let actions = CompositeAction([PrintAction()])

        for swiftVersion in SwiftVersions {
            let version = try! Version(swiftVersion)
            
            print("Found version: \(version)")
            
            let build = BuildSwiftCI(swiftVersion: swiftVersion, systemAction: actions)
            if enableBuild {
                try build.build()
            }
            
            if enablePush {
                try build.push()
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
    func build() throws
    func push() throws
}

extension CreateDocker {
    func build() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        try self.systemAction.createDirectory(url: tmpDir)
        
        let dockerFileUrl = tmpDir.appendingPathComponent("Docker")
        
        try self.create(file: dockerFileUrl)
        
        try self.systemAction.runAndPrint(path: tmpDir.path, command: "docker", "build", "-t", self.dockerTag, tmpDir.path)
    }
    
    func push() throws {
        try self.systemAction.runAndPrint(command: "docker", "push", self.dockerTag)
    }
}

// MARK: Build Swift CI

/// Create docker image suitable for CI builds
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
            
            RUN apt-get update && apt-get install -y \
            git sudo wget pkg-config libcurl4-openssl-dev libssl-dev \
            && rm -rf /var/lib/apt/lists/*
            
            RUN mkdir /project
            
            WORKDIR /project
            """
        }
    }
}

/// Create docker image suitable for local (non-CI) development builds
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
            
            RUN apt-get update && apt-get install -y \
            curl net-tools iproute2 netcat \
            && rm -rf /var/lib/apt/lists/*
            
            WORKDIR /project
            """
        }
    }
}


// MARK: SystemAction
/// A protocol for high level operations we may perform on the system.
/// The intent of this protocol is to make it easier to perform "dry-run" operations.
protocol SystemAction {
    func createDirectory(url: URL) throws
    func createFile(fileUrl: URL, content: String) throws
    func runAndPrint(path: String?, command: [String]) throws
}

extension SystemAction {
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

    func runAndPrint(path: String?=nil, command: String...) throws {
        try self.runAndPrint(path: path, command: command)
    }
}

/// Actually perform the function
class RealAction: SystemAction {
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
        try context.runAndPrint("echo", command)
    }
}

/// Only print the actions
class PrintAction: SystemAction {
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


// MARK: Utility Functions

///// Create a file at a given path.
/////
///// This will overwrite existing files.
///// - Parameters:
/////   - file: fileURL to create
/////   - content: Content of file
///// - Throws: any problems in creating file.
//func createFile(file: URL, content: String) throws {
//    let fm = FileManager.default
//    try? fm.removeItem(at: file)
//    try content.write(to: file, atomically: false, encoding: .utf8)
//}
//
///// Create a file at a given path.
/////
///// This will overwrite existing files.
///// - Parameters:
/////   - file: fileURL to create
/////   - contentBuilder: A closure that returns the content to write into the file.
///// - Throws: any problems in creating file.
//func createFile(file: URL, _ contentBuilder: ()->String) throws {
//    let content = contentBuilder()
//    try createFile(file: file, content: content)
//}

// MARK: Version Extensions
extension Version {
    var majorMinorString: String {
        return "\(self.major).\(self.minor)"
    }
    var majorString: String {
        return "\(self.major)"
    }
}
