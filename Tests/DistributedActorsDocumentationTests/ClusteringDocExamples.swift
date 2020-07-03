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

import DistributedActors
@testable import DistributedActorsTestKit
import NIOSSL
import XCTest

class ClusteringDocExamples: XCTestCase {
    func example_config_tls() throws {
        // tag::config_tls[]
        let system = ActorSystem("TestSystem") { settings in
            // ...
            settings.cluster.tls = TLSConfiguration.forServer( // <1>
                certificateChain: try! NIOSSLCertificate.fromPEMFile("/path/to/certificate.pem").map { NIOSSLCertificateSource.certificate($0) }, // <2>
                privateKey: .file("/path/to/private-key.pem"), // <3>
                certificateVerification: .fullVerification, // <4>
                trustRoots: .file("/path/to/certificateChain.pem")
            ) // <5>
        }
        // end::config_tls[]

        try! system.shutdown().wait()
    }

    func example_config_tls_passphrase() throws {
        // tag::config_tls_passphrase[]
        let system = ActorSystem("TestSystem") { settings in
            // ...
            settings.cluster.tlsPassphraseCallback = { setter in
                setter([UInt8]("password".utf8))
            }
        }
        // end::config_tls_passphrase[]

        try! system.shutdown().wait()
    }
}
