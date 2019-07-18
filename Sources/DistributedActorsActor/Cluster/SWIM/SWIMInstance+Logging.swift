//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct Logging.Logger

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Logging Metadata

extension SWIM.Instance {

    /// While the SWIM.Instance is not meant to be logging by itself, it does offer metadata for loggers to use.
    var metadata: Logger.Metadata {
        return [
            "swim/protocolPeriod": "\(self.protocolPeriod)",
            "swim/incarnation": "\(self.incarnation)",
            "swim/memberCount": "\(self.memberCount)",
            "swim/suspectCount": "\(self.suspects.count)"
        ]
    }
}
