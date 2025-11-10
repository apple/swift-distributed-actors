//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(tvOS) || os(iOS) || os(watchOS) || os(visionOS)
/// Provider of Instrumentation instances which use `os_signpost`.
internal struct OSSignpostInstrumentationProvider: ClusterSystemInstrumentationProvider {
    init() {}

    var actorTransportInstrumentation: (() -> _InternalActorTransportInstrumentation)? {
        if #available(OSX 10.14, iOS 12.0, *) {
            return OSSignpost_InternalActorTransportInstrumentation.init
        } else {
            return nil
        }
    }

    var receptionistInstrumentation: (() -> _ReceptionistInstrumentation)? {
        if #available(OSX 10.14, iOS 12.0, *) {
            return OSSignpostReceptionistInstrumentation.init
        } else {
            return nil
        }
    }
}
#endif
