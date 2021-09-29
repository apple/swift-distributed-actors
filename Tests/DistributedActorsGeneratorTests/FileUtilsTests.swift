//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import XCTest

@testable import DistributedActorsGenerator

final class FileUtilsTests: XCTestCase {
    let fileManager = FileManager.default
    
    func testFile() throws {
        let directoryURL = self.fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try self.fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        
        let filename = UUID().uuidString
        let fileExtension = "txt"
        let fileURL = directoryURL.appendingPathComponent("\(filename).\(fileExtension)")
        self.fileManager.createFile(atPath: fileURL.path, contents: nil)
        
        let file = try File(url: fileURL, fileManager: self.fileManager)
        XCTAssertEqual(fileURL, file.url)
        XCTAssertEqual(fileURL.path, file.path)
        XCTAssertEqual("\(filename).\(fileExtension)", file.name)
        XCTAssertEqual(fileExtension, file.extension)
        XCTAssertEqual(directoryURL.path, file.parent?.url.path)
        
        let contents = "Hello world"
        try file.append(contents)
        
        guard let fileData = self.fileManager.contents(atPath: file.path) else {
            return XCTFail("Test file should not be empty")
        }
        XCTAssertEqual(contents.data(using: .utf8), fileData)
        
        try file.delete()
        
        XCTAssertFalse(self.fileManager.fileExists(atPath: fileURL.path))
    }
    
    func testDirectory() throws {
        let directoryURL = self.fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try self.fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        
        let subdirectoryName = UUID().uuidString
        let subdirectoryURL = directoryURL.appendingPathComponent(subdirectoryName)
        try self.fileManager.createDirectory(at: subdirectoryURL, withIntermediateDirectories: true)
        
        let directory = try Directory(path: directoryURL.path, fileManager: self.fileManager)
        XCTAssert(directory.hasSubdirectory(named: subdirectoryName))
        
        let subdirectory = try directory.subdirectory(at: subdirectoryName)
        
        try directory.createFileIfNeeded(withName: "File.txt")
        try subdirectory.createFileIfNeeded(withName: "SubFile.ext")
        
        XCTAssertNoThrow(try directory.file(named: "File.txt"))

        directory.files.forEach { file in
            XCTAssert(Set(["File.txt"]).contains(file.name))
        }
        
        directory.files.recursive.forEach { file in
            XCTAssert(Set(["File.txt", "SubFile.ext"]).contains(file.name))
        }
        
        XCTAssertEqual(["SubFile.ext"], directory.files.recursive.filter { $0.extension == "ext" }.map { $0.name })
    }
}
