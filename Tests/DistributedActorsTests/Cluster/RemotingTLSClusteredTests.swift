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

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import NIOSSL
import XCTest

class RemotingTLSTests: ClusteredNodesTestBase {
    let testCert1 = """
    -----BEGIN CERTIFICATE-----
    MIIDEjCCAfoCCQCHROo5Bb+wETANBgkqhkiG9w0BAQsFADBKMQswCQYDVQQGEwJV
    UzETMBEGA1UECAwKQ2FsaWZvcm5pYTESMBAGA1UEBwwJQ3VwZXJ0aW5vMRIwEAYD
    VQQDDAlsb2NhbGhvc3QwIBcNMTkwMzEzMTcyODA5WhgPMjExOTAyMTcxNzI4MDla
    MEoxCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRIwEAYDVQQHDAlD
    dXBlcnRpbm8xEjAQBgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZIhvcNAQEBBQAD
    ggEPADCCAQoCggEBAOiZHuxjk/syP6PPoJwky1WNeTtB2Dislx2H+eX6VxhWiJma
    loZd8HsA1PmYP5XolaUfTeNnuOpzNzSqf7E2j9r+ebrVhXZzLs96Vg8H+y+c+Eli
    JOW6RxapYLKkqOtgFTi7swsswq8A2ZAX6TfA9F3x6E7CauHNDXpy/yOICd9KnSJz
    bAqxhDeXJb9FNeLhL1DGuZjW82Zmpxe7YDymaeHA4OJ+OVOg+hIBCKjmmq0gpYgc
    M65GKehzI50qQ+pkV1u73UL6zE8w7ltRWIVmuRGSR08fa6fs1YIrnXDNwKoH/vG4
    mWTA+tRswZTxYRaHspJ5HEeZC7YmVOtBQDaMTHUCAwEAATANBgkqhkiG9w0BAQsF
    AAOCAQEAdV5DUx4h4kW+raPWWpEC+E8K0Gvsdw5JBzkScxNF5z0aEanO4CAx1rHA
    vv1brQz5EC5+mFA8uour0uAoKu2nvlIvOcYuBS7Kesny0dvi3/8z13jXYPUk1tN7
    aeNO2N7Y3ZE+vV86UoYNEBJkFoF5h0Gu+vfeIjnpLNWYeXTGcuFZUXqlWbhrT9fR
    aAsjDIMWaAVO1eZ0vxG0aWOrAbKCHnhs/nNnqrbIHyW1T6cOcufIuZNhVpHOBVBx
    WIxdGLNaNzBYHSsij78GlwNUGkNC6/M7UGbsUXcbErMxBeADhfIDlANqOC5I/wbz
    IFIudYjIjS4/W/8WNRavjGQkeXp3OQ==
    -----END CERTIFICATE-----
    """

    let testKey1 = """
    -----BEGIN PRIVATE KEY-----
    MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDomR7sY5P7Mj+j
    z6CcJMtVjXk7Qdg4rJcdh/nl+lcYVoiZmpaGXfB7ANT5mD+V6JWlH03jZ7jqczc0
    qn+xNo/a/nm61YV2cy7PelYPB/svnPhJYiTlukcWqWCypKjrYBU4u7MLLMKvANmQ
    F+k3wPRd8ehOwmrhzQ16cv8jiAnfSp0ic2wKsYQ3lyW/RTXi4S9QxrmY1vNmZqcX
    u2A8pmnhwODifjlToPoSAQio5pqtIKWIHDOuRinocyOdKkPqZFdbu91C+sxPMO5b
    UViFZrkRkkdPH2un7NWCK51wzcCqB/7xuJlkwPrUbMGU8WEWh7KSeRxHmQu2JlTr
    QUA2jEx1AgMBAAECggEAStNvgkZqhaXdmTojBfhEPWp8tJZzE5BaMNLcjqJhQGAe
    I6P6hpFT2o4i9YSH+BbRhUQzz1M/xpR4DwZGe+D8mEvDJ1qnS7q0NWS6qK09nkyW
    By1+hzTMx7qHdBDKkqXfTdf8Oj0VCC1y0AsRKLF3K3216RhcP/WyP1EdSPXrjxwZ
    swF27RObQUCWeXWr+crirB2+tWFK2Pj3UMRtTLyd8Y3M9f2xpbnVV87uEmyh4i+w
    B7HO3dqJ1d8q3goPEt6gGifauRa7pYp8UINH0RXPBJ/VFYkQzLgoXmKiJEteC89I
    Mn1GHTIIKheA1y7q5iqRfz0SEjHxjerB9AGsBLo4YQKBgQD525uIUPk848xgU33c
    b7jOQB7DTI9rEgI5uDzQmwh5MNO0RahrNml6qyfU1GXKBHwmlZmt4RO3oY0t8mbf
    0Db0oJk/Xvn84PzuO2DgqRn3suJMQmVmwOyQT1wt09XeZxRGN3dXvd5MNEGSRIx9
    rPw2iZfnq0b6SDTqzNHt7n/w3QKBgQDuUOUy08JN5eqpIOHQkvkEkEfbQVCTb9MN
    zYIniCSdytRZSZDzEhzbMO64a/XBby1pc1G9Txep8fxguY2+gQDlXM0AZz7o/81T
    TQFIE09Q7/ZAtOkOGMknjVUeS7qYuXiJN3+44qlBhiCJZAsnhLnoyP2/rN7gGKNm
    kGJtAJAEeQKBgQDdjtESRctdJRrb5+1ZhXA45D7jK4aZiTST/j1fNbqDzLpNxt8b
    gvpxnkgJv/Yq92Mny8yklUuosAbC0YpLuRSiQ67gtNW0WcWvctPrI8g1D1kACnhk
    b3rWVKkGsiuZtYoS4ahgE6uFo2jpzQNPhg94RPaApi6gTVsvQkR9Wdn1uQKBgAm8
    +ICpMoloWbxrgY66Ur6i/qyw8I/1w9QOj8D5yTVBcofrf6bPGKrERxz2HGa5Gkvy
    0GZB8x+Yqc1yB56/OsAkmKPplCKFQWij/udpEpamF5PxUIyo6p9ZIR9JzOgsvAYv
    ZGKzsGLjDjVPBz2oKMigXe4VLE5P821ffQYjPb9RAoGBAJRbzXVriSdN8W9rP8T/
    w6qNsdFkR9kqTL8JcThI7dC2J4w/khnrJ62dfNJsWBsw5FEkHGv1Y/9o7P+gkWyr
    2BVZ18uewr/K/gWvH8iHjmlnNESlHSdTGhm0HquwgTPmUzQJX1bMQ90ye62y+ekI
    36S7aBeyL/j2AXm/lmNxrKOU
    -----END PRIVATE KEY-----
    """

    let testCert2 = """
    -----BEGIN CERTIFICATE-----
    MIIDEjCCAfoCCQCfsFo8GxrR8jANBgkqhkiG9w0BAQsFADBKMQswCQYDVQQGEwJV
    UzETMBEGA1UECAwKQ2FsaWZvcm5pYTESMBAGA1UEBwwJQ3VwZXJ0aW5vMRIwEAYD
    VQQDDAlsb2NhbGhvc3QwIBcNMTkwMzEzMTcwOTA5WhgPMjExOTAyMTcxNzA5MDla
    MEoxCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRIwEAYDVQQHDAlD
    dXBlcnRpbm8xEjAQBgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZIhvcNAQEBBQAD
    ggEPADCCAQoCggEBANKFKEQ5B3/21Ho+KugygDwbilTG1HYrJLkqn67JbZOyfgnQ
    0hWjyJlnpqWwQGYcoWHuLvceDNYf7/gmLCE4K11QUfa9RnfGggRzUfSPuKQ/RiHq
    4FZ0qXFXobve8nMRdomuhP+haC2Qvrgas/ycwqZg08tcDPiH08zohg/FocWfY6mU
    leAuR+2rMXJu6JptSOSOqk7QkTTNOZiqIns09ogs5j6wIWyl562IHBx8JCXiduVg
    a86KFq4QXKC8OqXLqXjzNQ2wsmXI3ZgK0IXZFJnPCGaecnaauqrKeVcIAjDRfW9J
    GZ2n0ArvxPqn57Wa61NRG33ubIgmL7+Mq3AwY40CAwEAATANBgkqhkiG9w0BAQsF
    AAOCAQEAkPVN2l/XrBM0xh7yYXVXIqIqwRobw7xYby13JkhlcY9z3E4Aj4nU+7T7
    Ctf8suR7J4hhjqsDKq2sRs5AakTNimjQXV9aofdfycZyoE3CYS04QtiQCKf7AayV
    qQDB7/7EVxpyxnI3ZLDk0ohBlAqLL63cgJ90p7TY5cI5RHiB6J9ThEwvc5BAIE0s
    ktSnAPjyjr7AByHwXI7BuUzm8ALT1YpbsEBWPlz4M+9YiblhkPotlyH+nG8AyrJW
    ZoZ+ReHXm+Q402/wxVCHWO8pfU4X1VVGFXNChUd8iYvZOoHIxx0pVlHjSFxMzSq/
    bk3g8S1ADd6SOhVNkjKBiekynIfYYg==
    -----END CERTIFICATE-----
    """

    let testKey2 = """
    -----BEGIN PRIVATE KEY-----
    MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDShShEOQd/9tR6
    PiroMoA8G4pUxtR2KyS5Kp+uyW2Tsn4J0NIVo8iZZ6alsEBmHKFh7i73HgzWH+/4
    JiwhOCtdUFH2vUZ3xoIEc1H0j7ikP0Yh6uBWdKlxV6G73vJzEXaJroT/oWgtkL64
    GrP8nMKmYNPLXAz4h9PM6IYPxaHFn2OplJXgLkftqzFybuiabUjkjqpO0JE0zTmY
    qiJ7NPaILOY+sCFspeetiBwcfCQl4nblYGvOihauEFygvDqly6l48zUNsLJlyN2Y
    CtCF2RSZzwhmnnJ2mrqqynlXCAIw0X1vSRmdp9AK78T6p+e1mutTURt97myIJi+/
    jKtwMGONAgMBAAECggEAZhqjPwOR+aSTxX5lfR0RSRXqb9fHsFCYjR55OGMFvH7z
    1nrrigdYAd9d2jqz4VK9iyvkp4Jxo2D2GJsbCDmf/rA4ML34cZtb8CCmfUE/wpnV
    wBmVGRmYHRrtnJszaE/t+DUm2H1Gc+MiPVTmOv0lA2EvGBDbUac/OMEGVJv8LEaS
    ZDG2w58JxqpmOYnT8yotDT/0TG/7QZGuPbzi2zv2BpzjkFI3LLWxgBAJb1B5Y9uF
    aniYhmClJOVk9PgloMHLRl2/SOPe5Hj/Q0MPBgk70Ln7cOWC1ffZsnSe0zCZYuvH
    6yLyaVQkZAE20Dl7GKJl4ba5WkjP2x2AsTlKr8WkAQKBgQD5LyU7OLdaZpVkvKuj
    IpN/9xIO6LLge/chCf4euv8VZH0j6ZO/AD1fGn6ltBTJJm1ENMmKT6bqu2vIzJhc
    w9Mz6kaZcDlViyLjy2PzxoQcYT8k9pDinztAEVXci/K+2G2kgZdUt8356kaiWVJV
    dnyYfnm537z7H95CgBoB6sGODQKBgQDYR0aohjQmbCrxIUworPkUlxvqgDEu4Z0P
    XU8NXbzFfnI56AwahvqlGmTUXpAJsxVxhq1PlYaB/7vvUU3nL4ir3wslmtTWapJb
    1DQoK8h6sZz7j1vU2dkYSqNMZrRSeWrlUvTo5XnaUHzZO1qaM+17FW2sgr6Hhhn9
    NGoLl7JLgQKBgQCnutZi4LB6x2Z0IpOeAd4rWtHq+zO863TT5ngJk3G0oqmhjM6I
    2M52v8zUGT2MkLMoICgxU6BVjMbmqOE+QApgfaf8DJBrRna7wuKK6utudv8cEGRC
    R1CItaKIDCPf1qsm+pw0yGx7dvkIuvsyz8jalPe26CW7HB5twPDArZaP2QKBgQCW
    37IE4goDO7YBHG9aeMARgxBwWBj3UWAVVcxN0LRdOUZJ6vx2jO7QukbYd1cXzRwK
    ZB8Gw5JfoZzi597mhZxb+W53Pzl2kkWjVbdExrZGER0nx+wR4h61+WtNYuAsIJNX
    grViuqJ0j21oxSUBKXRjRqGJlHOBayU6I5ROnfY9AQKBgHQTDh9gFXD0TDUYB+dV
    2MpCCGhdPOQmBwNgU1uyc9zKMUYUrOPuhPkCokGmjaJ1CYdNGMXgXkisYIoaXyf1
    XE+49aqIAPQ/yf4tkUebM/BdIg2eBUClYlFfeS/kJ7uvZepa2Hc6SG3W7tCArf7Q
    TR27Lm3gs9KewXcsKNR7jpTK
    -----END PRIVATE KEY-----
    """

    let passordProtectedCert = """
    -----BEGIN CERTIFICATE-----
    MIIDEjCCAfoCCQCPxmczzChNtTANBgkqhkiG9w0BAQsFADBKMQswCQYDVQQGEwJV
    UzETMBEGA1UECAwKQ2FsaWZvcm5pYTESMBAGA1UEBwwJQ3VwZXJ0aW5vMRIwEAYD
    VQQDDAlsb2NhbGhvc3QwIBcNMTkwMzEzMjA1NzIyWhgPMjExOTAyMTcyMDU3MjJa
    MEoxCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRIwEAYDVQQHDAlD
    dXBlcnRpbm8xEjAQBgNVBAMMCWxvY2FsaG9zdDCCASIwDQYJKoZIhvcNAQEBBQAD
    ggEPADCCAQoCggEBAKqdvtwZKgIbRKLy7Ohvf7KpjMAuPD+KcltEIibmq/V16ZO/
    wnG5AWeiheIRo5hOCTLwSBLd7623Zudi1a0ELKh3hc2MV9vCqN2IV/AUkpW/EVCP
    2VNZbFY9U4eH1RGdjp6jdCdywCk7/d59i9gqmiijCuTJCMv39PaU1JEmdqHlAMN4
    ebSczVyrCNRRNL9d/9FiRUsWN18oK2X8O5dP7A490BwyuR6MxfrE9m9oM5OZ+dCg
    guAqdvRYfy2xlpEdrB2prV5Ggn/5IGYzBIzasN29mZF4usXq3+YdIHjJWCcBUhQ+
    RsDvkGN1m1E1BmjSKf2rhypvVZ0RXPplVhNmpoUCAwEAATANBgkqhkiG9w0BAQsF
    AAOCAQEADU1hAzKHFTUZAHXWADLj5/bowXsYHkYNJexdAhA/dQfezWgyy9BVVUAX
    NGvWctVZo7Zq3Yxj4jdfsiVJuEmoJGQNeiPZi1YqynOfzmgsTPqvaaNY20THTjxw
    KrCIHM31WZ73VVm8Kw4XZbuhRNuhh22jazgUeYQt6CmzTyEsE05CLSsV0xhu++yO
    kDXtqMPvNJlq+mNo9PVs2Y3fzvaCLzQS8upCbDOMXFteRjiTc2yGn9DNZ+/R3/Jw
    QKqr4P73Fbe7Kr/4Q8Du8Zz4K5NPQnPtPpxCoN3Z/9CIU3QCePLBemQLFvH6MB6n
    TaMYkV4J7QXWgPVgN5ppfgJXiVFmMA==
    -----END CERTIFICATE-----
    """

    let passwordProtectedKey = """
    -----BEGIN ENCRYPTED PRIVATE KEY-----
    MIIFHzBJBgkqhkiG9w0BBQ0wPDAbBgkqhkiG9w0BBQwwDgQIW9zOkKWG8/gCAggA
    MB0GCWCGSAFlAwQBKgQQgWpUFFKJTJn6v6C5qj//dASCBNBPbU3LYQOsS1zElbG6
    K/yi2KQNI6CVlUq6NP3pT2KbWicR3e1uZps6M2F3TKq5IclSbIDVSW92Xkwd6kbH
    4hj/TWA1Hf7UtrAoEHCSvxCj0gs+ExDQikl0OmLfRQ+UFILR5fYMy0dsGVV9HQ7O
    AHHF/BymYM2uVOE7lFG6zyERan9HX8LBVd+dy7qqwQdAoK6n5Z8jd4I5kqo7an+f
    J+uK6rXbLYrqOICtMXGWoIHqR2vVwDgt5UwZHhCMmaK3KKdRI6W04PctYZQTjeSs
    kfEJISC9UPg0TdxmCbhumm5UjWhn9gjIPoxxCwfhdTiOVljNlzniK8CosUzeQpxv
    8tIcfsruZxZcBc1hL0ul8E9dENyNZ48cXXZNVOwAqRwqymbswbs4+hRUHXjKu7T6
    yKhAtoy5KLvAdXGQnaSm4yW5EVbX2wWnYmfltJomvW/pM7YK7d8tosMjdodMTYNF
    g/W0QvxR8UQy+CY4C+4ARd5q772ImhWKsAouLk6mpxKr0LWVX/OmXZsUHV13A5jy
    pxL8G+X6H5A6ykCUdrWuzM0f1oGH+dcuwW6xtZ7uu+QnFaJff3QJ++8Z0xzwueMn
    EoY692RKUrYcX2K6Os6SIQC0zk4hbVFPaOoHavMATw/tZrRscfYPEf072S6mJmQ/
    N0lomjT/BeLBC+ul/zabwByvEYlRaFYK3dui+KBveTZXNo7xIOoDrGsC0v4vnOnm
    5UW1RMecbBqum3XWEe4pRKe7SFiViRkQkBaNITtjFQTvdIAXASaz6d/ifcLfDzjD
    t9ucwx7xjcDHcs78hVFEa/9wc0REYqryMF9jS1AHmJO470YsZpP3aIdvug+v0fyR
    1r46zrgNwwERREsCDQbZ3M3xHlt0w6iriw72+Ii/IgKLWoFY3Kt12aoxR4LtF1FT
    kZYFTqFJ0wr5rLx+jV7lik62t36+q7/tnvP0xT9XdGuqURRuMCINcKriCG3MG/os
    5CjBThWmG3YeGxImaSvtIqq50UVsobVK+sdGsqu1N+I8/+a0AHEzQRgjhQCFE6wq
    WUw2QbTC9/siPKTQwBxqdIq2x1FaVV+4YER7woGPxyXdD32E6LibqwXlOQF/yim2
    EzpdkXuzEpTG+cEA9/7hzIh9k5oyA59DRDMKObXPvZiLNkHCbUVIBZIedGu8ZELH
    gmDJ6mryVF7DPZRE6Xkrczf3W0yg6HGayD0btPnM/muw7vOwPaO7hdNTeN/GHlNx
    QqTuH99OUGjxnJ3P8c6LcTs7hp2ggnCuuQjhNAtQBW6UNaXdKGRl9g491CHTdqIE
    TqxBCDLItzrEqJUorfOJzs0r5liTmwN5/x1zgCQE+N1Vi+dOJHKGj+xNGRKsQKIG
    v8FzEr0tWfk1NqHENRlwTzUSspObEo2yAj1LGk1J2yPHjF4S7OpzOk7HPVFjaXyO
    faA60MIk2CwBlUD9bP058e+3gcNnkkpZ9/ij2FQwJ+5C+IdLQYO5tGpEXj8WtZgX
    5GvsC9WB+UKtsHoEhebMyUsGG91NbEdSlewDJsmRTR/09vjaxDrYZ/EOVkJSlIa+
    P5YJu6MpVM9IQSbvvUJDpWQDIDGEMgmtCS4OeQU6eBrLycbaaACVfl2CM+uZS9a9
    4kJcI9XB+mMhar8E6LsX76NbSg==
    -----END ENCRYPTED PRIVATE KEY-----
    """

    func test_boundServer_shouldAcceptAssociateWithSSLEnabled() throws {
        let testCertificate1 = try NIOSSLCertificate(bytes: [UInt8](testCert1.utf8), format: .pem)
        let testCertificateSource1: NIOSSLCertificateSource = .certificate(testCertificate1)
        let testKeySource1: NIOSSLPrivateKeySource = .privateKey(try NIOSSLPrivateKey(bytes: [UInt8](testKey1.utf8), format: .pem))

        let testCertificate2 = try NIOSSLCertificate(bytes: [UInt8](testCert2.utf8), format: .pem)
        let testCertificateSource2: NIOSSLCertificateSource = .certificate(testCertificate2)
        let testKeySource2: NIOSSLPrivateKeySource = .privateKey(try NIOSSLPrivateKey(bytes: [UInt8](testKey2.utf8), format: .pem))

        let local = self.setUpNode("local") { settings in
            settings.cluster.tls = TLSConfiguration.forServer(
                certificateChain: [testCertificateSource1],
                privateKey: testKeySource1,
                certificateVerification: .fullVerification,
                trustRoots: .certificates([testCertificate2])
            )
        }

        let remote = setUpNode("remote") { settings in
            settings.cluster.tls = TLSConfiguration.forServer(
                certificateChain: [testCertificateSource2],
                privateKey: testKeySource2,
                certificateVerification: .fullVerification,
                trustRoots: .certificates([testCertificate1])
            )
        }

        local.cluster.join(node: remote.cluster.node.node)

        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)
    }

    func test_boundServer_shouldFailWithSSLEnabledOnHostnameVerificationWithIP() throws {
        let testCertificate = try NIOSSLCertificate(bytes: [UInt8](testCert1.utf8), format: .pem)
        let testCertificateSource: NIOSSLCertificateSource = .certificate(testCertificate)
        let testKey: NIOSSLPrivateKeySource = .privateKey(try NIOSSLPrivateKey(bytes: [UInt8](testKey1.utf8), format: .pem))

        let local = self.setUpNode("local") { settings in
            settings.cluster.node.host = "127.0.0.1"
            settings.cluster.tls = TLSConfiguration.forServer(
                certificateChain: [testCertificateSource],
                privateKey: testKey,
                certificateVerification: .fullVerification,
                trustRoots: .certificates([testCertificate])
            )
        }

        let remote = setUpNode("remote") { settings in
            settings.cluster.node.host = "127.0.0.1"
            settings.cluster.tls = TLSConfiguration.forServer(
                certificateChain: [testCertificateSource],
                privateKey: testKey,
                certificateVerification: .fullVerification,
                trustRoots: .certificates([testCertificate])
            )
        }

        let testKit = ActorTestKit(local)

        local.cluster.join(node: remote.cluster.node.node)

        sleep(2)

        do {
            let pSystem = testKit.spawnTestProbe(expecting: Set<UniqueNode>.self)
            local.cluster._shell.tell(.query(.associatedNodes(pSystem.ref)))
            remote.cluster._shell.tell(.query(.associatedNodes(pSystem.ref)))
            let associatedNodes = try pSystem.expectMessage()
            associatedNodes.shouldBeEmpty() // means we have not associated to _someone_
        }

        do {
            let pRemote = testKit.spawnTestProbe(expecting: Set<UniqueNode>.self)
            local.cluster._shell.tell(.query(.associatedNodes(pRemote.ref))) // FIXME: We need to get the Accept back and act on it on the origin side
            remote.cluster._shell.tell(.query(.associatedNodes(pRemote.ref)))
            let associatedNodes = try pRemote.expectMessage()
            associatedNodes.shouldBeEmpty() // means we have not associated to _someone_
        }
    }

    func test_boundServer_shouldAcceptAssociateWithSSLEnabledOnNoHostnameVerificationWithIP() throws {
        let testCertificate = try NIOSSLCertificate(bytes: [UInt8](testCert1.utf8), format: .pem)
        let testCertificateSource: NIOSSLCertificateSource = .certificate(testCertificate)
        let testKey: NIOSSLPrivateKeySource = .privateKey(try NIOSSLPrivateKey(bytes: [UInt8](testKey1.utf8), format: .pem))
        let local = self.setUpNode("local") { settings in
            settings.cluster.node.host = "127.0.0.1"
            settings.cluster.tls = TLSConfiguration.forServer(
                certificateChain: [testCertificateSource],
                privateKey: testKey,
                certificateVerification: .noHostnameVerification,
                trustRoots: .certificates([testCertificate])
            )
        }

        let remote = setUpNode("remote") { settings in
            settings.cluster.node.host = "127.0.0.1"
            settings.cluster.tls = TLSConfiguration.forServer(
                certificateChain: [testCertificateSource],
                privateKey: testKey,
                certificateVerification: .noHostnameVerification,
                trustRoots: .certificates([testCertificate])
            )
        }

        local.cluster.join(node: remote.cluster.node.node)

        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)
    }

    func test_boundServer_shouldAcceptAssociateWithSSLEnabledAndCorrectPassphrase() throws {
        let tmpKeyFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("key-\(NSUUID().uuidString).pem")
        defer {
            do {
                try FileManager.default.removeItem(at: tmpKeyFile)
            } catch {}
        }
        try self.passwordProtectedKey.write(to: tmpKeyFile, atomically: false, encoding: .utf8)
        let testCertificate = try NIOSSLCertificate(bytes: [UInt8](passordProtectedCert.utf8), format: .pem)
        let testCertificateSource: NIOSSLCertificateSource = .certificate(testCertificate)
        let testKey: NIOSSLPrivateKeySource = .file(tmpKeyFile.path)
        let local = self.setUpNode("local") { settings in
            settings.cluster.tls = TLSConfiguration.forServer(
                certificateChain: [testCertificateSource],
                privateKey: testKey,
                certificateVerification: .noHostnameVerification,
                trustRoots: .certificates([testCertificate])
            )
            settings.cluster.tlsPassphraseCallback = { setter in
                setter([UInt8]("test".utf8))
            }
        }

        let remote = setUpNode("remote") { settings in
            settings.cluster.tls = TLSConfiguration.forServer(
                certificateChain: [testCertificateSource],
                privateKey: testKey,
                certificateVerification: .noHostnameVerification,
                trustRoots: .certificates([testCertificate])
            )
            settings.cluster.tlsPassphraseCallback = { setter in
                setter([UInt8]("test".utf8))
            }
        }

        local.cluster.join(node: remote.cluster.node.node)

        try assertAssociated(local, withExactly: remote.settings.cluster.uniqueBindNode)
    }
}
