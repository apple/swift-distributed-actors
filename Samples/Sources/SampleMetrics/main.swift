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

import Metrics
import Prometheus
// import StatsdClient

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Prometheus backend

let prom = PrometheusClient()
MetricsSystem.bootstrap(prom)

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: StatsD backend
//
//      pip install pystatsd
//      python -c 'import pystatsd; pystatsd.Server(debug=True).serve()'

// let statsdClient = try StatsdClient(host: "localhost", port: 8125)
// MetricsSystem.bootstrap(statsdClient)

// start actor system
let system = ActorSystem("Metrics") { settings in
    settings.cluster.enabled = true
}

struct Talker {
    enum Message {
        case hello(Int, replyTo: ActorRef<Talker.Message>?)
    }

    static func talkTo(another talker: ActorRef<Message>?) -> Behavior<Message> {
        .setup { context in
            context.log.info("Started \(context.myself.path)")
            context.timers.startPeriodic(key: "next-chat", message: .hello(1, replyTo: talker), interval: .milliseconds(200))

            return .receiveMessage { message in
                // context.log.info("\(message)")

                switch message {
                case .hello(_, let talkTo):
                    talkTo?.tell(.hello(1, replyTo: talkTo))
                }
                return .same
            }
        }
    }
}

struct DieAfterSomeTime {
    static let behavior = Behavior<String>.setup { context in
        context.log.info("Started \(context.myself.path)")
        context.timers.startSingle(key: "die", message: "time-up", delay: .seconds(2))
        return .receiveMessage { _ in
            context.log.info("Stopping \(context.myself.path)...")
            return .stop
        }
    }
}

struct MetricPrinter {
    static var behavior: Behavior<String> {
        .setup { context in
            context.log.info("Started \(context.myself.path)")
            context.timers.startPeriodic(key: "print-metrics", message: "print", interval: .seconds(2))

            return .receiveMessage { _ in
                print("------------------------------------------------------------------------------------------")
                prom.collect { (stringRepr: String) in
                    print(stringRepr)
                }

                return .same
            }
        }
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
