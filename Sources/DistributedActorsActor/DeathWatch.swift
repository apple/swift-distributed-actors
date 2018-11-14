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

import NIO
import Dispatch

// MARK: Death watch implementation

/// DeathWatch implementation.
/// An [[ActorCell]] owns a death watch instance and is responsible of managing all calls to it.
//
// Implementation notes:
// Care was taken to keep this implementation separate from the ActorCell however not require more storage space.
internal struct DeathWatch<Message> { // TODO make a protocol

  private var watching = Set<BoxedHashableAnyReceivesSignals>()
  private var watchedBy = Set<BoxedHashableAnyReceivesSignals>()

  // MARK: perform watch/unwatch
  
  /// Performed by the sending side of "watch", the watchee should equal "context.myself"
  public mutating func watch<M>(watchee: ActorRef<M>, myself watcher: ActorRef<Message>) {
    pprint("watch: \(watchee) (by \(watcher))")
    // watching ourselves is a no-op, since we would never be able to observe the Terminated message anyway:
    guard watchee.path != watcher.path else { return () }

    let watcheeWithCell = watchee.internal_downcast

    // watching is idempotent, and an once-watched ref needs not be watched again
    let boxedWatchee = BoxedHashableAnyReceivesSignals(ref: watcheeWithCell)
    guard !watching.contains(boxedWatchee) else { return () }

    watcheeWithCell.sendSystemMessage(.watch(from: BoxedHashableAnyReceivesSignals(watcher)))
    watching.insert(boxedWatchee)
    subscribeAddressTerminatedEvents()
  }
  public mutating func unwatch(watchee: AnyAddressableActorRef) {
    return TODO("NOT IMPLEMENTED YET")
  }

  // MARK: react to watch or unwatch signals

  public mutating func becomeWatchedBy(watcher: AnyReceivesSignals, myself: ActorRef<Message>) {
    pprint("become watched by: \(watcher.path)     inside: \(myself)")
    let boxedWatcher = watcher.internal_exposeBox()
    self.watchedBy.insert(boxedWatcher)
  }
  public mutating func removeWatchedBy(watcher: AnyReceivesSignals, myself: ActorRef<Message>) {
    pprint("remove watched by: \(watcher.path)     inside: \(myself)")

  }

  /// Performs cleanup of references to the dead actor.
  ///
  /// Requires: passed in argument to be a `.terminated`.
  public mutating func receiveTerminated(_ terminated: SystemMessage) {
    guard case let .terminated(deadActorRef, _) = terminated else {
      fatalError("receiveTerminated most only be invoked with .terminated")
    }

    let deadPath = deadActorRef.path
    let pathsEqual: (BoxedHashableAnyReceivesSignals) -> Bool = { watched in watched.path == deadPath }
    func removeDeadRef(from set: inout Set<BoxedHashableAnyReceivesSignals>, `where` check: (BoxedHashableAnyReceivesSignals) -> Bool) {
      if let deadIndex = set.firstIndex(where: check) {
        set.remove(at: deadIndex)
      }
    }


    // remove the dead actor from the set that we were watching:

    // FIXME make this better so it can utilize the hashcode, since it WILL be the same as the boxed thing even if types are not
    var fromSet: Set<BoxedHashableAnyReceivesSignals> = self.watching

    removeDeadRef(from: &fromSet, where: pathsEqual)

    // remove the dead actor from the set that was watching us, no need to notify dead actors about our death:
    var fromSet2: Set<BoxedHashableAnyReceivesSignals> = self.watchedBy
    if let deadIndex = fromSet2.firstIndex(where: pathsEqual) {
      fromSet2.remove(at: deadIndex)
    }
  }

  // MARK: termination tasks

  func notifyWatchersWeDied(myself: ActorRef<Message>) {
    for watcher in watchedBy {
      // TODO reasons need to be thought through...
      let figureOutHowToUseReasons = "natural death"
      watcher.sendSystemMessage(.terminated(ref: BoxedHashableAnyAddressableActorRef(myself), reason: figureOutHowToUseReasons))
    }
  }

  // MARK: helper methods and state management

  // TODO implement this once we are clustered; a termination of an entire node means termination of all actors on that node
  private func subscribeAddressTerminatedEvents() {}

}
