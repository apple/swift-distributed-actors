import DistributedActors

struct Fork: Actorable {
    private let context: Myself.Context
    private var isTaken: Bool = false

    init(context: Myself.Context) {
        self.context = context
    }

    mutating func take() -> Bool {
        if self.isTaken {
            return false
        }

        self.isTaken = true
        return true
    }

    mutating func putBack() {
        assert(self.isTaken, "Attempted to put back a fork that is not taken!")
        self.isTaken = false
    }
}
