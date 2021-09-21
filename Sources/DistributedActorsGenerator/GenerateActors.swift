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
import DistributedActors
import Foundation
import Logging
import SwiftSyntax

final class GenerateActors {
    var log: Logger
    var printGenerated: Bool
    let basePath: Folder

    public init(basePath: Folder, logLevel: Logger.Level = .info, printGenerated: Bool = false) {
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
        let foldersToScan = !filteredSourceDirectories.isEmpty ? filteredSourceDirectories : [sourceDirectory]

        self.cleanAll(from: targetDirectory)

        let unresolvedActorables = try parseAll(filesToScan: [], directoriesToScan: foldersToScan)

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
        self.log.info("Cleaning up \(directory.path)")
        directory.files.forEach { file in
            do {
                try file.delete()
            } catch {
                self.log.warning("Could not delete file: \(file)")
            }
        }
    }

    private func parseAll(filesToScan: [File], directoriesToScan: [Directory]) throws -> [ActorableTypeDecl] {
        var unresolvedActorables: [ActorableTypeDecl] = []

        try filesToScan.forEach { file in
            let actorablesInFile = try self.parse(fileToParse: file)
            unresolvedActorables.append(contentsOf: actorablesInFile)
        }

        try directoriesToScan.forEach { directory in
            self.log.debug("Scanning [\(directory.path)] for actorables...")
            let actorFilesToScan = directory.files.recursive.filter { f in
                f.extension.lowercased() == "swift"
            }.filter {
                !self.isGeneratedFile(file: $0)
            }

            try actorFilesToScan.forEach { file in
                let actorablesInFile = try self.parse(fileToParse: file)
                unresolvedActorables.append(contentsOf: actorablesInFile)
            }
        }
        return unresolvedActorables
    }

    func parse(fileToParse: File) throws -> [ActorTypeDecl] {
        self.log.debug("Parsing: \(fileToParse.path)")

        let sourceFile = try SyntaxParser.parse(fileToParse.url)

        let gather = GatherDistributedActors(fileToParse, self.log.logLevel)
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
    private func generateAll(_ actorables: [ActorableTypeDecl], in targetDirectory: Directory, buckets: Int) throws {
        try actorables.forEach { actorable in
            _ = try generateGenActorFile(for: actorable, in: targetDirectory, buckets: buckets)
            _ = try generateGenCodableFile(for: actorable, in: targetDirectory, buckets: buckets)
        }
    }

    private func generateGenActorFile(for actorable: ActorTypeDecl, in targetDirectory: Directory, buckets: Int) throws -> File {
        let targetFile = try self.computeTargetFile(for: actorable, in: targetDirectory, buckets: buckets)

        try targetFile.append(Rendering.generatedFileHeader)
        try targetFile.append("\n")

        try actorable.imports.forEach { importBlock in
            try targetFile.append("\(importBlock)")
        }

        try targetFile.append("\n")
        let renderedShell = try Rendering.ActorShellTemplate(actorable: actorable).render()
        if self.printGenerated {
            print(renderedShell)
        }

        try targetFile.append(renderedShell)

        self.log.debug("Generated: \(targetFile.path)")
        return targetFile
    }

    /// Generate Codable conformances for the `Message` type -- until we don't have auto synthesis of it for enums with associated values.
    private func generateGenCodableFile(for actorable: ActorableTypeDecl, in targetDirectory: Directory, buckets: Int) throws -> File? {
        guard actorable.generateCodableConformance else {
            return nil // skip generating
        }

        let targetFile = try self.computeTargetFile(for: actorable, in: targetDirectory, buckets: buckets)

        try targetFile.append(Rendering.generatedFileHeader)
        try targetFile.append("\n")

        try actorable.imports.forEach { importBlock in
            try targetFile.append("\(importBlock)")
        }

        try targetFile.append("\n")
        let codableConformance = try Rendering.MessageCodableTemplate(actorable: actorable).render()
        if self.printGenerated {
            print(codableConformance)
        }
        try targetFile.append(codableConformance)

        self.log.debug("Generated: \(targetFile.path)")
        return targetFile
    }

    // simple bucketing based on the first letter
    private func computeTargetFile(for actorable: ActorTypeDecl, in targetDirectory: Directory, buckets: Int) throws -> File {
        guard buckets > 0 else {
            preconditionFailure("invalid buckets. \(buckets) must be > 0")
        }

        guard let firstLetter = actorable.name.lowercased().first else {
            preconditionFailure("invalid actorable name: \(actorable.name)")
        }

        let letterIndex = Self.letters.firstIndex(of: firstLetter)
            .flatMap { Self.letters.distance(from: Self.letters.startIndex, to: $0) } ?? 0

        let bucket = Int(floor(Double(letterIndex) / ceil(Double(Self.letters.count) / Double(buckets))))
        self.log.debug("Assigning \(actorable.name) into bucket #\(bucket)")

        return try targetDirectory.file(named: "\(Self.generatedFilePrefix)\(bucket).swift")
    }

    private func isGeneratedFile(file: File) -> Bool {
        file.name.hasPrefix(Self.generatedFilePrefix)
    }

    private static let generatedFilePrefix = "GeneratedDistributedActors_"
    private static let letters = "abcdefghijklmnopqrstuvwxyz"
}
