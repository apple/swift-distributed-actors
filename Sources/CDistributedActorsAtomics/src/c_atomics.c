//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#include <stdlib.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <inttypes.h>
#include <stdio.h>

#include "../include/c_atomics.h"
#include "../include/cpp_magic.h"

struct __catmc_atomic_flag {
    atomic_flag _flag;
};

struct __catmc_atomic_flag *__catmc_atomic_flag_create(bool value) {
    struct __catmc_atomic_flag *flag = malloc(sizeof(*flag));
    flag->_flag = (__typeof__(flag->_flag))ATOMIC_FLAG_INIT;
    if (value) {
        (void)atomic_flag_test_and_set_explicit(&flag->_flag, memory_order_seq_cst);
    } else {
        atomic_flag_clear_explicit(&flag->_flag, memory_order_seq_cst);
    }
    return flag;
}

void __catmc_atomic_flag_destroy(struct __catmc_atomic_flag *flag) {
    free(flag);
}

#define MAKE(type) /*
*/ struct __catmc_atomic_##type { /*
*/     _Atomic type value; /*
*/ }; /*
*/ /*
*/ struct __catmc_atomic_##type *__catmc_atomic_##type##_create(type value) { /*
*/     struct __catmc_atomic_##type *wrapper = malloc(sizeof(*wrapper)); /*
*/     atomic_init(&wrapper->value, value); /*
*/     return wrapper; /*
*/ } /*
*/ /*
*/ void __catmc_atomic_##type##_destroy(struct __catmc_atomic_##type *wrapper) { /*
*/     free(wrapper); /*
*/ } /*
*/ /*
*/ bool __catmc_atomic_##type##_compare_and_exchange_strong(struct __catmc_atomic_##type *wrapper, type expected, type desired, memory_order succ, memory_order fail) { /*
*/     type expected_copy = expected; /*
*/     return atomic_compare_exchange_strong_explicit(&wrapper->value, &expected_copy, desired, succ, fail); /*
*/ } /*
*/ /*
*/ bool __catmc_atomic_##type##_compare_and_exchange_weak(struct __catmc_atomic_##type *wrapper, type expected, type desired, memory_order succ, memory_order fail) { /*
*/     type expected_copy = expected; /*
*/     return atomic_compare_exchange_weak_explicit(&wrapper->value, &expected_copy, desired, succ, fail); /*
*/ } /*
*/ /*
*/ type __catmc_atomic_##type##_add(struct __catmc_atomic_##type *wrapper, type value, memory_order order) { /*
*/     return atomic_fetch_add_explicit(&wrapper->value, value, order); /*
*/ } /*
*/ /*
*/ type __catmc_atomic_##type##_sub(struct __catmc_atomic_##type *wrapper, type value, memory_order order) { /*
*/     return atomic_fetch_sub_explicit(&wrapper->value, value, order); /*
*/ } /*
*/ /*
*/ type __catmc_atomic_##type##_exchange(struct __catmc_atomic_##type *wrapper, type value, memory_order order) { /*
*/     return atomic_exchange_explicit(&wrapper->value, value, order); /*
*/ } /*
*/ /*
*/ type __catmc_atomic_##type##_load(struct __catmc_atomic_##type *wrapper, memory_order order) { /*
*/     return atomic_load_explicit(&wrapper->value, order); /*
*/ } /*
*/ /*
*/ void __catmc_atomic_##type##_store(struct __catmc_atomic_##type *wrapper, type value, memory_order order) { /*
*/     atomic_store_explicit(&wrapper->value, value, order); /*
*/ } /*
*/ /*
*/ type __catmc_atomic_##type##_and(struct __catmc_atomic_##type *wrapper, type value, memory_order order) { /*
*/     return atomic_fetch_and_explicit(&wrapper->value, value, order); /*
*/ } /*
*/ /*
*/ type __catmc_atomic_##type##_or(struct __catmc_atomic_##type *wrapper, type value, memory_order order) { /*
*/     return atomic_fetch_or_explicit(&wrapper->value, value, order); /*
*/ } /*
*/ /*
*/ type __catmc_atomic_##type##_xor(struct __catmc_atomic_##type *wrapper, type value, memory_order order) { /*
*/     return atomic_fetch_xor_explicit(&wrapper->value, value, order); /*
*/ }


typedef signed char signed_char;
typedef signed short signed_short;
typedef signed int signed_int;
typedef signed long signed_long;
typedef signed long long signed_long_long;
typedef unsigned char unsigned_char;
typedef unsigned short unsigned_short;
typedef unsigned int unsigned_int;
typedef unsigned long unsigned_long;
typedef unsigned long long unsigned_long_long;
typedef long long long_long;

MAP(MAKE,EMPTY,
         bool,
		          char,          short,          int,          long,          long_long,
		   signed_char,   signed_short,   signed_int,   signed_long,   signed_long_long,
		 unsigned_char, unsigned_short, unsigned_int, unsigned_long, unsigned_long_long,
		 int_least8_t, uint_least8_t,
		 int_least16_t, uint_least16_t,
		 int_least32_t, uint_least32_t,
		 int_least64_t, uint_least64_t
		)
