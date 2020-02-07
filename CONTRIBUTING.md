## Legal

By submitting a pull request, you represent that you have the right to license
your contribution to Apple and the community, and agree by submitting the patch
that your contributions are licensed under the Apache 2.0 license (see
`LICENSE.txt`).


## How to submit a bug report

Please ensure to specify the following:

* Swift Distributed Actors commit hash
* Contextual information (e.g. what you were trying to achieve with Swift Distributed Actors)
* Simplest possible steps to reproduce
  * More complex the steps are, lower the priority will be.
  * A pull request with failing test case is preferred, but it's just fine to paste the test case into the issue description.
* Anything that might be relevant in your opinion, such as:
  * Swift version or the output of `swift --version`
  * OS version and the output of `uname -a`
  * Network configuration


### Example

```
Swift Distributed Actors commit hash: 22ec043dc9d24bb011b47ece4f9ee97ee5be2757

Context:
While load testing my HTTP web server written with Swift Distributed Actors, I noticed
that one file descriptor is leaked per request.

Steps to reproduce:
1. ...
2. ...
3. ...
4. ...

$ swift --version
Swift version 4.0.2 (swift-4.0.2-RELEASE)
Target: x86_64-unknown-linux-gnu

Operating system: Ubuntu Linux 16.04 64-bit

$ uname -a
Linux beefy.machine 4.4.0-101-generic #124-Ubuntu SMP Fri Nov 10 18:29:59 UTC 2017 x86_64 x86_64 x86_64 GNU/Linux

My system has IPv6 disabled.
```

## Writing a Patch

A good Swift Distributed Actors patch is:

1. Concise, and contains as few changes as needed to achieve the end result.
2. Tested, ensuring that any tests provided failed before the patch and pass after it.
3. Documented, adding API documentation as needed to cover new functions and properties.
4. Adheres to our code formatting conventions and [style guide](STYLE_GUIDE.md).
5. Accompanied by a great commit message, using our commit message template.

### Code Format and Style

Swift Distributed Actors uses [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) to enforce the preferred [swift code format](.swiftformat). Always run SwiftFormat before committing your code. 

### Commit Message Template

We require that your commit messages match our template. The easiest way to do that is to get git to help you by explicitly using the template. To do that, `cd` to the root of our repository and run:

    git config commit.template dev/git.commit.template

### Test on Linux

Swift Distributed Actors uses XCTest to run tests on both macOS and Linux. While the macOS version of XCTest is able to use the Objective-C runtime to discover tests at execution time, the Linux version is not. For this reason, whenever you add new tests you will want to run a script that generates the hooks needed to run those tests on Linux, or our CI will complain that the tests are not all present on Linux. To do this, merely execute `./scripts/generate_linux_tests.rb` at the root of the package and check the changes it made.

## How to contribute your work

Please open a pull request at https://github.com/apple/swift-distributed-actors. Make sure the CI passes, and then wait for code review.
