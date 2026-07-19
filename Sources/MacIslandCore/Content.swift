import Foundation

/// The visible content of a card — the "what it says" axis, orthogonal to
/// presence, alerting, and actions. Two text tiers (not the reference's three:
/// the notch card is small), an optional icon, and an optional tint.
/// Only `title` is required — a bare title is a valid notification.
/// See the domain-model spec §Content.
public struct Content: Equatable, Codable, Sendable {
    /// The one always-present line.
    public var title: String
    /// Optional secondary line (a source with subtitle+detail joins them here).
    public var body: String?
    /// Optional icon — nil / symbol / image are all valid.
    public var icon: Icon?
    /// Optional tint as a hex string `"#RRGGBB"`; nil = theme default. A string
    /// (not a live `Color`) so the value serializes cleanly.
    public var tint: String?

    public init(title: String, body: String? = nil, icon: Icon? = nil, tint: String? = nil) {
        self.title = title
        self.body = body
        self.icon = icon
        self.tint = tint
    }
}

/// A card's icon. Raster images are supported from day one but always optional.
public enum Icon: Equatable, Codable, Sendable {
    /// SF Symbol name — the lightweight path.
    case symbol(String)
    /// A raster image.
    case image(ImageSource)
}

/// Where a raster icon's bytes come from. **Never a remote URL** — the core does
/// no network; a source resolves web images itself into `.data`/`.file`.
public enum ImageSource: Equatable, Codable, Sendable {
    /// A local file path — the ingress path; the core loads + caches it. The
    /// *absence* of a remote-URL case is the structural half of "never network";
    /// the complementary guard — rejecting a non-`file:` scheme fail-soft — lives
    /// in the (later) image loader at post time, not in this value (unified §8.3).
    case file(URL)
    /// In-memory bytes — for in-process Swift sources.
    case data(Data)
}
