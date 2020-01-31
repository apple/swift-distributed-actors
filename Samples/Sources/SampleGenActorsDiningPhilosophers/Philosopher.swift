import DistributedActors

class Philosopher: Actorable {
    private let context: Myself.Context
    private let leftFork: Actor<Fork>
    private let rightFork: Actor<Fork>
    private var state: State = .thinking

    init(context: Myself.Context, leftFork: Actor<Fork>, rightFork: Actor<Fork>) {
        self.context = context
        self.leftFork = leftFork
        self.rightFork = rightFork
    }

    func preStart(context: Actor<Philosopher>.Context) {
        context.watch(leftFork)
        context.watch(rightFork)
        context.log.info("\(context.address.name) joined the table!")
        think()
    }

    private func think() {
        if case let .takingForks(leftIsTaken, rightIsTaken) = state {
            if leftIsTaken {
                leftFork.putBack()
                context.log.info("\(context.address.name) put back their left fork!")
            }

            if rightIsTaken {
                rightFork.putBack()
                context.log.info("\(context.address.name) put back their right fork!")
            }
        }

        state = .thinking
        context.timers.startSingle(key: TimerKey("think"), message: .attemptToTakeForks, delay: .seconds(1))
        context.log.info("\(context.address.name) is thinking...")
    }

    func attemptToTakeForks() {
        guard state == .thinking else {
            context.log.error("\(context.address.name) tried to take a fork but was not in the thinking state!")
            return
        }

        state = .takingForks(leftTaken: false, rightTaken: false)

        func attemptToTake(fork: Actor<Fork>) {
            context.onResultAsync(of: fork.take(), timeout: .seconds(5)) { result in
                switch result {
                case let .failure(error):
                    self.context.log.warning("Failed to reach for fork! Error: \(error)")
                case let .success(didTakeFork):
                    if didTakeFork {
                        self.forkTaken(fork)
                    } else {
                        self.context.log.info("\(self.context.address.name) wasn't able to take a fork!")
                        self.think()
                    }
                }
            }
        }

        attemptToTake(fork: leftFork)
        attemptToTake(fork: rightFork)
    }

    private func forkTaken(_ fork: Actor<Fork>) {
        if state == .thinking { // We couldn't get the first fork and have already gone back to thinking.
            fork.putBack()
            return
        }

        guard case let .takingForks(leftForkIsTaken, rightForkIsTaken) = state else {
            context.log.error("Received fork \(fork) but was not in .takingForks state. State was \(self.state)! Ignoring...")
            fork.putBack()
            return
        }

        switch fork {
        case leftFork:
            self.context.log.info("\(self.context.address.name) received their left fork!")
            state = .takingForks(leftTaken: true, rightTaken: rightForkIsTaken)
        case rightFork:
            self.context.log.info("\(self.context.address.name) received their right fork!")
            state = .takingForks(leftTaken: leftForkIsTaken, rightTaken: true)
        default:
            context.log.error("Received unknown fork! Got: \(fork). Known forks: \(leftFork), \(rightFork)")
        }

        if case .takingForks(true, true) = state {
            becomeEating()
        }
    }

    private func becomeEating() {
        state = .eating
        context.log.info("\(context.address.name) began eating!")
        context.timers.startSingle(key: TimerKey("eat"), message: .stopEating, delay: .seconds(3))
    }

    func stopEating() {
        leftFork.putBack()
        rightFork.putBack()
        context.log.info("\(context.address.name) is done eating and replaced both forks!")
        think()
    }
}

extension Philosopher {
    private enum State: Equatable {
        case thinking
        case takingForks(leftTaken: Bool, rightTaken: Bool)
        case eating
    }
}
