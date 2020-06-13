import DistributedActors

final class Philosopher: Actorable {
    private let context: Myself.Context
    private let leftFork: Actor<Fork>
    private let rightFork: Actor<Fork>
    private var state: State = .thinking

    init(context: Myself.Context, leftFork: Actor<Fork>, rightFork: Actor<Fork>) {
        self.context = context
        self.leftFork = leftFork
        self.rightFork = rightFork
    }

    // @actor
    func preStart(context: Actor<Philosopher>.Context) {
        context.watch(self.leftFork)
        context.watch(self.rightFork)
        context.log.info("\(context.address.name) joined the table!")
        self.think()
    }

    // @actor
    func think() {
        if case .takingForks(let leftIsTaken, let rightIsTaken) = self.state {
            if leftIsTaken {
                leftFork.putBack()
                context.log.info("\(context.address.name) put back their left fork!")
            }

            if rightIsTaken {
                rightFork.putBack()
                context.log.info("\(context.address.name) put back their right fork!")
            }
        }

        self.state = .thinking
        self.context.timers.startSingle(key: TimerKey("think"), message: .attemptToTakeForks, delay: .seconds(1))
        self.context.log.info("\(self.context.address.name) is thinking...")
    }

    // @actor
    func attemptToTakeForks() {
        guard self.state == .thinking else {
            self.context.log.error("\(self.context.address.name) tried to take a fork but was not in the thinking state!")
            return
        }

        self.state = .takingForks(leftTaken: false, rightTaken: false)

        func attemptToTake(fork: Actor<Fork>) {
            self.context.onResultAsync(of: fork.take(), timeout: .seconds(5)) { result in
                switch result {
                case .failure(let error):
                    self.context.log.warning("Failed to reach for fork! Error: \(error)")
                case .success(let didTakeFork):
                    if didTakeFork {
                        self.forkTaken(fork)
                    } else {
                        self.context.log.info("\(self.context.address.name) wasn't able to take a fork!")
                        self.think()
                    }
                }
            }
        }

        attemptToTake(fork: self.leftFork)
        attemptToTake(fork: self.rightFork)
    }

    /// Message sent to oneself after a timer exceeds and we're done `eating` and can become `thinking` again.
    // @actor
    func stopEating() {
        self.leftFork.putBack()
        self.rightFork.putBack()
        self.context.log.info("\(self.context.address.name) is done eating and replaced both forks!")
        self.think()
    }

    private func forkTaken(_ fork: Actor<Fork>) {
        if self.state == .thinking { // We couldn't get the first fork and have already gone back to thinking.
            fork.putBack()
            return
        }

        guard case .takingForks(let leftForkIsTaken, let rightForkIsTaken) = self.state else {
            self.context.log.error("Received fork \(fork) but was not in .takingForks state. State was \(self.state)! Ignoring...")
            fork.putBack()
            return
        }

        switch fork {
        case self.leftFork:
            self.context.log.info("\(self.context.address.name) received their left fork!")
            self.state = .takingForks(leftTaken: true, rightTaken: rightForkIsTaken)
        case self.rightFork:
            self.context.log.info("\(self.context.address.name) received their right fork!")
            self.state = .takingForks(leftTaken: leftForkIsTaken, rightTaken: true)
        default:
            self.context.log.error("Received unknown fork! Got: \(fork). Known forks: \(self.leftFork), \(self.rightFork)")
        }

        if case .takingForks(true, true) = self.state {
            becomeEating()
        }
    }

    private func becomeEating() {
        self.state = .eating
        self.context.log.info("\(self.context.address.name) began eating!")
        self.context.timers.startSingle(key: TimerKey("eat"), message: .stopEating, delay: .seconds(3))
    }

}

extension Philosopher {
    private enum State: Equatable {
        case thinking
        case takingForks(leftTaken: Bool, rightTaken: Bool)
        case eating
    }
}
