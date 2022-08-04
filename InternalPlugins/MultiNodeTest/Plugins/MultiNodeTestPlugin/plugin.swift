//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import PackagePlugin

func log(_ log: String, file: String = #fileID, line: UInt = #line) {
    print("[multi-node] \(log)")
}

@main
struct MultiNodeTestPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        log("Building project...")
        let buildResult = try packageManager.build(
            .all(includingTests: true),
            parameters: .init())

        guard buildResult.succeeded else {
            return
        }

        var multiNodeRunner = buildResult.builtArtifacts
            .filter{ $0.kind == .executable }
            .first { $0.path.lastComponent.starts(with: "MultiNodeTestKitRunner" )}
        guard let multiNodeRunner = multiNodeRunner else {
            throw MultiNodeTestPluginError(message: "Failed")
        }
        
        log("Detected multi-node test runner: \(multiNodeRunner.path.lastComponent)")

        let command = arguments.first ?? "run-all"

        let process = Process()
        process.binaryPath = "/usr/bin/swift"
        process.arguments = ["run", "MultiNodeTestKitRunner", command]

        log("Invoke: swift \(process.arguments?.joined(separator: " ") ?? "")")

        do {
            try process.runProcess()
        log("POrocess: \(process)")
        } catch {
            log("[error] Failed to execute multi-node \(command)! Error: \(error)")
        }
    }
}

// Compatible with Swift on all macOS versions as well as Linux
extension Process {
    var binaryPath: String? {
        get {
            if #available(macOS 10.13, /* Linux */ *) {
                return self.executableURL?.path
            } else {
                return self.launchPath
            }
        }
        set {
            if #available(macOS 10.13, /* Linux */ *) {
                self.executableURL = newValue.map { URL(fileURLWithPath: $0) }
            } else {
                self.launchPath = newValue
            }
        }
    }

    func runProcess() throws {
        if #available(macOS 10.13, *) {
            try self.run()
        } else {
            self.launch()
        }
    }
}

struct MultiNodeTestPluginError: Error {
    let message: String
    let file: String
    let line: UInt

    init(message: String, file: String = #file, line: UInt = #line) {
        self.message = message
        self.file = file
        self.line = line
    }
}
