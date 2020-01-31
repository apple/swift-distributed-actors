import DistributedActors

struct Fork: Actorable {

    private let context: Myself.Context
    private var isTaken: Bool = false

    init(context: Myself.Context) {
        self.context = context
    }

    mutating func take() -> Bool {
        if isTaken {
            return false
        }

        isTaken = true
        return true
    }

    mutating func putBack() {
        assert(isTaken, "Attempted to put back a fork that is not taken!")
        isTaken = false
    }
}
