//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
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
import XCTest

final class CRDTLWWMapTests: XCTestCase {
    let replicaA: ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("a"), incarnation: .wellKnown))
    let replicaB: ReplicaId = .actorAddress(try! ActorAddress(path: ActorPath._user.appending("b"), incarnation: .wellKnown))

    func test_LWWMap_basicOperations() throws {
        var m1 = CRDT.LWWMap<String, Int>(replicaId: self.replicaA, defaultValue: 0)

        m1.underlying.shouldEqual([:])
        m1.keys.isEmpty.shouldBeTrue()
        m1.values.isEmpty.shouldBeTrue()
        m1.count.shouldEqual(0)
        m1.isEmpty.shouldBeTrue()

        m1.set(forKey: "foo", value: 3)
        m1.set(forKey: "bar", value: 5)

        guard let foo1 = m1["foo"] else {
            throw shouldNotHappen("Expect m1 to contain \"foo\", got \(m1)")
        }
        foo1.shouldEqual(3)

        guard let bar1 = m1["bar"] else {
            throw shouldNotHappen("Expect m1 to contain \"bar\", got \(m1)")
        }
        bar1.shouldEqual(5)

        m1["baz"].shouldBeNil() // doesn't exist

        m1.underlying.shouldEqual(["foo": 3, "bar": 5])
        Set(m1.keys).shouldEqual(["foo", "bar"])
        m1.values.count.shouldEqual(2)
        m1.count.shouldEqual(2)
        m1.isEmpty.shouldBeFalse()

        m1.set(forKey: "foo", value: 2)

        guard let foo2 = m1["foo"] else {
            throw shouldNotHappen("Expect m1 to contain \"foo\", got \(m1)")
        }
        foo2.shouldEqual(2) // changed to 2

        guard let bar2 = m1["bar"] else {
            throw shouldNotHappen("Expect m1 to contain \"bar\", got \(m1)")
        }
        bar2.shouldEqual(5) // no change

        // Delete "foo"
        _ = m1.unsafeRemoveValue(forKey: "foo")

        // "foo" should no longer exist
        m1["foo"].shouldBeNil()

        guard let bar3 = m1["bar"] else {
            throw shouldNotHappen("Expect m1 to contain \"bar\", got \(m1)")
        }
        bar3.shouldEqual(5) // no change

        m1.underlying.shouldEqual(["bar": 5])
        Set(m1.keys).shouldEqual(["bar"])
        m1.values.count.shouldEqual(1)
        m1.count.shouldEqual(1)
        m1.isEmpty.shouldBeFalse()

        m1.unsafeRemoveAllValues()

        m1["foo"].shouldBeNil()
        m1["bar"].shouldBeNil()

        m1.underlying.shouldEqual([:])
        m1.keys.isEmpty.shouldBeTrue()
        m1.values.isEmpty.shouldBeTrue()
        m1.count.shouldEqual(0)
        m1.isEmpty.shouldBeTrue()
    }

    func test_LWWMap_update_remove_shouldUpdateDelta() throws {
        var m1 = CRDT.LWWMap<String, Int>(replicaId: self.replicaA, defaultValue: 0)

        m1.set(forKey: "foo", value: 5)
        m1.count.shouldEqual(1)

        guard let d1 = m1.delta else {
            throw shouldNotHappen("Expect delta to be non nil")
        }
        // ORSet `keys`: [(A,1): "foo"]
        // `values`: ["foo": 5]
        d1.keys.versionContext.vv[self.replicaA].shouldEqual(1)
        d1.keys.elementByBirthDot.count.shouldEqual(1)
        d1.keys.elementByBirthDot[VersionDot(self.replicaA, 1)]!.shouldEqual("foo")
        d1.values.count.shouldEqual(1)

        guard let d1foo = d1.values["foo"] else {
            throw shouldNotHappen("Expect delta.values to contain \"foo\", got \(d1)")
        }
        d1foo.value.shouldEqual(5)

        m1.set(forKey: "bar", value: 3)
        m1.count.shouldEqual(2)

        guard let d2 = m1.delta else {
            throw shouldNotHappen("Expect delta to be non nil")
        }
        // ORSet `keys`: [(A,1): "foo", (A,2): "bar"]
        // `values`: ["foo": 5, "bar": 3]
        d2.keys.versionContext.vv[self.replicaA].shouldEqual(2)
        d2.keys.elementByBirthDot.count.shouldEqual(2) // two dots for different elements
        d2.keys.elementByBirthDot[VersionDot(self.replicaA, 1)]!.shouldEqual("foo")
        d2.keys.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("bar")
        d2.values.count.shouldEqual(2)

        guard let d2foo = d2.values["foo"] else {
            throw shouldNotHappen("Expect delta.values to contain \"foo\", got \(d2)")
        }
        d2foo.value.shouldEqual(5)

        guard let d2bar = d2.values["bar"] else {
            throw shouldNotHappen("Expect delta.values to contain \"bar\", got \(d2)")
        }
        d2bar.value.shouldEqual(3)

        _ = m1.unsafeRemoveValue(forKey: "foo")
        m1.count.shouldEqual(1) // "bar"

        guard let d3 = m1.delta else {
            throw shouldNotHappen("Expect delta to be non nil")
        }
        // ORSet `keys`: [(A,2): "bar"]
        // `values`: ["bar": 3]
        // keys.elementByBirthDot does not contain "foo" because it's been deleted, but keys.versionContext still has the version
        d3.keys.versionContext.vv[self.replicaA].shouldEqual(2)
        d3.keys.elementByBirthDot.count.shouldEqual(1)
        d3.keys.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("bar")
        d3.values.count.shouldEqual(1)

        guard let d3bar = d3.values["bar"] else {
            throw shouldNotHappen("Expect delta.values to contain \"bar\", got \(d3)")
        }
        d3bar.value.shouldEqual(3)

        m1.set(forKey: "foo", value: 6)
        m1.count.shouldEqual(2) // "foo" and "bar"

        guard let d4 = m1.delta else {
            throw shouldNotHappen("Expect delta to be non nil")
        }
        // ORSet `keys`: [(A,3): "foo", (A,2): "bar"]
        // `values`: ["foo": 6, "bar": 3]
        d4.keys.versionContext.vv[self.replicaA].shouldEqual(3)
        d4.keys.elementByBirthDot.count.shouldEqual(2)
        d4.keys.elementByBirthDot[VersionDot(self.replicaA, 3)]!.shouldEqual("foo")
        d4.keys.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("bar")
        d4.values.count.shouldEqual(2)

        guard let d4foo = d4.values["foo"] else {
            throw shouldNotHappen("Expect delta.values to contain \"foo\", got \(d4)")
        }
        d4foo.value.shouldEqual(6)
    }

    func test_LWWMap_merge_shouldMutate() throws {
        var m1 = CRDT.LWWMap<String, Int>(replicaId: self.replicaA, defaultValue: 0)

        var m2 = CRDT.LWWMap<String, Int>(replicaId: self.replicaB, defaultValue: 0)
        // ORSet `keys`: [(B,1): "foo"]
        // `values`: ["foo": 5]
        m2.set(forKey: "foo", value: 5) // (B,1)

        m1.merge(other: m2)

        guard let foo1 = m1["foo"] else {
            throw shouldNotHappen("Expect m1 to contain \"foo\", got \(m1)")
        }
        foo1.shouldEqual(5)

        m1.state._keys.elements.shouldEqual(["foo"])
        m1.state._keys.state.versionContext.vv[self.replicaA].shouldEqual(0)
        m1.state._keys.state.versionContext.vv[self.replicaB].shouldEqual(1)
        m1.state._keys.state.elementByBirthDot.count.shouldEqual(1)
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaB, 1)]!.shouldEqual("foo")

        // ORSet `keys`: [(A,1): "foo", (A,2): "bar"]
        // `values`: ["foo": 7, "bar": 6]
        // ORSet `keys`: [(B,3): "foo", (B,2): "bar"]
        // `values`: ["foo": 1, "bar": 3]
        m1.set(forKey: "foo", value: 7) // (A,1) replaces (B,1) because it's "newer"
        m2.set(forKey: "bar", value: 3) // (B,2)

        // Ensure the following changes are "newer"
        Thread.sleep(until: Date().addingTimeInterval(0.005))

        m1.set(forKey: "bar", value: 6) // (A,2)
        m2.set(forKey: "foo", value: 1) // (B,3) replaces (B,1)

        // ORSet `keys`: [(A,1): "foo", (A,2): "bar", (B,2): "bar", (B,3): "foo"]
        // `values`: ["foo": 1 ((B,3) wins), "bar": 6 ((A,2) wins)]
        m1.merge(other: m2)

        guard let foo2 = m1["foo"] else {
            throw shouldNotHappen("Expect m1 to contain \"foo\", got \(m1)")
        }
        foo2.shouldEqual(1)

        guard let bar2 = m1["bar"] else {
            throw shouldNotHappen("Expect m1 to contain \"bar\", got \(m1)")
        }
        bar2.shouldEqual(6)

        m1.state._keys.elements.shouldEqual(["foo", "bar"])
        m1.state._keys.state.versionContext.vv[self.replicaA].shouldEqual(2)
        m1.state._keys.state.versionContext.vv[self.replicaB].shouldEqual(3)
        m1.state._keys.state.elementByBirthDot.count.shouldEqual(4)
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaA, 1)]!.shouldEqual("foo")
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("bar")
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaB, 2)]!.shouldEqual("bar")
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaB, 3)]!.shouldEqual("foo")
    }

    func test_LWWMap_mergeDelta_shouldMutate() throws {
        var m1 = CRDT.LWWMap<String, Int>(replicaId: self.replicaA, defaultValue: 0)
        // ORSet `keys`: [(A,1): "foo", (A,2): "bar"]
        // `values`: ["foo": 8, "bar": 6]
        m1.set(forKey: "foo", value: 8) // (A,1)
        m1.set(forKey: "bar", value: 6) // (A,2)

        // Ensure the following changes are "newer"
        Thread.sleep(until: Date().addingTimeInterval(0.005))

        var m2 = CRDT.LWWMap<String, Int>(replicaId: self.replicaB, defaultValue: 0)
        // ORSet `keys`: [(B,1): "bar", (B,2): "baz"]
        // `values`: ["bar": 3, "baz": 5]
        m2.set(forKey: "bar", value: 3) // (B,1)
        m2.set(forKey: "baz", value: 5) // (B,2)

        guard let delta = m2.delta else {
            throw shouldNotHappen("m2.delta should not be nil after updates")
        }
        // ORSet `keys`: [(A,1): "foo", (A,2): "bar", (B,1): "bar", (B,2): "baz"]
        // `values`: ["foo": 8, "bar": 3, "baz": 5]
        m1.mergeDelta(delta) // m2 wins "bar"

        guard let foo = m1["foo"] else {
            throw shouldNotHappen("Expect m1 to contain \"foo\", got \(m1)")
        }
        foo.shouldEqual(8)

        guard let bar = m1["bar"] else {
            throw shouldNotHappen("Expect m1 to contain \"bar\", got \(m1)")
        }
        bar.shouldEqual(3)

        guard let baz = m1["baz"] else {
            throw shouldNotHappen("Expect m1 to contain \"baz\", got \(m1)")
        }
        baz.shouldEqual(5)

        m1.state._keys.elements.shouldEqual(["foo", "bar", "baz"])
        m1.state._keys.state.versionContext.vv[self.replicaA].shouldEqual(2)
        m1.state._keys.state.versionContext.vv[self.replicaB].shouldEqual(2)
        m1.state._keys.state.elementByBirthDot.count.shouldEqual(4)
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaA, 1)]!.shouldEqual("foo")
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaA, 2)]!.shouldEqual("bar")
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaB, 1)]!.shouldEqual("bar")
        m1.state._keys.state.elementByBirthDot[VersionDot(self.replicaB, 2)]!.shouldEqual("baz")
    }

    func test_LWWMap_resetValue_resetAllValues() throws {
        var m1 = CRDT.LWWMap<String, Int>(replicaId: self.replicaA, defaultValue: 0)
        m1.set(forKey: "foo", value: 2)
        m1.set(forKey: "bar", value: 6) // (A,2)

        guard let foo1 = m1["foo"] else {
            throw shouldNotHappen("Expect m1 to contain \"foo\", got \(m1)")
        }
        foo1.shouldEqual(2)

        guard let bar1 = m1["bar"] else {
            throw shouldNotHappen("Expect m1 to contain \"bar\", got \(m1)")
        }
        bar1.shouldEqual(6)

        m1.resetValue(forKey: "foo")

        guard let foo2 = m1["foo"] else {
            throw shouldNotHappen("Expect m1 to contain \"foo\", got \(m1)")
        }
        foo2.shouldEqual(0) // reset

        guard let bar2 = m1["bar"] else {
            throw shouldNotHappen("Expect m1 to contain \"bar\", got \(m1)")
        }
        bar2.shouldEqual(6) // no change

        m1.resetAllValues()

        guard let bar3 = m1["bar"] else {
            throw shouldNotHappen("Expect m1 to contain \"bar\", got \(m1)")
        }
        bar3.shouldEqual(0)
    }
}
