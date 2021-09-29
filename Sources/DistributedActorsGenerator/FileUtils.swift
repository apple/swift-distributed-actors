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

struct Directory: CustomStringConvertible {
    let url: URL
    let fileManager: FileManager
    
    var path: String {
        self.url.path
    }
    
    var parent: Directory? {
        let parentURL = self.url.deletingLastPathComponent()
        return try? Directory(path: parentURL.path, fileManager: self.fileManager)
    }
    
    var files: FilesEnumerator {
        FilesEnumerator(directory: self, fileManager: self.fileManager, isRecursive: false)
    }
    
    init(path: String, fileManager: FileManager = FileManager.default) throws {
        let path = path.expandingTildeInPath(fileManager: fileManager)
        
        guard fileManager.directoryExists(atPath: path) else {
            throw ReadError.doesNotExist(path: path)
        }
        
        self.url = URL(fileURLWithPath: path, isDirectory: true)
        self.fileManager = fileManager
    }
    
    func hasSubdirectory(named name: String) -> Bool {
        let subdirectoryPath = self.url.appendingPathComponent(name).path
        return self.fileManager.directoryExists(atPath: subdirectoryPath)
    }
    
    func subdirectory(at name: String) throws -> Directory {
        let subdirectoryPath = self.url.appendingPathComponent(name).path
        return try Directory(path: subdirectoryPath, fileManager: self.fileManager)
    }
    
    func createFileIfNeeded(withName name: String) throws {
        let filePath = self.url.appendingPathComponent(name).path
        guard !self.fileManager.fileExists(atPath: filePath, isDirectory: false) else {
            return
        }
        guard self.fileManager.createFile(atPath: filePath, contents: nil) else {
            throw WriteError.creationFailure(path: filePath)
        }
    }
    
    func file(named name: String) throws -> File {
        let fileURL = self.url.appendingPathComponent(name)
        return try File(url: fileURL, fileManager: self.fileManager)
    }
    
    var description: String {
        self.path
    }
}

struct File: CustomStringConvertible {
    let url: URL
    let name: String
    let fileManager: FileManager
    
    var path: String {
        self.url.path
    }
    
    var `extension`: String {
        self.url.pathExtension
    }
    
    var parent: Directory? {
        let parentURL = self.url.deletingLastPathComponent()
        return try? Directory(path: parentURL.path, fileManager: self.fileManager)
    }
    
    init(url: URL, fileManager: FileManager = FileManager.default) throws {
        guard fileManager.fileExists(atPath: url.path, isDirectory: false) else {
            throw ReadError.doesNotExist(path: url.path)
        }
        guard let name = url.pathComponents.last else {
            throw ReadError.invalidPath(url.path)
        }
        
        self.url = url
        self.name = name
        self.fileManager = fileManager
    }
    
    init(path: String, fileManager: FileManager = FileManager.default) throws {
        let path = path.expandingTildeInPath(fileManager: fileManager)
        let url = URL(fileURLWithPath: path)
        try self.init(url: url, fileManager: fileManager)
    }
    
    func append(_ string: String, encoding: String.Encoding = .utf8) throws {
        guard let data = string.data(using: encoding) else {
            throw WriteError.encodingError
        }

        do {
            let handle = try FileHandle(forWritingTo: self.url)
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } catch {
            throw WriteError.writeFailure(path: self.path, detail: "\(error)")
        }
    }
    
    func delete() throws {
        try self.fileManager.removeItem(at: self.url)
    }
    
    var description: String {
        self.path
    }
}

enum ReadError: Error {
    case doesNotExist(path: String)
    case invalidPath(String)
}

enum WriteError: Error {
    case doesNotExist(path: String)
    case creationFailure(path: String)
    case encodingError
    case writeFailure(path: String, detail: String)
}

struct FilesEnumerator {
    let directory: Directory
    let fileManager: FileManager
    
    let isRecursive: Bool
    
    var recursive: FilesEnumerator {
        FilesEnumerator(directory: self.directory, fileManager: self.fileManager, isRecursive: true)
    }
    
    func forEach(handler: (File) -> Void) {
        let resourceKeys = Set<URLResourceKey>([.isDirectoryKey])
        guard let enumerator = self.fileManager.enumerator(at: self.directory.url, includingPropertiesForKeys: Array(resourceKeys), options: .skipsHiddenFiles) else {
            return
        }
        
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
                  let isDirectory = resourceValues.isDirectory
            else {
                continue
            }
            
            if isDirectory {
                if !self.isRecursive {
                    enumerator.skipDescendants()
                }
            } else {
                guard let file = try? File(url: fileURL, fileManager: self.fileManager) else {
                    continue
                }
                handler(file)
            }
        }
    }
    
    func filter(predicate: (File) -> Bool) -> [File] {
        var files = [File]()
        self.forEach { file in
            if predicate(file) {
                files.append(file)
            }
        }
        return files
    }
}

// MARK: - FileManager extensions

fileprivate extension FileManager {
    func directoryExists(atPath path: String) -> Bool {
        self.fileExists(atPath: path, isDirectory: true)
    }
    
    func fileExists(atPath path: String, isDirectory: Bool) -> Bool {
        var isDirectoryBool = ObjCBool(isDirectory)
        let exists = self.fileExists(atPath: path, isDirectory: &isDirectoryBool)
        return exists && (isDirectoryBool.boolValue == isDirectory)
    }
}
