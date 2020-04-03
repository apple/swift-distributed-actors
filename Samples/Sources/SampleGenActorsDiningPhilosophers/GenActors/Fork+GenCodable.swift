// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors                     
// ==== ------------------------------------------------------------------ ====

import DistributedActors

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Codable conformance for Fork.Message
// TODO: This will not be required, once Swift synthesizes Codable conformances for enums with associated values 

extension Fork.Message {
    // TODO: Check with Swift team which style of discriminator to aim for
    public enum DiscriminatorKeys: String, Decodable {
        case take
        case putBack

    }

    public enum CodingKeys: CodingKey {
        case _case
        case take__replyTo

    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: CodingKeys._case) {
        case .take:
            let _replyTo = try container.decode(ActorRef<Bool>.self, forKey: CodingKeys.take__replyTo)
            self = .take(_replyTo: _replyTo)
        case .putBack:
            self = .putBack

        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .take(let _replyTo):
            try container.encode(DiscriminatorKeys.take.rawValue, forKey: CodingKeys._case)
            try container.encode(_replyTo, forKey: CodingKeys.take__replyTo)
        case .putBack:
            try container.encode(DiscriminatorKeys.putBack.rawValue, forKey: CodingKeys._case)

        }
    }
}
