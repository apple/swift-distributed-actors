//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsConcurrencyHelpers
import NIOConcurrencyHelpers

/// A checked continuation that offers easier APIs for working with cancellation,
/// as well as has its unique identity.
internal final class ClusterCancellableCheckedContinuation<Success>:
  Hashable, @unchecked Sendable where Success: Sendable {

  private struct _State: Sendable {
    var cancelled: Bool = false
    var onCancel: (@Sendable (ClusterCancellableCheckedContinuation<Success>) -> Void)?
    var continuation: CheckedContinuation<Success, any Error>?
  }

  private let state: NIOLockedValueBox<_State> = .init(_State())

  fileprivate init() {}

  func setContinuation(_ continuation: CheckedContinuation<Success, any Error>) -> Bool {
    var alreadyCancelled = false
    state.withLockedValue { state in
      if state.cancelled {
        alreadyCancelled = true
      } else {
        state.continuation = continuation
      }
    }
    if alreadyCancelled {
      continuation.resume(throwing: CancellationError())
    }
    return !alreadyCancelled
  }

  /// Register a cancellation handler, or call it immediately if the continuation was already cancelled.
  @Sendable
  func onCancel(handler: @Sendable @escaping (ClusterCancellableCheckedContinuation<Success>) -> Void) {
    var alreadyCancelled: Bool = state.withLockedValue { state in
      if state.cancelled {
        return true
      }

      state.onCancel = handler
      return false
    }
    if alreadyCancelled {
      handler(self)
    }
  }

  private func withContinuation(cancelled: Bool = false, _ operation: (CheckedContinuation<Success, any Error>) -> Void) {
    var safeContinuation: CheckedContinuation<Success, any Error>?
    var safeOnCancel: (@Sendable (ClusterCancellableCheckedContinuation<Success>) -> Void)?
    state.withLockedValue { (state: inout _State) -> Void in
      state.cancelled = state.cancelled || cancelled
      safeContinuation = state.continuation
      safeOnCancel = state.onCancel
      state.continuation = nil
      state.onCancel = nil
    }
    if let safeContinuation {
      operation(safeContinuation)
    }
    if cancelled {
      safeOnCancel?(self)
    }
  }

  func resume(returning value: Success) {
    withContinuation {
      $0.resume(returning: value)
    }
  }

  func resume(throwing error: any Error) {
    withContinuation {
      $0.resume(throwing: error)
    }
  }

  var isCancelled: Bool {
    state.withLockedValue { $0.cancelled }
  }

  func cancel() {
    withContinuation(cancelled: true) {
      $0.resume(throwing: CancellationError())
    }
  }
}

extension ClusterCancellableCheckedContinuation where Success == Void {
  func resume() {
    self.resume(returning: ())
  }
}
extension ClusterCancellableCheckedContinuation {
  static func == (lhs: ClusterCancellableCheckedContinuation, rhs: ClusterCancellableCheckedContinuation) -> Bool {
    return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
  }
  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}


func _withClusterCancellableCheckedContinuation<Success>(
  of successType: Success.Type = Success.self,
  _ body: @escaping (ClusterCancellableCheckedContinuation<Success>) -> Void,
  function: String = #function) async throws -> Success
    where Success: Sendable {
  let cccc = ClusterCancellableCheckedContinuation<Success>()
  return try await withTaskCancellationHandler {
    return try await withCheckedThrowingContinuation(function: function) { continuation in
      if cccc.setContinuation(continuation) {
        body(cccc)
      }
    }
  } onCancel: {
    cccc.cancel()
  }
}