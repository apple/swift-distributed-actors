# Security

Configuring security aspects of your cluster system.

@Comment {
    fishy-docs:enable
}

## Overview

Securing your cluster system mostly centers around two concepts: making sure you trust your peers and systems which are able to call into the cluster,
and ensuring that messages exchanged are of trusted types.

### Transport Security: TLS

> Note: **TODO:** explain configuring TLS

```swift
import DistributedCluster
import NIOSSL
```

```swift
let testCert1 = "<load the CERTIFICATE from somewhere>"
let testKey1 = "<load the PRIVATE KEY from somewhere>"

let testCert2 = "<load the CERTIFICATE from somewhere>"
let testKey2 = "<load the PRIVATE KEY from somewhere>"

let testCertificate2 = try NIOSSLCertificate(bytes: [UInt8](testCert2.utf8), format: .pem)
let testCertificateSource2: NIOSSLCertificateSource = .certificate(testCertificate2)
let testKeySource2: NIOSSLPrivateKeySource = .privateKey(try NIOSSLPrivateKey(bytes: [UInt8](testKey2.utf8), format: .pem))
```

```swift
let testCertificate1 = try NIOSSLCertificate(bytes: [UInt8](testCert1.utf8), format: .pem)
let testCertificateSource1: NIOSSLCertificateSource = .certificate(testCertificate1)
let testKeySource1: NIOSSLPrivateKeySource = .privateKey(try NIOSSLPrivateKey(bytes: [UInt8](testKey1.utf8), format: .pem))

let tlsExampleSystem = await ClusterSystem("tls-example") { settings in
    settings.endpoint.host = "..."
    settings.tls = TLSConfiguration.makeServerConfiguration(
        certificateChain: [testCertificateSource1],
        privateKey: testKeySource1
    )
    settings.tls?.certificateVerification = .fullVerification
    settings.tls?.trustRoots = .certificates([testCertificate2])
}
```

### Message Security

The other layer of security is about messages which are allowed to be sent to actors.

In general, you can audit your distributed API surface by searching your codebase for `distributed func` and `distributed var`, and verify the types involved in those calls.

The cluster also requires all types invokved in remote calls to conform to `Codable` and will utilize `Encoder` and `Decoder` types to deserialize them. As such, the typical attack of "accidentally deserialize an arbitrary sub-class of a type" is prevented by the `Codable` type itself.

#### Trusting message types


#### Trusting error types

Error types may be transported back to a remote caller if they are trusted.

By default, errors are NOT serialized even if they conform to `Codable` and one has to explicitly opt errors into shipping them back to callers, by adding the trusted types to the ``ClusterSystemSettings/RemoteCallSettings/codableErrorAllowance`` configuration setting:

```swift
_ = await ClusterSystem("AllowedRemoteErrors") { settings in 
    settings.remoteCall.codableErrorAllowance = .custom(allowedTypes: [
        GreeterCodableError.self, 
        AnotherGreeterCodableError.self,
    ])
}

struct GreeterCodableError: Error, Codable {}
struct AnotherGreeterCodableError: Error, Codable {}
```

## Topics

- ``Serialization/Settings``
- ``ClusterSystemSettings/tls``
- ``ClusterSystemSettings/tlsPassphraseCallback``
