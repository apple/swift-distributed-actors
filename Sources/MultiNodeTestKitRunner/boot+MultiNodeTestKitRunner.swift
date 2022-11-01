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
import DistributedCluster
import struct Foundation.Date
import class Foundation.FileHandle
import class Foundation.Process
import struct Foundation.URL
import MultiNodeTestKit
import NIOCore
import NIOPosix
import OrderedCollections

@main
struct MultiNodeTestKitRunnerBoot {
    static func main() async throws {
        try await Self().run()
    }

    struct TestFilter {
        private let matcher: String?

        init(parse arguments: ArraySlice<String>) {
            if let filterIdx = arguments.firstIndex(of: "--filter") {
                let filterValueIdx = arguments.index(after: filterIdx)
                if filterValueIdx >= arguments.endIndex {
                    fatalError("No value for `--filter` given! Arguments: \(arguments)")
                }
                self.matcher = arguments[filterValueIdx]
            } else {
                self.matcher = nil
            }
        }

        public func matches(suiteName: String, testName: String?) -> Bool {
            guard let matcher = self.matcher else {
                return true // always match if no matcher
            }

            if suiteName.contains(matcher) {
                return true
            } else if let testName, testName.contains(matcher) {
                return true
            } else {
                return false
            }
        }
    }

    enum RunResult {
        case signal(Int)
        case exit(Int)
    }

    enum InterpretedRunResult {
        case passedAsExpected
        case crashedAsExpected
        case crashRegexDidNotMatch(regex: String, output: String)
        case unexpectedRunResult(RunResult)
        case outputError(String)

        /// Passed test case, for whatever
        var passed: Bool {
            switch self {
            case .passedAsExpected, .crashedAsExpected:
                return true
            case .crashRegexDidNotMatch, .unexpectedRunResult, .outputError:
                return false
            }
        }

        /// Failed test case, for whatever reason
        var failed: Bool {
            !self.passed
        }
    }

    struct MultiNodeTestNotFound: Error {
        let suite: String
        let test: String
    }

    func allTestsForSuite(_ testSuite: String) -> [(String, MultiNodeTest)] {
        guard let suiteType = MultiNodeTestSuites.first(where: { testSuite == "\($0)" }) else {
            return []
        }

        let suiteInstance = suiteType.init()

        var tests: [(String, MultiNodeTest)] = []
        Mirror(reflecting: suiteInstance)
            .children
            .filter { $0.label?.starts(with: "test") ?? false }
            .forEach { multiNodeTestDescriptor in
                multiNodeTestDescriptor.label.flatMap { label in
                    (multiNodeTestDescriptor.value as? MultiNodeTest).map { multiNodeTest in
                        var multiNodeTest = multiNodeTest
                        multiNodeTest._testSuiteName = testSuite
                        multiNodeTest._testName = label
                        tests.append((label, multiNodeTest))
                    }
                }
            }
        return tests
    }

    func findMultiNodeTest(suite: String, testName: String) -> MultiNodeTest? {
        allTestsForSuite(suite)
            .first(where: { $0.0 == testName })?
            .1
    }

    @MainActor // Main actor only because we want failures to be printed one after another, and not interleaved.
    func interpretNodeTestOutput(
        _ result: Result<ProgramOutput, Error>,
        nodeName: String,
        multiNodeTest: MultiNodeTest,
        expectedFailureRegex: String?,
        grepper: OutputGrepper,
        settings: MultiNodeTestSettings,
        runResult: RunResult
    ) throws -> InterpretedRunResult {
        print()
        print(String(repeating: "-", count: 120))
        print("[multi-node] [\(nodeName)](\(multiNodeTest.fullTestName)) Captured logs:")
        defer {
            print(String(repeating: "=", count: 120))
        }

        let expectedFailure = expectedFailureRegex != nil
        do {
            var detectedReason: InterpretedRunResult?
            if !expectedFailure {
                switch result {
                case .failure(let error as MultiNodeProgramError):
                    var reason: String = "MultiNode test failed, output was dumped."
                    for line in error.completeOutput {
                        log("[\(nodeName)](\(multiNodeTest.testName)) \(line)")

                        if line.contains("Fatal error: "), detectedReason == nil {
                            detectedReason = .outputError(line)
                        } else if case .outputError(let reasonLines) = detectedReason {
                            // keep accumulating lines into the reason, after the "Fatal error:" line.
                            detectedReason = .outputError("\(reasonLines)\n\(line)")
                        }
                    }
                case .success(let result):
                    if settings.dumpNodeLogs == .always {
                        for line in result.logs {
                            log("[\(nodeName)](\(multiNodeTest.testName)) \(line)")
                        }
                    }
                    return .passedAsExpected
                default:
                    break
                }
            }

            if let detectedReason {
                return detectedReason
            }
        }

        guard let expectedFailureRegex = expectedFailureRegex else {
            return .unexpectedRunResult(runResult)
        }

        guard case .signal(Int(SIGILL)) = runResult else {
            return .unexpectedRunResult(runResult)
        }

        let result = try result.get()
        let outputLines = result.logs
        let outputJoined = outputLines.joined(separator: "\n")
        if outputJoined.range(of: expectedFailureRegex, options: .regularExpression) != nil {
            if settings.dumpNodeLogs == .always {
                for line in outputLines {
                    log("[\(nodeName)](\(multiNodeTest.testName)) \(line)")
                }
            }
            return .crashedAsExpected
        } else {
            for line in outputLines {
                log("[\(nodeName)](\(multiNodeTest.testName)) \(line)")
            }
            return .crashRegexDidNotMatch(regex: expectedFailureRegex, output: outputJoined)
        }
    }

    func usage() {
        print("ARGS: \(CommandLine.arguments)")
        print("\(CommandLine.arguments.first ?? "\(Self.self)") COMMAND [OPTIONS]")
        print()
        print("COMMAND is:")
        print("  test                         to run all multi-node tests")
        print("       --filter                to filter which tests should be run; Checks against SUITE and TEST name.")
        print("")
        print("Or an INTERNAL COMMAND:")
        print("For debugging purposes, you can also directly run the test binary directly:")
        print("  \(CommandLine.arguments.first ?? "\(Self.self)") _exec SUITE TEST-NAME NODE-NAME")
    }

    func run() async throws {
        signal(SIGPIPE, SIG_IGN)

        var summary = MultiNodeTestSummary()
        switch CommandLine.arguments.dropFirst().first {
        case .some("test"):
            let filter = TestFilter(parse: CommandLine.arguments.dropFirst())
            defer {
                summary.dump()
            }
            await commandTest(summary: &summary, filter: filter)

        case .some("_exec"):
            if let testSuiteName = CommandLine.arguments.dropFirst(2).first,
               let testName = CommandLine.arguments.dropFirst(3).first,
               let nodeName = CommandLine.arguments.dropFirst(4).first,
               let allNodesString = CommandLine.arguments.dropFirst(5).first,
               let allNodes = Optional(MultiNode.parseAllNodes(allNodesString)),
               let multiNodeTest = findMultiNodeTest(suite: testSuiteName, testName: testName)
            {
                do {
                    try await executeTest(
                        multiNodeTest: multiNodeTest,
                        nodeName: nodeName,
                        allNodes: allNodes
                    )
                } catch {
                    fatalError("Test '\(testSuiteName).\(testName)' execution threw error on node [\(nodeName)], error:\(error)".red)
                }
            } else {
                fatalError("can't find/create test for \(Array(CommandLine.arguments.dropFirst(2)))")
            }

            exit(CInt(0))
        default:
            usage()
            exit(EXIT_FAILURE)
        }

        exit(CInt(summary.failedTests == 0 ? EXIT_SUCCESS : EXIT_FAILURE))
    }

    func makeAllNodesCommandString(nodeNames: OrderedSet<String>, deployNodes: [(String, Int)]) -> String {
        var nodePort = 7301
        return nodeNames.map { nodeName in
            var s = ""
            s += nodeName
            s += "@"
            s += "127.0.0.1" // TODO: take from the deployNodes
            s += ":"
            s += "\(nodePort)"
            nodePort += 1
            return s
        }.joined(separator: ",")
    }
}

enum MultiNode {
    static func parseAllNodes(_ string: String) -> [MultiNode.Endpoint] {
        var nodes: [MultiNode.Endpoint] = []
        let sNodes = string.split(separator: ",")
        nodes.reserveCapacity(sNodes.count)

        func fail() -> Never {
            fatalError("Bad node list syntax: \(string)")
        }
        for sNode in sNodes {
            guard let atIndex = sNode.firstIndex(of: "@") else {
                fail()
            }
            let name = sNode[sNode.startIndex ..< atIndex]

            guard let colonIndex = sNode.firstIndex(of: ":") else {
                fail()
            }
            let host = sNode[sNode.index(after: atIndex) ..< colonIndex]

            guard let colonIndex = sNode.firstIndex(of: ":") else {
                fail()
            }
            guard let port = Int(sNode[sNode.index(after: colonIndex) ..< sNode.endIndex]) else {
                fail()
            }

            let node = MultiNode.Endpoint(
                name: String(name),
                sactHost: String(host),
                sactPort: port,
                deployHost: nil,
                deployPort: nil
            )

            nodes.append(node)
        }
        return nodes

        // FIXME: issue using regex...
        // dyld[44973]: Symbol not found: _$s12RegexBuilder0a9ComponentB0O17buildPartialBlock5first17_StringProcessing0A0Vy0A6OutputQzGx_tAF0aC0RzlFZ
        // Referenced from: <0B3B1546-7B0D-32FE-BC10-3C3A213DC1C5> /Users/ktoso/code/swift-distributed-actors/.build/arm64-apple-macosx/debug/MultiNodeTestKitRunner
        // Expected in:     <9D6DF4BC-5271-331E-A1C6-6DADAC121448> /usr/lib/swift/libswiftRegexBuilder.dylib
//        let nodeSeparator = #/,/#
//        let word = OneOrMore(.word)
//
//        let nodeMatcher = Regex {
//            Capture { // name
//                NegativeLookahead { nodeSeparator }
//                word
//            }
//            "@"
//            Capture { // ip
//                word
//            }
//            ":"
//            TryCapture(OneOrMore(.digit)) { // port
//                Int($0)
//            }
//        }
//
//        var nodes: [MultiNode.Endpoint] = []
//        for nodeString in string.split(separator: ",") {
//            guard let match = nodeString.wholeMatch(of: nodeMatcher) else {
//                fatalError("Bad nodes format: \(string) did not match \(nodeMatcher)")
//            }
//            let name = match.output.1
//            let sactHost = match.output.2
//            let sactPort = match.output.3
//
//            let node = MultiNode.Endpoint(
//                name: String(name),
//                sactHost: String(sactHost),
//                sactPort: sactPort,
//                deployHost: nil,
//                deployPort: nil)
//            nodes.append(node)
//        }
//
//        return nodes
    }

    struct Endpoint {
        let name: String

        let sactHost: String
        let sactPort: Int

        let deployHost: String?
        let deployPort: Int?
    }
}
