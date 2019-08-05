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

internal final class PollingParentMonitoringFailureDetector {
    public static let name: ActorNaming = "processFailureDetector"
    public enum Message {
        case checkOnParent
    }

    private var timerKey: TimerKey {
        return "monitor-parent-pid-\(self.parentPID)"
    }

    // Parent:
    private let parentNode: UniqueNode
    private let parentPID: Int

    public init(parentNode: UniqueNode, parentPID: Int) {
        self.parentNode = parentNode
        self.parentPID = parentPID
    }

    var behavior: Behavior<Message> {
        return .setup { context in
            let interval = TimeAmount.seconds(1) // TODO: settings
            context.timers.startPeriodic(key: self.timerKey , message: .checkOnParent, interval: interval)
            return self.monitoring
        }
    }
    internal var monitoring: Behavior<Message> {
        return .receive { context, message in
            switch message {
            case .checkOnParent:
                guard self.parentPID == POSIXProcessUtils.getParentPID() else {
                    context.log.error("""
                                      Parent process [\(self.parentPID)] has terminated! \
                                      Servant process MUST NOT remain alive with master process terminated: EXITING. 
                                      """)

                    // we crash hard; since we are running in process managed mode, death of parent
                    // means that we should ASAP exit workers as well; in this model we assume that the
                    // master should not fail and if it did, something very bad has happened (or it was
                    // manually killed, ant that also means its servants should die with it).
                    POSIXProcessUtils._exit(-1)
                    fatalError()
                }
            }
            return .same
        }
    }

}
