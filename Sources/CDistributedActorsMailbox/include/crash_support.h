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

#ifndef SACT_CRASH_SUPPORT_H
#define SACT_CRASH_SUPPORT_H

/**
 * Prints a stack backtrace directly to `stderr`.
 * Use only internally, mostly for 
 *
 * Swift names will be mangled.
 * Paste as: `pbpaste | ./scripts/sact_backtrace_demangle` to easily demangle the entire trace.
 */
void sact_dump_backtrace(void);

int sact_get_backtrace(char*** strs);

/* emit `ud2` assembly, simulating a trap */
void sact_simulate_trap(void);

#endif
