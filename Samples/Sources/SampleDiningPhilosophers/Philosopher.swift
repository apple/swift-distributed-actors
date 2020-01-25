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
        context.timers.startSingle(key: TimerKey("think"), message: .attemptToTakeForks, delay: .seconds(1))
        context.log.info("\(context.address.name) joined the table!")
    }

    func think() {
        state = .thinking
        context.timers.startSingle(key: TimerKey("think"), message: .attemptToTakeForks, delay: .seconds(1))
        context.log.info("\(context.address.name) is thinking...")
    }

    func attemptToTakeForks() {
        guard state == .thinking else {
            // Ignore eat messages if not thinking
            return
        }

        func forkTaken(_ fork: Actor<Fork>) {
            guard case .takingForks(let alreadyTakenLeft, let alreadyTakenRight) = self.state else {
                context.log.warning("Received fork \(fork) yet not in .takingForks state, was in: \(self.state)! Ignoring...")
                // TODO: we could also immediately try to put it back before ignoring it, if we want to?
                return
            }

            switch fork {
            case self.leftFork:
                self.state = .takingForks(alreadyTakenLeft || true, alreadyTakenRight)
            case self.rightFork:
                self.state = .takingForks(alreadyTakenLeft || true, alreadyTakenRight)
            default:
                context.log.warning("Received unknown fork! Got: \(fork), known forks: \(self.leftFork), \(self.rightFork)")
                return // TODO: I'd throw and crash in this situation :-) "let it crash!"
            }

            if case .takingForks(true, true) = state {
                self.eat()
            } // else, we're still waiting for the other fork
        }

        self.state = .takingForks(nil, nil)

        // so we can model this in a number of ways...
        // perhaps the nicest for async work is to reply with an
        // struct ForkTakeReply { let taken: Bool; let fork: Actor<Fork> }
        // that's super easy to correlate then when the replies come back, and we only have to write the code for
        // "a fork replied" once, but handling which one it was...
        //
        // one may prefer:
        // - to write 2 callbacks for each fork which "know which one we're receiving", OR
        // - have them reply `Bool` AND do (leftReply: Reply<Bool>).map { ($0, leftFork) }
        //                                 (rightReply: Reply<Bool>).map { ($0, rightFork) }
        //    // ^^^ about the Reply.map() this on purpose does not exist today... as we are in the process of building
        // a Future library as well which would make things safer to use etc. So Reply would then be that future,
        // TODAY this is doable by dropping to ._nioFuture.map and wrapping back again... so yeah a bit meh
        //
        // I think I'd suggest the proper reply type, rather than boolean which will make things easier in such concurrently
        // asking many forks use cases. Sending references to Actor<> is safe, cheap, and well expected after all :-)
        let leftTakeReply: Reply<ForkTakeReply> = self.leftFork.take()
        let rightTakeReply: Reply<ForkTakeReply> = self.rightFork.take()

        let onForkResultCompleted: (Result<ForkReply>) -> () = {
            switch $0 {
            case .success(let reply) where reply.taken:
                forkTaken(reply.fork)
            case .success(let reply):
                context.log.warning("Did not obtain fork \(reply.fork)")
            case .failure(let error):
                throw error // crash the actor on a timeout?
            }
        }
        context.onResultAsync(of: leftTakeReply, timeout: .seconds(1), onForkResultCompleted)
        context.onResultAsync(of: rightTakeReply, timeout: .seconds(1), onForkResultCompleted)
    }

    func eat() {
        context.log.info("\(context.address.name) began eating!")
        context.timers.startSingle(key: TimerKey("eat"), message: .stopEating, delay: .seconds(3))
    }

    func stopEating() {
        // Probably need to check that this actually succeeds before going back to thinking
        guard case .eating = self.state else {
            context.log.warning("Cannot stop eating, am in \(self.state)!")
            return
        }

        leftFork.putBack()
        rightFork.putBack()
        context.log.info("\(context.address.name) is done eating and replaced both forks!")
        think()
    }
}

extension Philosopher {
    private enum State: Equatable {
        case thinking
        case takingForks(leftObtained: Bool, rightObtained: Bool)
//        case takingLeftFork
//        case takingRightFork
        case eating
    }
}

struct Fork: Actorable {
}
