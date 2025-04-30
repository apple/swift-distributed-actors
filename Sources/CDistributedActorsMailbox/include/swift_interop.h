//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#ifndef SACTANA_SWIFT_INTEROP_H
#define SACTANA_SWIFT_INTEROP_H


#if __has_attribute(enum_extensibility)
#define SWIFT_CLOSED_ENUM(name) typedef enum __attribute__((enum_extensibility(closed))) name
#else
#define SWIFT_CLOSED_ENUM(name) typedef enum name
#endif


#endif //SACTANA_SWIFT_INTEROP_H
