//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedActorsTestKit
import DistributedCluster
import NIOSSL
import Testing

@Suite(.serialized)
struct ClusteringDocExamples {
    
    @Test
    func example_config_tls() throws {
        // tag::config_tls[]
        let system = ClusterSystem("TestSystem") { settings in
            // ...
            settings.tls = TLSConfiguration.makeServerConfiguration( // <1>
                certificateChain: try! NIOSSLCertificate.fromPEMFile("/path/to/certificate.pem").map { NIOSSLCertificateSource.certificate($0) }, // <2>
                privateKey: .file("/path/to/private-key.pem") // , // <3>
//                certificateVerification: .fullVerification, // <4>
//                trustRoots: .file("/path/to/certificateChain.pem")
            ) // <5>
            settings.tls?.certificateVerification = .fullVerification
            settings.tls?.trustRoots = .file("/path/to/certificateChain.pem")
        }
        // end::config_tls[]

        try! await system.shutdown().wait()
    }

    @Test
    func example_config_tls_passphrase() throws {
        // tag::config_tls_passphrase[]
        let system = ClusterSystem("TestSystem") { settings in
            // ...
            settings.tlsPassphraseCallback = { setter in
                setter([UInt8]("password".utf8))
            }
        }
        // end::config_tls_passphrase[]

        try! await system.shutdown().wait()
    }
}
