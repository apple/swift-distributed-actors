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

import CAtomics

public enum MemoryOrder {
    case relaxed
    case consume
    case acquire
    case release
    case acq_rel
    case seq_cst
}

internal extension MemoryOrder {
    @usableFromInline
    var to_C_memory_order: memory_order {
        switch self {
        case .relaxed: return memory_order_relaxed
        case .consume: return memory_order_consume
        case .acquire: return memory_order_acquire
        case .release: return memory_order_release
        case .acq_rel: return memory_order_acq_rel
        case .seq_cst: return memory_order_seq_cst
        }
    }
}

/// An atomic primitive object.
///
/// Before using `UnsafeEmbeddedAtomic`, please consider whether your needs can be met by `Atomic` instead.
/// `UnsafeEmbeddedAtomic` is a value type, but atomics are heap-allocated. Thus, it is only safe to
/// use `UnsafeEmbeddedAtomic` in situations where the atomic can be guaranteed to be cleaned up (via calling `destroy`).
/// If you cannot make these guarantees, use `Atomic` instead, which manages this for you.
///
/// Atomic objects support a wide range of atomic operations:
///
/// - Compare and swap
/// - Add
/// - Subtract
/// - Exchange
/// - Load current value
/// - Store current value
///
/// Atomic primitives are useful when building constructs that need to
/// communicate or cooperate across multiple threads. In the case of
/// SwiftNIO this usually involves communicating across multiple event loops.
public struct UnsafeEmbeddedAtomic<T: AtomicPrimitive> {
    @usableFromInline
    internal let value: OpaquePointer

    /// Create an atomic object with `value`.
    @inlinable
    public init(value: T) {
        self.value = T.atomic_create(value)
    }

    /// Atomically compares the value against `expected` and, if they are equal,
    /// replaces the value with `desired`.
    ///
    /// This implementation conforms to C11's `atomic_compare_exchange_strong`. This
    /// means that the compare-and-swap will always succeed if `expected` is equal to
    /// value. For more details on atomic memory models, check the documentation
    /// for C11's `stdatomic.h`.
    ///
    /// - Parameters:
    ///   - expected: The value that this object must currently hold for the
    ///     compare-and-swap to succeed.
    ///   - desired: The new value that this object will hold if the compare
    ///     succeeds.
    ///   - order: Memory order for this operation
    /// - Returns: `True` if the exchange occurred, or `False` if `expected` did not
    ///     match the current value and so no exchange occurred.
    @inlinable
    public func compareAndExchange(expected: T, desired: T, succ: MemoryOrder = .seq_cst, fail: MemoryOrder = .seq_cst) -> Bool {
        return T.atomic_compare_and_exchange(self.value, expected, desired, succ.to_C_memory_order, fail.to_C_memory_order)
    }

    /// Atomically compares the value against `expected` and, if they are equal,
    /// replaces the value with `desired`.
    ///
    /// This implementation conforms to C11's `atomic_compare_exchange_weak`. This
    /// means that the compare-and-swap will not always succeed if `expected` is equal to
    /// value. For more details on atomic memory models, check the documentation
    /// for C11's `stdatomic.h`.
    ///
    /// - Parameters:
    ///   - expected: The value that this object must currently hold for the
    ///     compare-and-swap to succeed.
    ///   - desired: The new value that this object will hold if the compare
    ///     succeeds.
    ///   - order: Memory order for this operation
    /// - Returns: `True` if the exchange occurred, or `False` if `expected` did not
    ///     match the current value and so no exchange occurred.
    @inlinable
    public func compareAndExchangeWeak(expected: T, desired: T, succ: MemoryOrder = .seq_cst, fail: MemoryOrder = .seq_cst) -> Bool {
        return T.atomic_compare_and_exchange_weak(self.value, expected, desired, succ.to_C_memory_order, fail.to_C_memory_order)
    }

    /// Atomically adds `rhs` to this object.
    ///
    /// - Parameters:
    ///   - rhs: The value to add to this object.
    ///   - order: Memory order for this operation
    /// - Returns: The previous value of this object, before the addition occurred.
    @inlinable
    public func add(_ rhs: T, order: MemoryOrder = .seq_cst) -> T {
        return T.atomic_add(self.value, rhs, order.to_C_memory_order)
    }

    /// Atomically subtracts `rhs` from this object.
    ///
    /// - Parameters:
    ///   - rhs: The value to subtract from this object.
    ///   - order: Memory order for this operation
    /// - Returns: The previous value of this object, before the subtraction occurred.
    @inlinable
    public func sub(_ rhs: T, order: MemoryOrder = .seq_cst) -> T {
        return T.atomic_sub(self.value, rhs, order.to_C_memory_order)
    }

    /// Atomically execute a bitwise `and` with `rhs` on this object.
    ///
    /// - Parameters:
    ///   - rhs: The value to `and` this object with.
    ///   - order: Memory order for this operation
    /// - Returns: The previous value of this object, before the `and` occurred.
    @inlinable
    public func and(_ rhs: T, order: MemoryOrder = .seq_cst) -> T {
        return T.atomic_and(self.value, rhs, order.to_C_memory_order)
    }

    /// Atomically execute a bitwise `or` with `rhs` on this object.
    ///
    /// - Parameters:
    ///   - rhs: The value to `or` this object with.
    ///   - order: Memory order for this operation
    /// - Returns: The previous value of this object, before the `or` occurred.
    @inlinable
    public func or(_ rhs: T, order: MemoryOrder = .seq_cst) -> T {
        return T.atomic_or(self.value, rhs, order.to_C_memory_order)
    }

    /// Atomically execute a bitwise `xor` with `rhs` on this object.
    ///
    /// - Parameter rhs: The value to `xor` this object with.
    /// - Returns: The previous value of this object, before the `xor` occurred.
    @inlinable
    public func xor(_ rhs: T, order: MemoryOrder = .seq_cst) -> T {
        return T.atomic_xor(self.value, rhs, order.to_C_memory_order)
    }

    /// Atomically exchanges `value` for the current value of this object.
    ///
    /// - Parameters:
    ///   - value: The new value to set this object to.
    ///   - order: Memory order for this operation
    /// - Returns: The value previously held by this object.
    @inlinable
    public func exchange(with value: T, order: MemoryOrder = .seq_cst) -> T {
        return T.atomic_exchange(self.value, value, order.to_C_memory_order)
    }

    /// Atomically loads and returns the value of this object.
    ///
    /// - Parameter order: Memory order for this operation:
    /// - Returns: The value of this object
    @inlinable
    public func load(order: MemoryOrder = .seq_cst) -> T {
        return T.atomic_load(self.value, order.to_C_memory_order)
    }

    /// Atomically replaces the value of this object with `value`.
    ///
    /// - Parameters:
    ///   - value: The new value to set the object to.
    ///   - order: Memory order for this operation
    @inlinable
    public func store(_ value: T, order: MemoryOrder = .seq_cst) -> Void {
        T.atomic_store(self.value, value, order.to_C_memory_order)
    }

    /// Destroy the atomic value.
    ///
    /// This method is the source of the unsafety of this structure. This *must* be called, or you will leak memory with each
    /// atomic.
    public func destroy() {
        T.atomic_destroy(self.value)
    }
}

/// An encapsulation of an atomic primitive object.
///
/// Atomic objects support a wide range of atomic operations:
///
/// - Compare and swap
/// - Add
/// - Subtract
/// - Exchange
/// - Load current value
/// - Store current value
///
/// Atomic primitives are useful when building constructs that need to
/// communicate or cooperate across multiple threads. In the case of
/// SwiftNIO this usually involves communicating across multiple event loops.
///
/// By necessity, all atomic values are references: after all, it makes no
/// sense to talk about managing an atomic value when each time it's modified
/// the thread that modified it gets a local copy!
public final class Atomic<T: AtomicPrimitive> {
    @usableFromInline
    internal let embedded: UnsafeEmbeddedAtomic<T>

    /// Create an atomic object with `value`.
    @inlinable
    public init(value: T) {
        self.embedded = UnsafeEmbeddedAtomic(value: value)
    }

    /// Atomically compares the value against `expected` and, if they are equal,
    /// replaces the value with `desired`.
    ///
    /// This implementation conforms to C11's `atomic_compare_exchange_strong`. This
    /// means that the compare-and-swap will always succeed if `expected` is equal to
    /// value. For more details on atomic memory models, check the documentation
    /// for C11's `stdatomic.h`.
    ///
    /// - Parameters:
    ///   - expected: The value that this object must currently hold for the
    ///     compare-and-swap to succeed.
    ///   - desired: The new value that this object will hold if the compare
    ///     succeeds.
    ///   - order: Memory order for this operation
    /// - Returns: `True` if the exchange occurred, or `False` if `expected` did not
    ///     match the current value and so no exchange occurred.
    @inlinable
    public func compareAndExchange(expected: T, desired: T) -> Bool {
        return self.embedded.compareAndExchange(expected: expected, desired: desired)
    }

    /// Atomically compares the value against `expected` and, if they are equal,
    /// replaces the value with `desired`.
    ///
    /// This implementation conforms to C11's `atomic_compare_exchange_weak`. This
    /// means that the compare-and-swap will not always succeed if `expected` is equal to
    /// value. For more details on atomic memory models, check the documentation
    /// for C11's `stdatomic.h`.
    ///
    /// - Parameters:
    ///   - expected: The value that this object must currently hold for the
    ///     compare-and-swap to succeed.
    ///   - desired: The new value that this object will hold if the compare
    ///     succeeds.
    ///   - order: Memory order for this operation
    /// - Returns: `True` if the exchange occurred, or `False` if `expected` did not
    ///     match the current value and so no exchange occurred.
    @inlinable
    public func compareAndExchangeWeak(expected: T, desired: T, succ: MemoryOrder = .seq_cst, fail: MemoryOrder = .seq_cst) -> Bool {
        return self.embedded.compareAndExchangeWeak(expected: expected, desired: desired, succ: succ, fail: fail)
    }

    /// Atomically adds `rhs` to this object.
    ///
    /// - Parameters:
    ///   - rhs: The value to add to this object.
    ///   - order: Memory order for this operation
    /// - Returns: The previous value of this object, before the addition occurred.
    @inlinable
    public func add(_ rhs: T, order: MemoryOrder = .seq_cst) -> T {
        return self.embedded.add(rhs, order: order)
    }

    /// Atomically subtracts `rhs` from this object.
    ///
    /// - Parameters:
    ///   - rhs: The value to subtract from this object.
    ///   - order: Memory order for this operation
    /// - Returns: The previous value of this object, before the subtraction occurred.
    @inlinable
    public func sub(_ rhs: T, order: MemoryOrder = .seq_cst) -> T {
        return self.embedded.sub(rhs, order: order)
    }

    /// Atomically execute a bitwise `and` with `rhs` on this object.
    ///
    /// - Parameters:
    ///   - rhs: The value to `and` this object with.
    ///   - order: Memory order for this operation
    /// - Returns: The previous value of this object, before the `and` occurred.
    @inlinable
    public func and(_ rhs: T, order: MemoryOrder = .seq_cst) -> T {
        return self.embedded.and(rhs, order: order)
    }

    /// Atomically execute a bitwise `or` with `rhs` on this object.
    ///
    /// - Parameters:
    ///   - rhs: The value to `or` this object with.
    ///   - order: Memory order for this operation
    /// - Returns: The previous value of this object, before the `or` occurred.
    @inlinable
    public func or(_ rhs: T, order: MemoryOrder = .seq_cst) -> T {
        return self.embedded.or(rhs, order: order)
    }

    /// Atomically execute a bitwise `xor` with `rhs` on this object.
    ///
    /// - Parameter rhs: The value to `xor` this object with.
    /// - Returns: The previous value of this object, before the `xor` occurred.
    @inlinable
    public func xor(_ rhs: T, order: MemoryOrder = .seq_cst) -> T {
        return self.embedded.xor(rhs, order: order)
    }

    /// Atomically exchanges `value` for the current value of this object.
    ///
    /// - Parameters:
    ///   - value: The new value to set this object to.
    ///   - order: Memory order for this operation
    /// - Returns: The value previously held by this object.
    @inlinable
    public func exchange(with value: T, order: MemoryOrder = .seq_cst) -> T {
        return self.embedded.exchange(with: value, order: order)
    }

    /// Atomically loads and returns the value of this object.
    ///
    /// - Parameter order: Memory order for this operation:
    /// - Returns: The value of this object
    @inlinable
    public func load(order: MemoryOrder = .seq_cst) -> T {
        return self.embedded.load(order: order)
    }

    /// Atomically replaces the value of this object with `value`.
    ///
    /// - Parameters:
    ///   - value: The new value to set the object to.
    ///   - order: Memory order for this operation
    @inlinable
    public func store(_ value: T, order: MemoryOrder = .seq_cst) -> Void {
        self.embedded.store(value, order: order)
    }

    deinit {
        self.embedded.destroy()
    }
}

/// The protocol that all types that can be made atomic must conform to.
///
/// **Do not add conformance to this protocol for arbitrary types**. Only a small range
/// of types have appropriate atomic operations supported by the CPU, and those types
/// already have conformances implemented.
public protocol AtomicPrimitive {
    static var atomic_create: (Self) -> OpaquePointer { get }
    static var atomic_destroy: (OpaquePointer) -> Void { get }
    static var atomic_compare_and_exchange: (OpaquePointer, Self, Self, memory_order, memory_order) -> Bool { get }
    static var atomic_compare_and_exchange_weak: (OpaquePointer, Self, Self, memory_order, memory_order) -> Bool { get }
    static var atomic_add: (OpaquePointer, Self, memory_order) -> Self { get }
    static var atomic_sub: (OpaquePointer, Self, memory_order) -> Self { get }
    static var atomic_and: (OpaquePointer, Self, memory_order) -> Self { get }
    static var atomic_or: (OpaquePointer, Self, memory_order) -> Self { get }
    static var atomic_xor: (OpaquePointer, Self, memory_order) -> Self { get }
    static var atomic_exchange: (OpaquePointer, Self, memory_order) -> Self { get }
    static var atomic_load: (OpaquePointer, memory_order) -> Self { get }
    static var atomic_store: (OpaquePointer, Self, memory_order) -> Void { get }
}

extension Bool: AtomicPrimitive {
    public static let atomic_create                     = __catmc_atomic__Bool_create
    public static let atomic_destroy                    = __catmc_atomic__Bool_destroy
    public static let atomic_compare_and_exchange       = __catmc_atomic__Bool_compare_and_exchange_strong
    public static let atomic_compare_and_exchange_weak  = __catmc_atomic__Bool_compare_and_exchange_weak
    public static let atomic_add                        = __catmc_atomic__Bool_add
    public static let atomic_sub                        = __catmc_atomic__Bool_sub
    public static let atomic_and                        = __catmc_atomic__Bool_and
    public static let atomic_or                         = __catmc_atomic__Bool_or
    public static let atomic_xor                        = __catmc_atomic__Bool_xor
    public static let atomic_exchange                   = __catmc_atomic__Bool_exchange
    public static let atomic_load                       = __catmc_atomic__Bool_load
    public static let atomic_store                      = __catmc_atomic__Bool_store
}

extension Int8: AtomicPrimitive {
    public static let atomic_create                     = __catmc_atomic_int_least8_t_create
    public static let atomic_destroy                    = __catmc_atomic_int_least8_t_destroy
    public static let atomic_compare_and_exchange       = __catmc_atomic_int_least8_t_compare_and_exchange_strong
    public static let atomic_compare_and_exchange_weak  = __catmc_atomic_int_least8_t_compare_and_exchange_weak
    public static let atomic_add                        = __catmc_atomic_int_least8_t_add
    public static let atomic_sub                        = __catmc_atomic_int_least8_t_sub
    public static let atomic_and                        = __catmc_atomic_int_least8_t_and
    public static let atomic_or                         = __catmc_atomic_int_least8_t_or
    public static let atomic_xor                        = __catmc_atomic_int_least8_t_xor
    public static let atomic_exchange                   = __catmc_atomic_int_least8_t_exchange
    public static let atomic_load                       = __catmc_atomic_int_least8_t_load
    public static let atomic_store                      = __catmc_atomic_int_least8_t_store
}

extension UInt8: AtomicPrimitive {
    public static let atomic_create                     = __catmc_atomic_uint_least8_t_create
    public static let atomic_destroy                    = __catmc_atomic_uint_least8_t_destroy
    public static let atomic_compare_and_exchange       = __catmc_atomic_uint_least8_t_compare_and_exchange_strong
    public static let atomic_compare_and_exchange_weak  = __catmc_atomic_uint_least8_t_compare_and_exchange_weak
    public static let atomic_add                        = __catmc_atomic_uint_least8_t_add
    public static let atomic_sub                        = __catmc_atomic_uint_least8_t_sub
    public static let atomic_and                        = __catmc_atomic_uint_least8_t_and
    public static let atomic_or                         = __catmc_atomic_uint_least8_t_or
    public static let atomic_xor                        = __catmc_atomic_uint_least8_t_xor
    public static let atomic_exchange                   = __catmc_atomic_uint_least8_t_exchange
    public static let atomic_load                       = __catmc_atomic_uint_least8_t_load
    public static let atomic_store                      = __catmc_atomic_uint_least8_t_store
}

extension Int16: AtomicPrimitive {
    public static let atomic_create                     = __catmc_atomic_int_least16_t_create
    public static let atomic_destroy                    = __catmc_atomic_int_least16_t_destroy
    public static let atomic_compare_and_exchange       = __catmc_atomic_int_least16_t_compare_and_exchange_strong
    public static let atomic_compare_and_exchange_weak  = __catmc_atomic_int_least16_t_compare_and_exchange_weak
    public static let atomic_add                        = __catmc_atomic_int_least16_t_add
    public static let atomic_sub                        = __catmc_atomic_int_least16_t_sub
    public static let atomic_and                        = __catmc_atomic_int_least16_t_and
    public static let atomic_or                         = __catmc_atomic_int_least16_t_or
    public static let atomic_xor                        = __catmc_atomic_int_least16_t_xor
    public static let atomic_exchange                   = __catmc_atomic_int_least16_t_exchange
    public static let atomic_load                       = __catmc_atomic_int_least16_t_load
    public static let atomic_store                      = __catmc_atomic_int_least16_t_store
}

extension UInt16: AtomicPrimitive {
    public static let atomic_create                     = __catmc_atomic_uint_least16_t_create
    public static let atomic_destroy                    = __catmc_atomic_uint_least16_t_destroy
    public static let atomic_compare_and_exchange       = __catmc_atomic_uint_least16_t_compare_and_exchange_strong
    public static let atomic_compare_and_exchange_weak  = __catmc_atomic_uint_least16_t_compare_and_exchange_weak
    public static let atomic_add                        = __catmc_atomic_uint_least16_t_add
    public static let atomic_sub                        = __catmc_atomic_uint_least16_t_sub
    public static let atomic_and                        = __catmc_atomic_uint_least16_t_and
    public static let atomic_or                         = __catmc_atomic_uint_least16_t_or
    public static let atomic_xor                        = __catmc_atomic_uint_least16_t_xor
    public static let atomic_exchange                   = __catmc_atomic_uint_least16_t_exchange
    public static let atomic_load                       = __catmc_atomic_uint_least16_t_load
    public static let atomic_store                      = __catmc_atomic_uint_least16_t_store
}

extension Int32: AtomicPrimitive {
    public static let atomic_create                     = __catmc_atomic_int_least32_t_create
    public static let atomic_destroy                    = __catmc_atomic_int_least32_t_destroy
    public static let atomic_compare_and_exchange       = __catmc_atomic_int_least32_t_compare_and_exchange_strong
    public static let atomic_compare_and_exchange_weak  = __catmc_atomic_int_least32_t_compare_and_exchange_weak
    public static let atomic_add                        = __catmc_atomic_int_least32_t_add
    public static let atomic_sub                        = __catmc_atomic_int_least32_t_sub
    public static let atomic_and                        = __catmc_atomic_int_least32_t_and
    public static let atomic_or                         = __catmc_atomic_int_least32_t_or
    public static let atomic_xor                        = __catmc_atomic_int_least32_t_xor
    public static let atomic_exchange                   = __catmc_atomic_int_least32_t_exchange
    public static let atomic_load                       = __catmc_atomic_int_least32_t_load
    public static let atomic_store                      = __catmc_atomic_int_least32_t_store
}

extension UInt32: AtomicPrimitive {
    public static let atomic_create                     = __catmc_atomic_uint_least32_t_create
    public static let atomic_destroy                    = __catmc_atomic_uint_least32_t_destroy
    public static let atomic_compare_and_exchange       = __catmc_atomic_uint_least32_t_compare_and_exchange_strong
    public static let atomic_compare_and_exchange_weak  = __catmc_atomic_uint_least32_t_compare_and_exchange_weak
    public static let atomic_add                        = __catmc_atomic_uint_least32_t_add
    public static let atomic_sub                        = __catmc_atomic_uint_least32_t_sub
    public static let atomic_and                        = __catmc_atomic_uint_least32_t_and
    public static let atomic_or                         = __catmc_atomic_uint_least32_t_or
    public static let atomic_xor                        = __catmc_atomic_uint_least32_t_xor
    public static let atomic_exchange                   = __catmc_atomic_uint_least32_t_exchange
    public static let atomic_load                       = __catmc_atomic_uint_least32_t_load
    public static let atomic_store                      = __catmc_atomic_uint_least32_t_store
}

extension Int64: AtomicPrimitive {
    public static let atomic_create                     = __catmc_atomic_long_long_create
    public static let atomic_destroy                    = __catmc_atomic_long_long_destroy
    public static let atomic_compare_and_exchange       = __catmc_atomic_long_long_compare_and_exchange_strong
    public static let atomic_compare_and_exchange_weak  = __catmc_atomic_long_long_compare_and_exchange_weak
    public static let atomic_add                        = __catmc_atomic_long_long_add
    public static let atomic_sub                        = __catmc_atomic_long_long_sub
    public static let atomic_and                        = __catmc_atomic_long_long_and
    public static let atomic_or                         = __catmc_atomic_long_long_or
    public static let atomic_xor                        = __catmc_atomic_long_long_xor
    public static let atomic_exchange                   = __catmc_atomic_long_long_exchange
    public static let atomic_load                       = __catmc_atomic_long_long_load
    public static let atomic_store                      = __catmc_atomic_long_long_store
}

extension UInt64: AtomicPrimitive {
    public static let atomic_create                     = __catmc_atomic_unsigned_long_long_create
    public static let atomic_destroy                    = __catmc_atomic_unsigned_long_long_destroy
    public static let atomic_compare_and_exchange       = __catmc_atomic_unsigned_long_long_compare_and_exchange_strong
    public static let atomic_compare_and_exchange_weak  = __catmc_atomic_unsigned_long_long_compare_and_exchange_weak
    public static let atomic_add                        = __catmc_atomic_unsigned_long_long_add
    public static let atomic_sub                        = __catmc_atomic_unsigned_long_long_sub
    public static let atomic_and                        = __catmc_atomic_unsigned_long_long_and
    public static let atomic_or                         = __catmc_atomic_unsigned_long_long_or
    public static let atomic_xor                        = __catmc_atomic_unsigned_long_long_xor
    public static let atomic_exchange                   = __catmc_atomic_unsigned_long_long_exchange
    public static let atomic_load                       = __catmc_atomic_unsigned_long_long_load
    public static let atomic_store                      = __catmc_atomic_unsigned_long_long_store
}

extension Int: AtomicPrimitive {
    public static let atomic_create                     = __catmc_atomic_long_create
    public static let atomic_destroy                    = __catmc_atomic_long_destroy
    public static let atomic_compare_and_exchange       = __catmc_atomic_long_compare_and_exchange_strong
    public static let atomic_compare_and_exchange_weak  = __catmc_atomic_long_compare_and_exchange_weak
    public static let atomic_add                        = __catmc_atomic_long_add
    public static let atomic_sub                        = __catmc_atomic_long_sub
    public static let atomic_and                        = __catmc_atomic_long_and
    public static let atomic_or                         = __catmc_atomic_long_or
    public static let atomic_xor                        = __catmc_atomic_long_xor
    public static let atomic_exchange                   = __catmc_atomic_long_exchange
    public static let atomic_load                       = __catmc_atomic_long_load
    public static let atomic_store                      = __catmc_atomic_long_store
}

extension UInt: AtomicPrimitive {
    public static let atomic_create                     = __catmc_atomic_unsigned_long_create
    public static let atomic_destroy                    = __catmc_atomic_unsigned_long_destroy
    public static let atomic_compare_and_exchange       = __catmc_atomic_unsigned_long_compare_and_exchange_strong
    public static let atomic_compare_and_exchange_weak  = __catmc_atomic_unsigned_long_compare_and_exchange_weak
    public static let atomic_add                        = __catmc_atomic_unsigned_long_add
    public static let atomic_sub                        = __catmc_atomic_unsigned_long_sub
    public static let atomic_and                        = __catmc_atomic_unsigned_long_and
    public static let atomic_or                         = __catmc_atomic_unsigned_long_or
    public static let atomic_xor                        = __catmc_atomic_unsigned_long_xor
    public static let atomic_exchange                   = __catmc_atomic_unsigned_long_exchange
    public static let atomic_load                       = __catmc_atomic_unsigned_long_load
    public static let atomic_store                      = __catmc_atomic_unsigned_long_store
}





/// `AtomicBox` is a heap-allocated box which allows atomic access to an instance of a Swift class.
///
/// It behaves very much like `Atomic<T>` but for objects, maintaining the correct retain counts.
public class AtomicBox<T: AnyObject> {
    private let storage: Atomic<UInt>

    public init() {
        self.storage = Atomic(value: 0x0)
    }

    public init(value: T) {
        let ptr = Unmanaged<T>.passRetained(value)
        self.storage = Atomic(value: UInt(bitPattern: ptr.toOpaque()))
    }

    deinit {
        let oldPtrBits = self.storage.exchange(with: 0xdeadbee)
        if oldPtrBits != 0 {
            let oldPtr = Unmanaged<T>.fromOpaque(UnsafeRawPointer(bitPattern: oldPtrBits)!)
            oldPtr.release()
        }
    }

    /// Atomically compares the value against `expected` and, if they are equal,
    /// replaces the value with `desired`.
    ///
    /// This implementation conforms to C11's `atomic_compare_exchange_strong`. This
    /// means that the compare-and-swap will always succeed if `expected` is equal to
    /// value. Additionally, it uses a *sequentially consistent ordering*. For more
    /// details on atomic memory models, check the documentation for C11's
    /// `stdatomic.h`.
    ///
    /// - Parameter expected: The value that this object must currently hold for the
    ///     compare-and-swap to succeed.
    /// - Parameter desired: The new value that this object will hold if the compare
    ///     succeeds.
    /// - Returns: `True` if the exchange occurred, or `False` if `expected` did not
    ///     match the current value and so no exchange occurred.
    public func compareAndExchange(expected expectedOpt: T?, desired desiredOpt: T?) -> Bool {
        return withExtendedLifetime(desiredOpt) {
            let expectedPtr = expectedOpt.map(Unmanaged<T>.passUnretained)
            let desiredPtr = desiredOpt.map(Unmanaged<T>.passUnretained)
            let expectedBitPtr: UInt = expectedPtr.map { UInt(bitPattern: $0.toOpaque()) } ?? 0
            let desiredBitPtr: UInt = desiredPtr.map { UInt(bitPattern: $0.toOpaque()) } ?? 0

            if self.storage.compareAndExchange(expected: expectedBitPtr,
                                               desired: desiredBitPtr) {
                _ = desiredPtr?.retain()
                expectedPtr?.release()
                return true
            } else {
                return false
            }
        }
    }

    /// Atomically exchanges `value` for the current value of this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Parameter value: The new value to set this object to.
    /// - Returns: The value previously held by this object.
    public func exchange(with value: T?) -> T? {
        let newPtrBits: UInt = value.map { value in
            let newPtr = Unmanaged<T>.passRetained(value)
            return UInt(bitPattern: newPtr.toOpaque())
        } ?? 0

        let oldPtrBits = self.storage.exchange(with: newPtrBits)

        if oldPtrBits == 0 {
            return nil
        }

        let oldPtr = Unmanaged<T>.fromOpaque(UnsafeRawPointer(bitPattern: oldPtrBits)!)
        return oldPtr.takeRetainedValue()
    }

    /// Atomically loads and returns the value of this object.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Returns: The value of this object
    public func load() -> T? {
        let ptrBits = self.storage.load()
        if ptrBits == 0 {
            return nil
        }

        let ptr = Unmanaged<T>.fromOpaque(UnsafeRawPointer(bitPattern: ptrBits)!)
        return ptr.takeUnretainedValue()
    }

    /// Atomically replaces the value of this object with `value`.
    ///
    /// This implementation uses a *relaxed* memory ordering. This guarantees nothing
    /// more than that this operation is atomic: there is no guarantee that any other
    /// event will be ordered before or after this one.
    ///
    /// - Parameter value: The new value to set the object to.
    public func store(_ value: T?) -> Void {
        _ = self.exchange(with: value)
    }
}
