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

#include <stdbool.h>
#include <stdint.h>

#include "cpp_magic.h"

#if __clang_major__ == 3 && __clang_minor__ <= 6
/* clang 3.6 doesn't seem to know about _Nonnull yet */
#define _Nonnull __attribute__((nonnull))
#endif

struct __catmc_atomic__Bool;
struct __catmc_atomic__Bool * _Nonnull __catmc_atomic__Bool_create(bool value);
void __catmc_atomic__Bool_destroy(struct __catmc_atomic__Bool * _Nonnull atomic);
bool __catmc_atomic__Bool_compare_and_exchange(struct __catmc_atomic__Bool * _Nonnull atomic, bool expected, bool desired);
bool __catmc_atomic__Bool_add(struct __catmc_atomic__Bool * _Nonnull atomic, bool value);
bool __catmc_atomic__Bool_sub(struct __catmc_atomic__Bool * _Nonnull atomic, bool value);
bool __catmc_atomic__Bool_exchange(struct __catmc_atomic__Bool * _Nonnull atomic, bool value);
bool __catmc_atomic__Bool_load(struct __catmc_atomic__Bool * _Nonnull atomic);
void __catmc_atomic__Bool_store(struct __catmc_atomic__Bool * _Nonnull atomic, bool value);
struct __catmc_atomic_char;
struct __catmc_atomic_char * _Nonnull __catmc_atomic_char_create(char value);
void __catmc_atomic_char_destroy(struct __catmc_atomic_char * _Nonnull atomic);
bool __catmc_atomic_char_compare_and_exchange(struct __catmc_atomic_char * _Nonnull atomic, char expected, char desired);
char __catmc_atomic_char_add(struct __catmc_atomic_char * _Nonnull atomic, char value);
char __catmc_atomic_char_sub(struct __catmc_atomic_char * _Nonnull atomic, char value);
char __catmc_atomic_char_exchange(struct __catmc_atomic_char * _Nonnull atomic, char value);
char __catmc_atomic_char_load(struct __catmc_atomic_char * _Nonnull atomic);
void __catmc_atomic_char_store(struct __catmc_atomic_char * _Nonnull atomic, char value);
struct __catmc_atomic_short;
struct __catmc_atomic_short * _Nonnull __catmc_atomic_short_create(short value);
void __catmc_atomic_short_destroy(struct __catmc_atomic_short * _Nonnull atomic);
bool __catmc_atomic_short_compare_and_exchange(struct __catmc_atomic_short * _Nonnull atomic, short expected, short desired);
short __catmc_atomic_short_add(struct __catmc_atomic_short * _Nonnull atomic, short value);
short __catmc_atomic_short_sub(struct __catmc_atomic_short * _Nonnull atomic, short value);
short __catmc_atomic_short_exchange(struct __catmc_atomic_short * _Nonnull atomic, short value);
short __catmc_atomic_short_load(struct __catmc_atomic_short * _Nonnull atomic);
void __catmc_atomic_short_store(struct __catmc_atomic_short * _Nonnull atomic, short value);
struct __catmc_atomic_int;
struct __catmc_atomic_int * _Nonnull __catmc_atomic_int_create(int value);
void __catmc_atomic_int_destroy(struct __catmc_atomic_int * _Nonnull atomic);
bool __catmc_atomic_int_compare_and_exchange(struct __catmc_atomic_int * _Nonnull atomic, int expected, int desired);
int __catmc_atomic_int_add(struct __catmc_atomic_int * _Nonnull atomic, int value);
int __catmc_atomic_int_sub(struct __catmc_atomic_int * _Nonnull atomic, int value);
int __catmc_atomic_int_exchange(struct __catmc_atomic_int * _Nonnull atomic, int value);
int __catmc_atomic_int_load(struct __catmc_atomic_int * _Nonnull atomic);
void __catmc_atomic_int_store(struct __catmc_atomic_int * _Nonnull atomic, int value);
struct __catmc_atomic_long;
struct __catmc_atomic_long * _Nonnull __catmc_atomic_long_create(long value);
void __catmc_atomic_long_destroy(struct __catmc_atomic_long * _Nonnull atomic);
bool __catmc_atomic_long_compare_and_exchange(struct __catmc_atomic_long * _Nonnull atomic, long expected, long desired);
long __catmc_atomic_long_add(struct __catmc_atomic_long * _Nonnull atomic, long value);
long __catmc_atomic_long_sub(struct __catmc_atomic_long * _Nonnull atomic, long value);
long __catmc_atomic_long_exchange(struct __catmc_atomic_long * _Nonnull atomic, long value);
long __catmc_atomic_long_load(struct __catmc_atomic_long * _Nonnull atomic);
void __catmc_atomic_long_store(struct __catmc_atomic_long * _Nonnull atomic, long value);
struct __catmc_atomic_long_long;
struct __catmc_atomic_long_long * _Nonnull __catmc_atomic_long_long_create(long long value);
void __catmc_atomic_long_long_destroy(struct __catmc_atomic_long_long * _Nonnull atomic);
bool __catmc_atomic_long_long_compare_and_exchange(struct __catmc_atomic_long_long * _Nonnull atomic, long long expected, long long desired);
long long __catmc_atomic_long_long_add(struct __catmc_atomic_long_long * _Nonnull atomic, long long value);
long long __catmc_atomic_long_long_sub(struct __catmc_atomic_long_long * _Nonnull atomic, long long value);
long long __catmc_atomic_long_long_exchange(struct __catmc_atomic_long_long * _Nonnull atomic, long long value);
long long __catmc_atomic_long_long_load(struct __catmc_atomic_long_long * _Nonnull atomic);
void __catmc_atomic_long_long_store(struct __catmc_atomic_long_long * _Nonnull atomic, long long value);
struct __catmc_atomic_signed_char;
struct __catmc_atomic_signed_char * _Nonnull __catmc_atomic_signed_char_create(signed char value);
void __catmc_atomic_signed_char_destroy(struct __catmc_atomic_signed_char * _Nonnull atomic);
bool __catmc_atomic_signed_char_compare_and_exchange(struct __catmc_atomic_signed_char * _Nonnull atomic, signed char expected, signed char desired);
signed char __catmc_atomic_signed_char_add(struct __catmc_atomic_signed_char * _Nonnull atomic, signed char value);
signed char __catmc_atomic_signed_char_sub(struct __catmc_atomic_signed_char * _Nonnull atomic, signed char value);
signed char __catmc_atomic_signed_char_exchange(struct __catmc_atomic_signed_char * _Nonnull atomic, signed char value);
signed char __catmc_atomic_signed_char_load(struct __catmc_atomic_signed_char * _Nonnull atomic);
void __catmc_atomic_signed_char_store(struct __catmc_atomic_signed_char * _Nonnull atomic, signed char value);
struct __catmc_atomic_signed_short;
struct __catmc_atomic_signed_short * _Nonnull __catmc_atomic_signed_short_create(signed short value);
void __catmc_atomic_signed_short_destroy(struct __catmc_atomic_signed_short * _Nonnull atomic);
bool __catmc_atomic_signed_short_compare_and_exchange(struct __catmc_atomic_signed_short * _Nonnull atomic, signed short expected, signed short desired);
signed short __catmc_atomic_signed_short_add(struct __catmc_atomic_signed_short * _Nonnull atomic, signed short value);
signed short __catmc_atomic_signed_short_sub(struct __catmc_atomic_signed_short * _Nonnull atomic, signed short value);
signed short __catmc_atomic_signed_short_exchange(struct __catmc_atomic_signed_short * _Nonnull atomic, signed short value);
signed short __catmc_atomic_signed_short_load(struct __catmc_atomic_signed_short * _Nonnull atomic);
void __catmc_atomic_signed_short_store(struct __catmc_atomic_signed_short * _Nonnull atomic, signed short value);
struct __catmc_atomic_signed_int;
struct __catmc_atomic_signed_int * _Nonnull __catmc_atomic_signed_int_create(signed int value);
void __catmc_atomic_signed_int_destroy(struct __catmc_atomic_signed_int * _Nonnull atomic);
bool __catmc_atomic_signed_int_compare_and_exchange(struct __catmc_atomic_signed_int * _Nonnull atomic, signed int expected, signed int desired);
signed int __catmc_atomic_signed_int_add(struct __catmc_atomic_signed_int * _Nonnull atomic, signed int value);
signed int __catmc_atomic_signed_int_sub(struct __catmc_atomic_signed_int * _Nonnull atomic, signed int value);
signed int __catmc_atomic_signed_int_exchange(struct __catmc_atomic_signed_int * _Nonnull atomic, signed int value);
signed int __catmc_atomic_signed_int_load(struct __catmc_atomic_signed_int * _Nonnull atomic);
void __catmc_atomic_signed_int_store(struct __catmc_atomic_signed_int * _Nonnull atomic, signed int value);
struct __catmc_atomic_signed_long;
struct __catmc_atomic_signed_long * _Nonnull __catmc_atomic_signed_long_create(signed long value);
void __catmc_atomic_signed_long_destroy(struct __catmc_atomic_signed_long * _Nonnull atomic);
bool __catmc_atomic_signed_long_compare_and_exchange(struct __catmc_atomic_signed_long * _Nonnull atomic, signed long expected, signed long desired);
signed long __catmc_atomic_signed_long_add(struct __catmc_atomic_signed_long * _Nonnull atomic, signed long value);
signed long __catmc_atomic_signed_long_sub(struct __catmc_atomic_signed_long * _Nonnull atomic, signed long value);
signed long __catmc_atomic_signed_long_exchange(struct __catmc_atomic_signed_long * _Nonnull atomic, signed long value);
signed long __catmc_atomic_signed_long_load(struct __catmc_atomic_signed_long * _Nonnull atomic);
void __catmc_atomic_signed_long_store(struct __catmc_atomic_signed_long * _Nonnull atomic, signed long value);
struct __catmc_atomic_signed_long_long;
struct __catmc_atomic_signed_long_long * _Nonnull __catmc_atomic_signed_long_long_create(signed long long value);
void __catmc_atomic_signed_long_long_destroy(struct __catmc_atomic_signed_long_long * _Nonnull atomic);
bool __catmc_atomic_signed_long_long_compare_and_exchange(struct __catmc_atomic_signed_long_long * _Nonnull atomic, signed long long expected, signed long long desired);
signed long long __catmc_atomic_signed_long_long_add(struct __catmc_atomic_signed_long_long * _Nonnull atomic, signed long long value);
signed long long __catmc_atomic_signed_long_long_sub(struct __catmc_atomic_signed_long_long * _Nonnull atomic, signed long long value);
signed long long __catmc_atomic_signed_long_long_exchange(struct __catmc_atomic_signed_long_long * _Nonnull atomic, signed long long value);
signed long long __catmc_atomic_signed_long_long_load(struct __catmc_atomic_signed_long_long * _Nonnull atomic);
void __catmc_atomic_signed_long_long_store(struct __catmc_atomic_signed_long_long * _Nonnull atomic, signed long long value);
struct __catmc_atomic_unsigned_char;
struct __catmc_atomic_unsigned_char * _Nonnull __catmc_atomic_unsigned_char_create(unsigned char value);
void __catmc_atomic_unsigned_char_destroy(struct __catmc_atomic_unsigned_char * _Nonnull atomic);
bool __catmc_atomic_unsigned_char_compare_and_exchange(struct __catmc_atomic_unsigned_char * _Nonnull atomic, unsigned char expected, unsigned char desired);
unsigned char __catmc_atomic_unsigned_char_add(struct __catmc_atomic_unsigned_char * _Nonnull atomic, unsigned char value);
unsigned char __catmc_atomic_unsigned_char_sub(struct __catmc_atomic_unsigned_char * _Nonnull atomic, unsigned char value);
unsigned char __catmc_atomic_unsigned_char_exchange(struct __catmc_atomic_unsigned_char * _Nonnull atomic, unsigned char value);
unsigned char __catmc_atomic_unsigned_char_load(struct __catmc_atomic_unsigned_char * _Nonnull atomic);
void __catmc_atomic_unsigned_char_store(struct __catmc_atomic_unsigned_char * _Nonnull atomic, unsigned char value);
struct __catmc_atomic_unsigned_short;
struct __catmc_atomic_unsigned_short * _Nonnull __catmc_atomic_unsigned_short_create(unsigned short value);
void __catmc_atomic_unsigned_short_destroy(struct __catmc_atomic_unsigned_short * _Nonnull atomic);
bool __catmc_atomic_unsigned_short_compare_and_exchange(struct __catmc_atomic_unsigned_short * _Nonnull atomic, unsigned short expected, unsigned short desired);
unsigned short __catmc_atomic_unsigned_short_add(struct __catmc_atomic_unsigned_short * _Nonnull atomic, unsigned short value);
unsigned short __catmc_atomic_unsigned_short_sub(struct __catmc_atomic_unsigned_short * _Nonnull atomic, unsigned short value);
unsigned short __catmc_atomic_unsigned_short_exchange(struct __catmc_atomic_unsigned_short * _Nonnull atomic, unsigned short value);
unsigned short __catmc_atomic_unsigned_short_load(struct __catmc_atomic_unsigned_short * _Nonnull atomic);
void __catmc_atomic_unsigned_short_store(struct __catmc_atomic_unsigned_short * _Nonnull atomic, unsigned short value);
struct __catmc_atomic_unsigned_int;
struct __catmc_atomic_unsigned_int * _Nonnull __catmc_atomic_unsigned_int_create(unsigned int value);
void __catmc_atomic_unsigned_int_destroy(struct __catmc_atomic_unsigned_int * _Nonnull atomic);
bool __catmc_atomic_unsigned_int_compare_and_exchange(struct __catmc_atomic_unsigned_int * _Nonnull atomic, unsigned int expected, unsigned int desired);
unsigned int __catmc_atomic_unsigned_int_add(struct __catmc_atomic_unsigned_int * _Nonnull atomic, unsigned int value);
unsigned int __catmc_atomic_unsigned_int_sub(struct __catmc_atomic_unsigned_int * _Nonnull atomic, unsigned int value);
unsigned int __catmc_atomic_unsigned_int_exchange(struct __catmc_atomic_unsigned_int * _Nonnull atomic, unsigned int value);
unsigned int __catmc_atomic_unsigned_int_load(struct __catmc_atomic_unsigned_int * _Nonnull atomic);
void __catmc_atomic_unsigned_int_store(struct __catmc_atomic_unsigned_int * _Nonnull atomic, unsigned int value);
struct __catmc_atomic_unsigned_long;
struct __catmc_atomic_unsigned_long * _Nonnull __catmc_atomic_unsigned_long_create(unsigned long value);
void __catmc_atomic_unsigned_long_destroy(struct __catmc_atomic_unsigned_long * _Nonnull atomic);
bool __catmc_atomic_unsigned_long_compare_and_exchange(struct __catmc_atomic_unsigned_long * _Nonnull atomic, unsigned long expected, unsigned long desired);
unsigned long __catmc_atomic_unsigned_long_add(struct __catmc_atomic_unsigned_long * _Nonnull atomic, unsigned long value);
unsigned long __catmc_atomic_unsigned_long_sub(struct __catmc_atomic_unsigned_long * _Nonnull atomic, unsigned long value);
unsigned long __catmc_atomic_unsigned_long_exchange(struct __catmc_atomic_unsigned_long * _Nonnull atomic, unsigned long value);
unsigned long __catmc_atomic_unsigned_long_load(struct __catmc_atomic_unsigned_long * _Nonnull atomic);
void __catmc_atomic_unsigned_long_store(struct __catmc_atomic_unsigned_long * _Nonnull atomic, unsigned long value);
struct __catmc_atomic_unsigned_long_long;
struct __catmc_atomic_unsigned_long_long * _Nonnull __catmc_atomic_unsigned_long_long_create(unsigned long long value);
void __catmc_atomic_unsigned_long_long_destroy(struct __catmc_atomic_unsigned_long_long * _Nonnull atomic);
bool __catmc_atomic_unsigned_long_long_compare_and_exchange(struct __catmc_atomic_unsigned_long_long * _Nonnull atomic, unsigned long long expected, unsigned long long desired);
unsigned long long __catmc_atomic_unsigned_long_long_add(struct __catmc_atomic_unsigned_long_long * _Nonnull atomic, unsigned long long value);
unsigned long long __catmc_atomic_unsigned_long_long_sub(struct __catmc_atomic_unsigned_long_long * _Nonnull atomic, unsigned long long value);
unsigned long long __catmc_atomic_unsigned_long_long_exchange(struct __catmc_atomic_unsigned_long_long * _Nonnull atomic, unsigned long long value);
unsigned long long __catmc_atomic_unsigned_long_long_load(struct __catmc_atomic_unsigned_long_long * _Nonnull atomic);
void __catmc_atomic_unsigned_long_long_store(struct __catmc_atomic_unsigned_long_long * _Nonnull atomic, unsigned long long value);
struct __catmc_atomic_int_least8_t;
struct __catmc_atomic_int_least8_t * _Nonnull __catmc_atomic_int_least8_t_create(int_least8_t value);
void __catmc_atomic_int_least8_t_destroy(struct __catmc_atomic_int_least8_t * _Nonnull atomic);
bool __catmc_atomic_int_least8_t_compare_and_exchange(struct __catmc_atomic_int_least8_t * _Nonnull atomic, int_least8_t expected, int_least8_t desired);
int_least8_t __catmc_atomic_int_least8_t_add(struct __catmc_atomic_int_least8_t * _Nonnull atomic, int_least8_t value);
int_least8_t __catmc_atomic_int_least8_t_sub(struct __catmc_atomic_int_least8_t * _Nonnull atomic, int_least8_t value);
int_least8_t __catmc_atomic_int_least8_t_exchange(struct __catmc_atomic_int_least8_t * _Nonnull atomic, int_least8_t value);
int_least8_t __catmc_atomic_int_least8_t_load(struct __catmc_atomic_int_least8_t * _Nonnull atomic);
void __catmc_atomic_int_least8_t_store(struct __catmc_atomic_int_least8_t * _Nonnull atomic, int_least8_t value);
struct __catmc_atomic_uint_least8_t;
struct __catmc_atomic_uint_least8_t * _Nonnull __catmc_atomic_uint_least8_t_create(uint_least8_t value);
void __catmc_atomic_uint_least8_t_destroy(struct __catmc_atomic_uint_least8_t * _Nonnull atomic);
bool __catmc_atomic_uint_least8_t_compare_and_exchange(struct __catmc_atomic_uint_least8_t * _Nonnull atomic, uint_least8_t expected, uint_least8_t desired);
uint_least8_t __catmc_atomic_uint_least8_t_add(struct __catmc_atomic_uint_least8_t * _Nonnull atomic, uint_least8_t value);
uint_least8_t __catmc_atomic_uint_least8_t_sub(struct __catmc_atomic_uint_least8_t * _Nonnull atomic, uint_least8_t value);
uint_least8_t __catmc_atomic_uint_least8_t_exchange(struct __catmc_atomic_uint_least8_t * _Nonnull atomic, uint_least8_t value);
uint_least8_t __catmc_atomic_uint_least8_t_load(struct __catmc_atomic_uint_least8_t * _Nonnull atomic);
void __catmc_atomic_uint_least8_t_store(struct __catmc_atomic_uint_least8_t * _Nonnull atomic, uint_least8_t value);
struct __catmc_atomic_int_least16_t;
struct __catmc_atomic_int_least16_t * _Nonnull __catmc_atomic_int_least16_t_create(int_least16_t value);
void __catmc_atomic_int_least16_t_destroy(struct __catmc_atomic_int_least16_t * _Nonnull atomic);
bool __catmc_atomic_int_least16_t_compare_and_exchange(struct __catmc_atomic_int_least16_t * _Nonnull atomic, int_least16_t expected, int_least16_t desired);
int_least16_t __catmc_atomic_int_least16_t_add(struct __catmc_atomic_int_least16_t * _Nonnull atomic, int_least16_t value);
int_least16_t __catmc_atomic_int_least16_t_sub(struct __catmc_atomic_int_least16_t * _Nonnull atomic, int_least16_t value);
int_least16_t __catmc_atomic_int_least16_t_exchange(struct __catmc_atomic_int_least16_t * _Nonnull atomic, int_least16_t value);
int_least16_t __catmc_atomic_int_least16_t_load(struct __catmc_atomic_int_least16_t * _Nonnull atomic);
void __catmc_atomic_int_least16_t_store(struct __catmc_atomic_int_least16_t * _Nonnull atomic, int_least16_t value);
struct __catmc_atomic_uint_least16_t;
struct __catmc_atomic_uint_least16_t * _Nonnull __catmc_atomic_uint_least16_t_create(uint_least16_t value);
void __catmc_atomic_uint_least16_t_destroy(struct __catmc_atomic_uint_least16_t * _Nonnull atomic);
bool __catmc_atomic_uint_least16_t_compare_and_exchange(struct __catmc_atomic_uint_least16_t * _Nonnull atomic, uint_least16_t expected, uint_least16_t desired);
uint_least16_t __catmc_atomic_uint_least16_t_add(struct __catmc_atomic_uint_least16_t * _Nonnull atomic, uint_least16_t value);
uint_least16_t __catmc_atomic_uint_least16_t_sub(struct __catmc_atomic_uint_least16_t * _Nonnull atomic, uint_least16_t value);
uint_least16_t __catmc_atomic_uint_least16_t_exchange(struct __catmc_atomic_uint_least16_t * _Nonnull atomic, uint_least16_t value);
uint_least16_t __catmc_atomic_uint_least16_t_load(struct __catmc_atomic_uint_least16_t * _Nonnull atomic);
void __catmc_atomic_uint_least16_t_store(struct __catmc_atomic_uint_least16_t * _Nonnull atomic, uint_least16_t value);
struct __catmc_atomic_int_least32_t;
struct __catmc_atomic_int_least32_t * _Nonnull __catmc_atomic_int_least32_t_create(int_least32_t value);
void __catmc_atomic_int_least32_t_destroy(struct __catmc_atomic_int_least32_t * _Nonnull atomic);
bool __catmc_atomic_int_least32_t_compare_and_exchange(struct __catmc_atomic_int_least32_t * _Nonnull atomic, int_least32_t expected, int_least32_t desired);
int_least32_t __catmc_atomic_int_least32_t_add(struct __catmc_atomic_int_least32_t * _Nonnull atomic, int_least32_t value);
int_least32_t __catmc_atomic_int_least32_t_sub(struct __catmc_atomic_int_least32_t * _Nonnull atomic, int_least32_t value);
int_least32_t __catmc_atomic_int_least32_t_exchange(struct __catmc_atomic_int_least32_t * _Nonnull atomic, int_least32_t value);
int_least32_t __catmc_atomic_int_least32_t_load(struct __catmc_atomic_int_least32_t * _Nonnull atomic);
void __catmc_atomic_int_least32_t_store(struct __catmc_atomic_int_least32_t * _Nonnull atomic, int_least32_t value);
struct __catmc_atomic_uint_least32_t;
struct __catmc_atomic_uint_least32_t * _Nonnull __catmc_atomic_uint_least32_t_create(uint_least32_t value);
void __catmc_atomic_uint_least32_t_destroy(struct __catmc_atomic_uint_least32_t * _Nonnull atomic);
bool __catmc_atomic_uint_least32_t_compare_and_exchange(struct __catmc_atomic_uint_least32_t * _Nonnull atomic, uint_least32_t expected, uint_least32_t desired);
uint_least32_t __catmc_atomic_uint_least32_t_add(struct __catmc_atomic_uint_least32_t * _Nonnull atomic, uint_least32_t value);
uint_least32_t __catmc_atomic_uint_least32_t_sub(struct __catmc_atomic_uint_least32_t * _Nonnull atomic, uint_least32_t value);
uint_least32_t __catmc_atomic_uint_least32_t_exchange(struct __catmc_atomic_uint_least32_t * _Nonnull atomic, uint_least32_t value);
uint_least32_t __catmc_atomic_uint_least32_t_load(struct __catmc_atomic_uint_least32_t * _Nonnull atomic);
void __catmc_atomic_uint_least32_t_store(struct __catmc_atomic_uint_least32_t * _Nonnull atomic, uint_least32_t value);
struct __catmc_atomic_int_least64_t;
struct __catmc_atomic_int_least64_t * _Nonnull __catmc_atomic_int_least64_t_create(int_least64_t value);
void __catmc_atomic_int_least64_t_destroy(struct __catmc_atomic_int_least64_t * _Nonnull atomic);
bool __catmc_atomic_int_least64_t_compare_and_exchange(struct __catmc_atomic_int_least64_t * _Nonnull atomic, int_least64_t expected, int_least64_t desired);
int_least64_t __catmc_atomic_int_least64_t_add(struct __catmc_atomic_int_least64_t * _Nonnull atomic, int_least64_t value);
int_least64_t __catmc_atomic_int_least64_t_sub(struct __catmc_atomic_int_least64_t * _Nonnull atomic, int_least64_t value);
int_least64_t __catmc_atomic_int_least64_t_exchange(struct __catmc_atomic_int_least64_t * _Nonnull atomic, int_least64_t value);
int_least64_t __catmc_atomic_int_least64_t_load(struct __catmc_atomic_int_least64_t * _Nonnull atomic);
void __catmc_atomic_int_least64_t_store(struct __catmc_atomic_int_least64_t * _Nonnull atomic, int_least64_t value);
struct __catmc_atomic_uint_least64_t;
struct __catmc_atomic_uint_least64_t * _Nonnull __catmc_atomic_uint_least64_t_create(uint_least64_t value);
void __catmc_atomic_uint_least64_t_destroy(struct __catmc_atomic_uint_least64_t * _Nonnull atomic);
bool __catmc_atomic_uint_least64_t_compare_and_exchange(struct __catmc_atomic_uint_least64_t * _Nonnull atomic, uint_least64_t expected, uint_least64_t desired);
uint_least64_t __catmc_atomic_uint_least64_t_add(struct __catmc_atomic_uint_least64_t * _Nonnull atomic, uint_least64_t value);
uint_least64_t __catmc_atomic_uint_least64_t_sub(struct __catmc_atomic_uint_least64_t * _Nonnull atomic, uint_least64_t value);
uint_least64_t __catmc_atomic_uint_least64_t_exchange(struct __catmc_atomic_uint_least64_t * _Nonnull atomic, uint_least64_t value);
uint_least64_t __catmc_atomic_uint_least64_t_load(struct __catmc_atomic_uint_least64_t * _Nonnull atomic);
void __catmc_atomic_uint_least64_t_store(struct __catmc_atomic_uint_least64_t * _Nonnull atomic, uint_least64_t value);
