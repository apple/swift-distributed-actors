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


/// # SWIM (Scalable Weakly-consistent Infection-style Process Group Membership Protocol).
///
/// Namespace containing message types used to implement the SWIM protocol.
///
/// > As you swim lazily through the milieu,
/// > The secrets of the world will infect you.
///
/// - SeeAlso: https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf
public enum SWIM {

    // TODO actually separate them properly based on what they do etc
    internal enum Message {
        case ping(Payload)
        case pingReq(Payload)
        case ack(Payload)

        // TODO messages for pushing membership table etc

        case suspect(Payload)

        /// Extension: Lifeguard, Local Health Aware Probe
        /// LHAProbe adds a `nack` message to the fault detector protocol,
        /// which is sent in the case of failed indirect probes. This gives the member that
        ///  initiates the indirect probe a way to check if it is receiving timely responses
        /// from the `k` members it enlists, even if the target of their indirect pings is not responsive.
        // case nack(Payload)
    }

    internal enum Payload {
        case none
        // case membership(table I guess)
        // TODO: should be able to gossip payloads in each gossip message
    }

    // TODO may move around
    internal enum State {
        case Alive
        case Suspect
        case Dead
    }
}
