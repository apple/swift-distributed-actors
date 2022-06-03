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

#if os(Linux)
import Glibc
#else
import Darwin
// import LibProc
#endif

public struct BenchResults {
    typealias T = Int
    private let samples: [T]
    let maxRSS: Int?
    let stats: Stats

    init(_ samples: [T], maxRSS: Int?) {
        self.samples = samples.sorted()
        self.maxRSS = maxRSS
        self.stats = self.samples.reduce(into: Stats(), Stats.collect)
    }

    /// Return measured value for given `quantile`.
    ///
    /// Equivalent to quantile estimate type R-1, SAS-3. See:
    /// https://en.wikipedia.org/wiki/Quantile#Estimating_quantiles_from_a_sample
    subscript(_ quantile: Double) -> T {
        let index = Swift.max(
            0,
            Int((Double(self.samples.count) * quantile).rounded(.up)) - 1
        )
        return self.samples[index]
    }

    var sampleCount: T { self.samples.count }
    var min: T { self.samples.first! }
    var max: T { self.samples.last! }
    var mean: T { Int(self.stats.mean.rounded()) }
    var sd: T { Int(self.stats.standardDeviation.rounded()) }
    var median: T { self[0.5] }
}

public var registeredBenchmarks: [BenchmarkInfo] = []

enum TestAction {
    case run
    case listTests
}

struct TestConfig {
    /// The delimiter to use when printing output.
    let delim: String

    /// Duration of the test measurement in seconds.
    ///
    /// Used to compute the number of iterations, if no fixed amount is specified.
    /// This is useful when one wishes for a test to run for a
    /// longer amount of time to perform performance analysis on the test in
    /// instruments.
    let sampleTime: Double

    /// Number of iterations averaged in the sample.
    /// When not specified, we'll compute the number of iterations to be averaged
    /// in the sample from the actual runtime and the desired `sampleTime`.
    let numIters: Int?

    /// The number of samples we should take of each test.
    let numSamples: Int?

    /// Quantiles to report in results.
    let quantile: Int?

    /// Time unit in which to report results (nanos, micros, millis) (default: nanoseconds)
    let timeUnit: TimeUnit

    /// Report quantiles with delta encoding.
    let delta: Bool

    /// Is verbose output enabled?
    let verbose: Bool

    // Should we log the test's memory usage?
    let logMemory: Bool

    /// After we run the tests, should the harness sleep to allow for utilities
    /// like leaks that require a PID to run on the test harness.
    let afterRunSleep: UInt32?

    /// The list of tests to run.
    let tests: [(index: String, info: BenchmarkInfo)]

    let action: TestAction

    init(_ registeredBenchmarks: [BenchmarkInfo]) {
        struct PartialTestConfig {
            var delim: String?
            var tags, skipTags: Set<BenchmarkCategory>?
            var numSamples: UInt?
            var numIters: UInt?
            var quantile: UInt?
            var timeUnit: String?
            var delta: Bool?
            var afterRunSleep: UInt32?
            var sampleTime: Double?
            var verbose: Bool?
            var logMemory: Bool?
            var action: TestAction?
            var tests: [String]?
        }

        // Custom value type parsers
        func tags(tags: String) throws -> Set<BenchmarkCategory> {
            // We support specifying multiple tags by splitting on comma, i.e.:
            //  --tags=Array,Dictionary
            //  --skip-tags=Array,Set,unstable,skip
            Set(
                try tags.split(separator: ",").map(String.init).map {
                    try checked({ BenchmarkCategory(rawValue: $0) }, $0)
                }
            )
        }
        func finiteDouble(value: String) -> Double? {
            Double(value).flatMap { $0.isFinite ? $0 : nil }
        }

        // Configure the command line argument parser
        let p = ArgumentParser(into: PartialTestConfig())
        p.addArgument(
            "--num-samples", \.numSamples,
            help: "number of samples to take per benchmark;\n" +
                "default: 1 or auto-scaled to measure for\n" +
                "`sample-time` if num-iters is also specified\n",
            parser: { UInt($0) }
        )
        p.addArgument(
            "--num-iters", \.numIters,
            help: "number of iterations averaged in the sample;\n" +
                "default: auto-scaled to measure for `sample-time`",
            parser: { UInt($0) }
        )
        p.addArgument(
            "--quantile", \.quantile,
            help: "report quantiles instead of normal dist. stats;\n" +
                "use 4 to get a five-number summary with quartiles,\n" +
                "10 (deciles), 20 (ventiles), 100 (percentiles), etc.",
            parser: { UInt($0) }
        )
        p.addArgument(
            "--time-unit", \.timeUnit,
            help: "time unit to be used for reported measurements;\n" +
                "supported values: ns, us, ms; default: ns",
            parser: { $0 }
        )
        p.addArgument(
            "--delta", \.delta, defaultValue: true,
            help: "report quantiles with delta encoding"
        )
        p.addArgument(
            "--sample-time", \.sampleTime,
            help: "duration of test measurement in seconds\ndefault: 1",
            parser: finiteDouble
        )
        p.addArgument(
            "--verbose", \.verbose, defaultValue: true,
            help: "increase output verbosity"
        )
        p.addArgument(
            "--memory", \.logMemory, defaultValue: true,
            help: "log the change in maximum resident set size (MAX_RSS)"
        )
        p.addArgument(
            "--delim", \.delim,
            help: "value delimiter used for log output; default: ,",
            parser: { $0 }
        )
        p.addArgument(
            "--tags", \PartialTestConfig.tags,
            help: "run tests matching all the specified categories",
            parser: tags
        )
        p.addArgument(
            "--skip-tags", \PartialTestConfig.skipTags, defaultValue: [],
            help: "don't run tests matching any of the specified\n" +
                "categories; default: unstable,skip",
            parser: tags
        )
        p.addArgument(
            "--sleep", \.afterRunSleep,
            help: "number of seconds to sleep after benchmarking",
            parser: { UInt32($0) }
        )
        p.addArgument(
            "--list", \.action, defaultValue: .listTests,
            help: "don't run the tests, just log the list of test \n" +
                "numbers, names and tags (respects specified filters)"
        )
        p.addArgument(nil, \.tests) // positional arguments
        let c = p.parse()

        // Configure from the command line arguments, filling in the defaults.
        self.delim = c.delim ?? ","
        self.sampleTime = c.sampleTime ?? 1.0
        self.numIters = c.numIters.map { Int($0) }
        self.numSamples = c.numSamples.map { Int($0) }
        self.quantile = c.quantile.map { Int($0) }
        self.timeUnit = c.timeUnit.map { TimeUnit($0) } ?? TimeUnit.nanoseconds
        self.delta = c.delta ?? false
        self.verbose = c.verbose ?? false
        self.logMemory = c.logMemory ?? false
        self.afterRunSleep = c.afterRunSleep
        self.action = c.action ?? .run
        self.tests = TestConfig.filterTests(
            registeredBenchmarks,
            specifiedTests: Set(c.tests ?? []),
            tags: c.tags ?? [],
            skipTags: c.skipTags ?? [.unstable, .skip]
        )

        if self.logMemory, self.tests.count > 1 {
            print(
                """
                warning: The memory usage of a test, reported as the change in MAX_RSS,
                         is based on measuring the peak memory used by the whole process.
                         These results are meaningful only when running a single test,
                         not in the batch mode!
                """)
        }

        // We always prepare the configuration string and call the print to have
        // the same memory usage baseline between verbose and normal mode.
        let testList = self.tests.map(\.1.name).joined(separator: ", ")
        let configuration = """
        --- CONFIG ---
        NumSamples: \(numSamples ?? 0)
        Verbose: \(verbose)
        LogMemory: \(logMemory)
        SampleTime: \(sampleTime)
        NumIters: \(numIters ?? 0)
        Quantile: \(quantile ?? 0)
        TimeUnit: \(timeUnit)
        Delimiter: \(String(reflecting: delim))
        Tests Filter: \(c.tests ?? [])
        Tests to run: \(testList)
        --- DATA ---\n
        """
        print(self.verbose ? configuration : "", terminator: "")
    }

    /// Returns the list of tests to run.
    ///
    /// - Parameters:
    ///   - registeredBenchmarks: List of all performance tests to be filtered.
    ///   - specifiedTests: List of explicitly specified tests to run. These can
    ///     be specified either by a test name or a test number.
    ///   - tags: Run tests tagged with all of these categories.
    ///   - skipTags: Don't run tests tagged with any of these categories.
    /// - Returns: An array of test number and benchmark info tuples satisfying
    ///     specified filtering conditions.
    static func filterTests(
        _ registeredBenchmarks: [BenchmarkInfo],
        specifiedTests: Set<String>,
        tags: Set<BenchmarkCategory>,
        skipTags: Set<BenchmarkCategory>
    ) -> [(index: String, info: BenchmarkInfo)] {
        let allTests = registeredBenchmarks.sorted()
        let indices = Dictionary(
            uniqueKeysWithValues:
            zip(
                allTests.map(\.name),
                (1...).lazy.map { String($0) }
            )
        )

        func byTags(b: BenchmarkInfo) -> Bool {
            b.tags.isSuperset(of: tags) &&
                b.tags.isDisjoint(with: skipTags)
        }
        func byNamesOrIndices(b: BenchmarkInfo) -> Bool {
            specifiedTests.contains(b.name) ||
                specifiedTests.contains(indices[b.name]!)
        } // !! "`allTests` have been assigned an index"
        return allTests
            .filter(specifiedTests.isEmpty ? byTags : byNamesOrIndices)
            .map { (index: indices[$0.name]!, info: $0) }
    }
}

struct Stats {
    var n: Int = 0
    var S: Double = 0.0
    var mean: Double = 0.0
    var variance: Double { self.n < 2 ? 0.0 : self.S / Double(self.n - 1) }
    var standardDeviation: Double { self.variance.squareRoot() }

    static func collect(_ s: inout Stats, _ x: Int) {
        Stats.runningMeanVariance(&s, Double(x))
    }

    /// Compute running mean and variance using B. P. Welford's method.
    ///
    /// See Knuth TAOCP vol 2, 3rd edition, page 232, or
    /// https://www.johndcook.com/blog/standard_deviation/
    static func runningMeanVariance(_ s: inout Stats, _ x: Double) {
        let n = s.n + 1
        let (k, M_, S_) = (Double(n), s.mean, s.S)
        let M = M_ + (x - M_) / k
        let S = S_ + (x - M_) * (x - M)
        (s.n, s.mean, s.S) = (n, M, S)
    }
}

#if SWIFT_RUNTIME_ENABLE_LEAK_CHECKER

@_silgen_name("_swift_leaks_startTrackingObjects")
func startTrackingObjects(_: UnsafePointer<CChar>) -> Void
@_silgen_name("_swift_leaks_stopTrackingObjects")
func stopTrackingObjects(_: UnsafePointer<CChar>) -> Int

#endif

public final class Timer {
    #if os(Linux)
    public typealias TimeT = timespec

    public init() {}

    public func getTime() -> TimeT {
        var ts = timespec(tv_sec: 0, tv_nsec: 0)
        clock_gettime(CLOCK_REALTIME, &ts)
        return ts
    }

    public func getTimeAsInt() -> UInt64 {
        UInt64(getTime().tv_nsec)
    }

    public func diffTimeInNanoSeconds(from start: TimeT, to end: TimeT) -> UInt64 {
        let oneSecond = 1_000_000_000 // ns
        var elapsed = timespec(tv_sec: 0, tv_nsec: 0)
        if end.tv_nsec - start.tv_nsec < 0 {
            elapsed.tv_sec = end.tv_sec - start.tv_sec - 1
            elapsed.tv_nsec = end.tv_nsec - start.tv_nsec + oneSecond
        } else {
            elapsed.tv_sec = end.tv_sec - start.tv_sec
            elapsed.tv_nsec = end.tv_nsec - start.tv_nsec
        }
        return UInt64(elapsed.tv_sec) * UInt64(oneSecond) + UInt64(elapsed.tv_nsec)
    }

    #else
    public typealias TimeT = UInt64
    var info = mach_timebase_info_data_t(numer: 0, denom: 0)

    public init() {
        mach_timebase_info(&info)
    }

    public func getTime() -> TimeT {
        mach_absolute_time()
    }

    public func getTimeAsInt() -> UInt64 {
        UInt64(getTime())
    }

    public func diffTimeInNanoSeconds(from start: TimeT, to end: TimeT) -> UInt64 {
        let elapsed = end - start
        return elapsed * UInt64(info.numer) / UInt64(info.denom)
    }
    #endif
}

extension UInt64 {
    public var nanoseconds: Int { Int(self) }
    public var microseconds: Int { Int(self / 1000) }
    public var milliseconds: Int { Int(self / 1000 / 1000) }
    public var seconds: Int { Int(self / 1000 / 1000 / 1000) }
}

enum TimeUnit: String {
    case nanoseconds = "ns"
    case microseconds = "μs"
    case milliseconds = "ms"
    case seconds = "s"

    init(_ from: String) {
        switch from {
        case "ns": self = .nanoseconds
        case "us", "μs": self = .microseconds
        case "ms": self = .milliseconds
        case "s": self = .seconds
        default: fatalError("Only the following time units are supported: ns, us, ms, s")
        }
    }

    static var `default` = TimeUnit.nanoseconds
}

extension TimeUnit: CustomStringConvertible {
    public var description: String {
        self.rawValue
    }
}

/// Performance test runner that measures benchmarks and reports the results.
final class TestRunner {
    let c: TestConfig
    let timer = Timer()
    var start, end, lastYield: Timer.TimeT
    let baseline = TestRunner.getResourceUtilization()
    let schedulerQuantum = UInt64(10_000_000) // nanoseconds (== 10ms, macos)
    init(_ config: TestConfig) {
        self.c = config
        let now = timer.getTime()
        (start, end, lastYield) = (now, now, now)
    }

    /// Offer to yield CPU to other processes and return current time on resume.
    func yield() -> Timer.TimeT {
        sched_yield()
        return timer.getTime()
    }

    #if os(Linux)
    private static func getExecutedInstructions() -> UInt64 {
        // FIXME: there is a Linux PMC API you can use to get this, but it's
        // not quite so straightforward.
        0
    }

    #else
    private static func getExecutedInstructions() -> UInt64 {
//        if #available(OSX 10.9, iOS 7.0, *) {
//            var u = rusage_info_v4()
//            let p = UnsafeMutablePointer(&u)
//            p.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) { up in
//                let _ = proc_pid_rusage(getpid(), RUSAGE_INFO_V4, up)
//            }
//            return u.ri_instructions
//        } else {
        0
//        }
    }
    #endif

    private static func getResourceUtilization() -> rusage {
        #if canImport(Darwin)
        let rusageSelf = RUSAGE_SELF
        #else
        let rusageSelf = RUSAGE_SELF.rawValue
        #endif
        var u = rusage(); getrusage(rusageSelf, &u); return u
    }

    /// Returns maximum resident set size (MAX_RSS) delta in bytes.
    ///
    /// This method of estimating memory usage is valid only for executing single
    /// benchmark. That's why we don't worry about reseting the `baseline` in
    /// `resetMeasurements`.
    ///
    // FIXME: This current implementation doesn't work on Linux. It is disabled
    /// permanently to avoid linker errors. Feel free to fix.
    func measureMemoryUsage() -> Int? {
        #if os(Linux)
        return nil
        #else
        guard c.logMemory else { return nil }
        let current = TestRunner.getResourceUtilization()
        let maxRSS = current.ru_maxrss - baseline.ru_maxrss
        #if canImport(Darwin)
        let pageSize = _SC_PAGESIZE
        #else
        let pageSize = Int32(_SC_PAGESIZE)
        #endif
        let pages = { maxRSS / sysconf(pageSize) }
        func deltaEquation(_ stat: KeyPath<rusage, Int>) -> String {
            let b = baseline[keyPath: stat], c = current[keyPath: stat]
            return "\(c) - \(b) = \(c - b)"
        }
        logVerbose(
            """
                MAX_RSS \(deltaEquation(\rusage.ru_maxrss)) (\(pages()) pages)
                ICS \(deltaEquation(\rusage.ru_nivcsw))
                VCS \(deltaEquation(\rusage.ru_nvcsw))
            """)
        return maxRSS
        #endif
    }

    private func startMeasurement() {
        let spent = timer.diffTimeInNanoSeconds(from: lastYield, to: end)
        let nextSampleEstimate = UInt64(Double(lastSampleTime) * 1.5)

        if spent + nextSampleEstimate < schedulerQuantum {
            start = timer.getTime()
        } else {
            logVerbose("    Yielding after ~\(spent.nanoseconds) ns")
            let now = yield()
            (start, lastYield) = (now, now)
        }
    }

    private func stopMeasurement() {
        end = timer.getTime()
    }

    private func resetMeasurements() {
        let now = yield()
        (start, end, lastYield) = (now, now, now)
    }

    /// Time in nanoseconds spent running the last function
    var lastSampleTime: UInt64 {
        timer.diffTimeInNanoSeconds(from: start, to: end)
    }

    /// Measure the `fn` and return the average sample time per iteration (in c.timeUnit).
    func measure(_ name: String, fn: (Int) -> Void, numIters: Int) -> Int {
        #if SWIFT_RUNTIME_ENABLE_LEAK_CHECKER
        name.withCString { p in startTrackingObjects(p) }
        #endif

        startMeasurement()
        fn(numIters)
        stopMeasurement()

        #if SWIFT_RUNTIME_ENABLE_LEAK_CHECKER
        name.withCString { p in stopTrackingObjects(p) }
        #endif

        switch c.timeUnit {
        case .nanoseconds: return lastSampleTime.nanoseconds / numIters
        case .microseconds: return lastSampleTime.microseconds / numIters
        case .milliseconds: return lastSampleTime.milliseconds / numIters
        case .seconds: return lastSampleTime.seconds / numIters
        }
    }

    func logVerbose(_ msg: @autoclosure () -> String) {
        if c.verbose { print(msg()) }
    }

    /// Run the benchmark and return the measured results.
    func run(_ test: BenchmarkInfo) -> BenchResults? {
        // Before we do anything, check that we actually have a function to
        // run. If we don't it is because the benchmark is not supported on
        // the platform and we should skip it.
        guard let testFn = test.runFunction else {
            logVerbose("Skipping unsupported benchmark \(test.name)!")
            return nil
        }
        logVerbose("Running \(test.name)")

        var samples: [Int] = []

        func addSample(_ time: Int) {
            logVerbose("    Sample \(samples.count),\(time)")
            samples.append(time)
        }

        resetMeasurements()
        if let setUp = test.setUpFunction {
            setUp()
            stopMeasurement()
            logVerbose("    SetUp \(lastSampleTime.microseconds)")
            resetMeasurements()
        }

        // Determine number of iterations for testFn to run for desired time.
        func iterationsPerSampleTime() -> (numIters: Int, oneIter: Int) {
            let oneIter = measure(test.name, fn: testFn, numIters: 1)
            if oneIter > 0 {
                let timePerSample = Int(c.sampleTime * 1_000_000.0) // microseconds (μs)
                return (max(timePerSample / oneIter, 1), oneIter)
            } else {
                return (1, oneIter)
            }
        }

        // Determine the scale of measurements. Re-use the calibration result if
        // it is just one measurement.
        func calibrateMeasurements() -> Int {
            let (numIters, oneIter) = iterationsPerSampleTime()
            if numIters == 1 { addSample(oneIter) }
            else { resetMeasurements() } // for accurate yielding reports
            return numIters
        }

        let numIters = min( // Cap to prevent overflow on 32-bit systems when scaled
            Int.max / 10000, // by the inner loop multiplier inside the `testFn`.
            c.numIters ?? calibrateMeasurements()
        )

        let numSamples = c.numSamples ?? min(
            200, // Cap the number of samples
            c.numIters == nil ? 1 : calibrateMeasurements()
        )

        samples.reserveCapacity(numSamples)
        logVerbose("    Collecting \(numSamples) samples.")
        logVerbose("    Measuring with scale \(numIters).")
        for _ in samples.count ..< numSamples {
            addSample(measure(test.name, fn: testFn, numIters: numIters))
        }

        test.tearDownFunction?()
        if let lf = test.legacyFactor {
            logVerbose("    Applying legacy factor: \(lf)")
            samples = samples.map { $0 * lf }
        }

        return BenchResults(samples, maxRSS: measureMemoryUsage())
    }

    var header: String {
        let withUnit = { $0 + "(\(self.c.timeUnit))" }
        let withDelta = { "𝚫" + $0 }
        func quantiles(q: Int) -> [String] {
            // See https://en.wikipedia.org/wiki/Quantile#Specialized_quantiles
            let prefix = [
                2: "MEDIAN", 3: "T", 4: "Q", 5: "QU", 6: "S", 7: "O", 10: "D",
                12: "Dd", 16: "H", 20: "V", 33: "TT", 100: "P", 1000: "Pr",
            ][q, default: "\(q)-q"]
            let base20 = "0123456789ABCDEFGHIJ".map { String($0) }
            let index: (Int) -> String =
                { q == 2 ? "" : q <= 20 ? base20[$0] : String($0) }
            let tail = (1 ..< q).map { prefix + index($0) } + ["MAX"]
            return [withUnit("MIN")] + tail.map(c.delta ? withDelta : withUnit)
        }
        return (
            ["#", "TEST", "SAMPLES"] +
                (
                    c.quantile.map(quantiles)
                        ?? ["MIN", "MAX", "MEAN", "SD", "MEDIAN"].map(withUnit)
                ) +
                (c.logMemory ? ["MAX_RSS(B)"] : [])
        ).joined(separator: c.delim)
    }

    /// Execute benchmarks and continuously report the measurement results.
    func runBenchmarks() {
        var testCount = 0

        func report(_ index: String, _ t: BenchmarkInfo, results: BenchResults?) {
            func values(r: BenchResults) -> [String] {
                func quantiles(q: Int) -> [Int] {
                    let qs = (0 ... q).map { i in r[Double(i) / Double(q)] }
                    return c.delta ?
                        qs.reduce(into: (encoded: [], last: 0)) {
                            $0.encoded.append($1 - $0.last); $0.last = $1
                        }.encoded : qs
                }
                return (
                    [r.sampleCount] +
                        (
                            c.quantile.map(quantiles)
                                ?? [r.min, r.max, r.mean, r.sd, r.median]
                        ) +
                        [r.maxRSS].compactMap { $0 }
                ).map { (c.delta && $0 == 0) ? "" : String($0) } // drop 0s in deltas
            }
            let benchmarkStats = (
                [index, t.name] + (results.map(values) ?? ["Unsupported"])
            ).joined(separator: c.delim)

            print(benchmarkStats)
            fflush(stdout)

            if results != nil {
                testCount += 1
            }
        }

        print(header)

        for (index, test) in c.tests {
            report(index, test, results: run(test))
        }

        print("\nTotal performance tests executed: \(testCount)")
    }
}

public func main() {
    let config = TestConfig(registeredBenchmarks)
    switch config.action {
    case .listTests:
        print("#\(config.delim)Test\(config.delim)[Tags]")
        for (index, t) in config.tests {
            let testDescription = [index, t.name, t.tags.sorted().description]
                .joined(separator: config.delim)
            print(testDescription)
        }
    case .run:
        TestRunner(config).runBenchmarks()
        if let x = config.afterRunSleep {
            sleep(x)
        }
    }
}
