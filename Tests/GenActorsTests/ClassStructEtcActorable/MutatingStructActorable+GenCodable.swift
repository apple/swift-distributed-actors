// ==== ------------------------------------------------------------------ ====
// === DO NOT EDIT: Generated by GenActors
// ==== ------------------------------------------------------------------ ====

import DistributedActors

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DO NOT EDIT: Codable conformance for MutatingStructActorable.Message
// TODO: This will not be required, once Swift synthesizes Codable conformances for enums with associated values

extension MutatingStructActorable.Message: Codable {
    // TODO: Check with Swift team which style of discriminator to aim for
    public enum DiscriminatorKeys: String, Decodable {
        case hello
    }

    public enum CodingKeys: CodingKey {
        case _case
        case hello__replyTo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: CodingKeys._case) {
        case .hello:
            let _replyTo = try container.decode(ActorRef<String>.self, forKey: CodingKeys.hello__replyTo)
            self = .hello(_replyTo: _replyTo)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let _replyTo):
            try container.encode(DiscriminatorKeys.hello.rawValue, forKey: CodingKeys._case)
            try container.encode(_replyTo, forKey: CodingKeys.hello__replyTo)
        }
    }
}
