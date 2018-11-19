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
@usableFromInline internal struct DeathWatch<Message> { // TODO make a protocol

  private var watching = Set<BoxedHashableAnyReceivesSignals>()
  private var watchedBy = Set<BoxedHashableAnyReceivesSignals>()

  // MARK: perform watch/unwatch
  
  /// Performed by the sending side of "watch", therefore the `watcher` should equal `context.myself`
  public mutating func watch<M>(watchee: ActorRef<M>, myself watcher: ActorRef<Message>) {
    pprint("watch: \(watchee) (from \(watcher) (myself))")
    // watching ourselves is a no-op, since we would never be able to observe the Terminated message anyway:
    guard watchee.path != watcher.path else { return () }

    let watcheeWithCell = watchee.internal_downcast

    // watching is idempotent, and an once-watched ref needs not be watched again
    let boxedWatchee = BoxedHashableAnyReceivesSignals(ref: watcheeWithCell)
    guard !watching.contains(boxedWatchee) else { return () }

    watcheeWithCell.sendSystemMessage(.watch(from: watcher.internal_boxAnyReceivesSignals()))
    watching.insert(boxedWatchee)
    subscribeAddressTerminatedEvents()
  }

  /// Performed by the sending side of "unwatch", the watchee should equal "context.myself"
  public mutating func unwatch(watchee: AnyReceivesSignals, myself watcher: ActorRef<Message>) {
    pprint("unwatch: watchee: \(watchee) (from \(watcher) myself)")
    // we could short circuit "if watchee == myself return" but it's not really worth checking since no-op anyway
    let boxedWatchee: BoxedHashableAnyReceivesSignals = watchee.internal_exposeBox()
    if let removed = watching.remove(boxedWatchee) {
      removed.sendSystemMessage(.unwatch(from: watcher.internal_boxAnyReceivesSignals()))
    }
  }

  // MARK: react to watch or unwatch signals

  public mutating func becomeWatchedBy(watcher: AnyReceivesSignals, myself: ActorRef<Message>) {
    guard watcher.path != myself.path else {
      // TODO log warning
      pprint("Attempted to watch 'myself' [\(myself)], which is a no-op, since such watch's terminated can never be observed. " +
          "Likely a programming error where the wrong actor ref was passed to watch(), please check your code.")
      return
    }

    pprint("become watched by: \(watcher.path)     inside: \(myself)")
    let boxedWatcher = watcher.internal_exposeBox()
    self.watchedBy.insert(boxedWatcher)
  }
  public mutating func removeWatchedBy(watcher: AnyReceivesSignals, myself: ActorRef<Message>) {
    pprint("remove watched by: \(watcher.path)     inside: \(myself)")
    let boxedWatcher = watcher.internal_exposeBox()
    self.watchedBy.remove(boxedWatcher)
  }

  /// Performs cleanup of references to the dead actor.
  ///
  /// Requires: passed in argument to be a `.terminated`.
  ///
  /// Returns: `true` if the termination was concerning a currently watched actor, false otherwise.
  public mutating func receiveTerminated(_ terminated: SystemMessage) -> Bool {
    guard case let .terminated(deadActorRef) = terminated else { // TODO hope this optimizes away nicely when inlined etc
      fatalError("receiveTerminated most only be invoked with .terminated")
    }

    let deadPath = deadActorRef.path
    let pathsEqual: (BoxedHashableAnyReceivesSignals) -> Bool = { watched in watched.path == deadPath }
    // FIXME make this better so it can utilize the hashcode, since it WILL be the same as the boxed thing even if types are not
    func removeDeadRef(from set: inout Set<BoxedHashableAnyReceivesSignals>, `where` check: (BoxedHashableAnyReceivesSignals) -> Bool) -> Bool {
      if let deadIndex = set.firstIndex(where: check) {
        set.remove(at: deadIndex)
        return true
      }
      return false
    }

    // we remove the actor from both sets;
    // - we don't need to watch it anymore, since it has just terminated,
    // - we don't need to refer to it, since sending it .terminated notifications would be pointless.
    guard removeDeadRef(from: &self.watching, where: pathsEqual) &&
          removeDeadRef(from: &self.watchedBy, where: pathsEqual) else {
      // seems we don't know this actor at all, which means that no actions should be taken in response to this .terminated.
      // It should NOT be delivered to user code, nor should Death Pact termination be triggered.
      return false
    }

    // we knew this actor, and have successfully removed it from our sets,
    // the ActorCell should take appropriate signal handling actions now.
    return true
  }

  // MARK: termination tasks

  func notifyWatchersWeDied(myself: ActorRef<Message>) {
    pprint("\(myself) IS WATCHED BY \(watchedBy) AND IS DYING :::::::")
    for watcher in watchedBy {
      pprint("Notify \(watcher) that we died... :::: myself: \(myself)")
      watcher.sendSystemMessage(.terminated(ref: BoxedHashableAnyAddressableActorRef(myself)))
    }
  }

  // MARK: helper methods and state management

  // TODO implement this once we are clustered; a termination of an entire node means termination of all actors on that node
  private func subscribeAddressTerminatedEvents() {}

}


public enum DeathPactError: Error {
  case unhandledDeathPact(terminated: AnyAddressableActorRef, myself: AnyAddressableActorRef, message: String)
}
