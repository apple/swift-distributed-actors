//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Foundation
import Logging
import SwiftSyntax
import SwiftSyntaxParser

final class GenerateActors {
    var log: Logger
    var printGenerated: Bool
    let basePath: Directory

    public init(basePath: Directory, logLevel: Logger.Level = .info, printGenerated: Bool = false) {
        self.basePath = basePath
        self.log = Logger(label: "DistributedActorsGenerator")
        self.log.logLevel = logLevel
        self.printGenerated = printGenerated
    }

    public func run(sourceDirectory: Directory, targetDirectory: Directory, buckets: Int, targets: [String] = []) throws {
        var sourceDirectory = sourceDirectory
        if sourceDirectory.hasSubdirectory(named: "Sources") {
            sourceDirectory = try sourceDirectory.subdirectory(at: "Sources")
        }

        let filteredSourceDirectories = try targets.map { try sourceDirectory.subdirectory(at: $0) }
        let directoriesToScan = !filteredSourceDirectories.isEmpty ? filteredSourceDirectories : [sourceDirectory]

        self.cleanAll(from: targetDirectory)

        let unresolvedActorables = try parseAll(filesToScan: [], directoriesToScan: directoriesToScan)

        // resolves protocol adoption across files; e.g. a protocol defined in another file can be implemented in another
        // TODO: does not work cross module yet (it would break)
        let resolvedActors = ResolveDistributedActors.resolve(unresolvedActorables)

        // prepare buckets
        try (0 ..< buckets).forEach {
            try targetDirectory.createFileIfNeeded(withName: "\(Self.generatedFilePrefix)\($0).swift")
        }

        try generateAll(resolvedActors, in: targetDirectory, buckets: buckets)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Parsing sources

extension GenerateActors {
    private func cleanAll(from directory: Directory) {
        self.log.debug("Cleaning up: \(directory.path)")
        directory.files.forEach { file in
            do {
                try file.delete()
            } catch {
                self.log.warning("Could not delete file: \(file)")
            }
        }
    }

    private func parseAll(filesToScan: [File], directoriesToScan: [Directory]) throws -> [DistributedActorDecl] {
        var unresolvedActorables: [DistributedActorDecl] = []

        try filesToScan.forEach { file in
            let distributedActorsInFile = try self.parse(fileToParse: file)
            unresolvedActorables.append(contentsOf: distributedActorsInFile)
        }

        try directoriesToScan.forEach { directory in
            self.log.debug("Scanning [\(directory.path)] for distributed actors...")
            let actorFilesToScan = directory.files.recursive.filter { f in
                f.extension.lowercased() == "swift"
            }.filter {
                !self.isGeneratedFile(file: $0)
            }

            try actorFilesToScan.forEach { file in
                let distributedActorsInFile = try self.parse(fileToParse: file)
                unresolvedActorables.append(contentsOf: distributedActorsInFile)
            }
        }
        return unresolvedActorables
    }

    func parse(fileToParse: File) throws -> [DistributedActorDecl] {
        self.log.trace("Parsing: \(fileToParse.path)")

        let sourceFile = try SyntaxParser.parse(fileToParse.url)

        let gather = GatherDistributedActors(basePath: self.basePath, path: fileToParse, log: self.log)
        gather.walk(sourceFile)

        // perform a resolve within the file
        let rawActors = gather.actorDecls
        let actors = ResolveDistributedActors.resolve(rawActors)

        return actors
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Generating sources

extension GenerateActors {
    private func generateAll(_ actors: [DistributedActorDecl], in targetDirectory: Directory, buckets: Int) throws {
        try actors.forEach { actor in
            _ = try generateGenActorFile(for: actor, in: targetDirectory, buckets: buckets)
            _ = try generateGenCodableFile(for: actor, in: targetDirectory, buckets: buckets)
        }
    }

    private func generateGenActorFile(for actor: DistributedActorDecl, in targetDirectory: Directory, buckets: Int) throws -> File {
        let targetFile = try self.computeTargetFile(for: actor, in: targetDirectory, buckets: buckets)

        try targetFile.append(Rendering.generatedFileHeader)
        try targetFile.append("\n")

        try actor.imports.forEach { importBlock in
            try targetFile.append("\(importBlock)")
        }

        try targetFile.append("\n")
        let renderedShell = try Rendering.ActorShellTemplate(nominal: actor).render()
        if self.printGenerated {
            print(renderedShell)
        }

        try targetFile.append(renderedShell)

        self.log.debug("Generated: \(targetFile.path)")
        return targetFile
    }

    /// Generate Codable conformances for the `Message` type -- until we don't have auto synthesis of it for enums with associated values.
    private func generateGenCodableFile(for actor: DistributedActorDecl, in targetDirectory: Directory, buckets: Int) throws -> File? {
        guard actor.generateCodableConformance else {
            return nil // skip generating
        }

        let targetFile = try self.computeTargetFile(for: actor, in: targetDirectory, buckets: buckets)

        try targetFile.append(Rendering.generatedFileHeader)
        try targetFile.append("\n")

        try actor.imports.forEach { importBlock in
            try targetFile.append("\(importBlock)")
        }

        try targetFile.append("\n")

        self.log.debug("Generated: \(targetFile.path)")
        return targetFile
    }

    // simple bucketing based on the first letter
    private func computeTargetFile(for actor: DistributedActorDecl, in targetDirectory: Directory, buckets: Int) throws -> File {
        guard buckets > 0 else {
            preconditionFailure("invalid buckets. \(buckets) must be > 0")
        }

        guard let firstLetter = actor.name.lowercased().first else {
            preconditionFailure("invalid actor name: \(actor.name)")
        }

        let letterIndex = Self.letters.firstIndex(of: firstLetter)
            .flatMap { Self.letters.distance(from: Self.letters.startIndex, to: $0) } ?? 0

        let bucket = Int(floor(Double(letterIndex) / ceil(Double(Self.letters.count) / Double(buckets))))
        self.log.debug("Assigning \(actor.name) into bucket #\(bucket)")

        return try targetDirectory.file(named: "\(Self.generatedFilePrefix)\(bucket).swift")
    }

    private func isGeneratedFile(file: File) -> Bool {
        file.name.hasPrefix(Self.generatedFilePrefix)
    }

    private static let generatedFilePrefix = "GeneratedDistributedActors_"
    private static let letters = "abcdefghijklmnopqrstuvwxyz"
}
