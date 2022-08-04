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

import ArgumentParser
import DistributedActors
import struct Foundation.Date
import class Foundation.FileHandle
import class Foundation.Process
import struct Foundation.URL
import MultiNodeTestKit
import NIOCore
import NIOPosix
import OrderedCollections

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Code executing on each specific process/node

extension MultiNodeTestKitRunnerBoot {

    func runMultiNodeTest(_ name: String, suite: String, binary: String) async throws -> InterpretedRunResult {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try! elg.syncShutdownGracefully()
        }

        guard let multiNodeTest = findMultiNodeTest(name, suite: suite) else {
            throw MultiNodeTestNotFound(suite: suite, test: name)
        }

        let devNull = try FileHandle(forUpdating: URL(fileURLWithPath: "/dev/null"))
        defer {
            devNull.closeFile()
        }

        let allNodesCommandString = makeAllNodesCommandString(
            nodeNames: multiNodeTest.nodeNames,
            deployNodes: [])

        let results = try await withThrowingTaskGroup(
            of: InterpretedRunResult.self,
            returning: [InterpretedRunResult].self
        ) { group in
            for nodeName in multiNodeTest.nodeNames {
                group.addTask {
                    let grepper = OutputGrepper.make(group: elg)

                    let processOutputPipe = FileHandle(fileDescriptor: try! grepper.processOutputPipe.takeDescriptorOwnership())
                    let process = Process()
                    process.binaryPath = binary
                    process.standardInput = devNull
                    process.standardOutput = processOutputPipe
                    process.standardError = processOutputPipe // we pipe all output to the same pipe; we don't really care that much

                    process.arguments = ["_exec", suite, name, nodeName, allNodesCommandString]

                    try process.runProcess()
                    print("Execute: \(process.binaryPath!) \(process.arguments?.joined(separator: " ") ?? "") PID: \(process.processIdentifier)")

                    process.waitUntilExit()
                    processOutputPipe.closeFile()
                    let result: Result<ProgramOutput, Error> = Result {
                        try grepper.result.wait()
                    }

                    log("RESULT[\(nodeName)]: \(result)")

                    return try interpretOutput(
                        result,
                        regex: multiNodeTest.crashRegex,
                        runResult: process.terminationReason == .exit ?
                            .exit(Int(process.terminationStatus)) :
                            .signal(Int(process.terminationStatus))
                    )
                }
            }

            var results: [InterpretedRunResult] = []
            results.reserveCapacity(multiNodeTest.nodeNames.count)

            for try await result in group {
                results.append(result)
            }

            return results
        }

        log("RESULTS: \(results)")

        return results.first! // FIXME: return all
    }
}
