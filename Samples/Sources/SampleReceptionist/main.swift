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

let system = ActorSystem("Metrics") { settings in
    settings.cluster.enabled = true
}

enum HotelGuest {
    static var behavior: Behavior<String> = .setup { context in
        context.system.receptionist.register(<#T##ref: ActorRef<M>##DistributedActors.ActorRef<M>#>, key: <#T##RegistrationKey<M>##DistributedActors.Receptionist.RegistrationKey<M>#>)
    }
}

let props = Props().metrics(group: "talkers")

let t1 = try system.spawn("talker-1", props: props, Talker.talkTo(another: nil))
let t2 = try system.spawn("talker-2", props: props, Talker.talkTo(another: t1))
let t3 = try system.spawn("talker-3", props: props, Talker.talkTo(another: t2))
let t4 = try system.spawn("talker-4", props: props, Talker.talkTo(another: t3))

let m = try system.spawn("metricsPrinter", MetricPrinter.behavior)

for i in 1 ... 10 {
    _ = try system.spawn("life-\(i)", DieAfterSomeTime.behavior)
    Thread.sleep(.seconds(1))
}

Thread.sleep(.seconds(100))

system.shutdown().wait()
print("~~~~~~~~~~~~~~~ SHUTTING DOWN ~~~~~~~~~~~~~~~")
