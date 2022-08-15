# Contributing



## Testing

The cluster is extensively tested, including plain unit tests, tests spanning multiple nodes within the same process, as well as multi-node tests spanning across actor systems running across separate processes.

### Multi-node testing

Multi node test infrastructure is still in development and may be lacking some features, however its basic premise is to be able to run small "apps" that function as tests, and are automatically deployed to multiple processes.

> Note: Eventually, those processes may actually be located on different physical machines, but this isn't implemented yet.

## Testing logging (LogCapture)

As the cluster performs operations "in the background", such as keeping the membership and health information of the cluster up to date, it is very important that log statements it emits in such mode are useful and actionable, byt not overwhelming.

> Note: Almost all tests spanning multiple actor systems use a form of log capture, in order to keep the test output clean. Only some tests actually assert on logged information.

We therefore sometimes implement log capture tests. The basic way of using log capture tests is to use the `ClusterSystemXCTestCase`, 
and its `setUpNode` method to create an actor system (that will be shut down automatically after the test, including dumping logs if the test failed.)

Next one can use 

```swift
let log = try self.logCapture.awaitLogContaining(testKit, text: "Assign identity")
```

to suspend until the expected log statement is emitted. It is possible to configure more details about the matching as well as timeouts by passing more parameters to this call.

### Testing metrics (MetricsTestKit)