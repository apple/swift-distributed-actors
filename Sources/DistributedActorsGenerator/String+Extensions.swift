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

import Foundation

extension String {
    func findFirstNot(character: Character) -> String.Index? {
        var index = startIndex

        while index != endIndex {
            if character != self[index] {
                return index
            }
            index = self.index(after: index)
        }

        return nil
    }

    func findLastNot(character: Character) -> String.Index? {
        var index = self.index(before: endIndex)

        while index != startIndex {
            if character != self[index] {
                return self.index(after: index)
            }
            index = self.index(before: index)
        }

        return nil
    }

    func trim(character: Character) -> String {
        let first = self.findFirstNot(character: character) ?? startIndex
        let last = self.findLastNot(character: character) ?? endIndex
        return String(self[first ..< last])
    }

    func expandingTildeInPath(fileManager: FileManager = FileManager.default) -> String {
        var path = self
        if path.hasPrefix("~") {
            path = fileManager.homeDirectoryForCurrentUser.path + path.dropFirst()
        }
        return path
    }
}
