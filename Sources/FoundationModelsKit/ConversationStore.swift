// ConversationStore.swift
// Manages the turn-by-turn transcript for a single conversation session.
//
// Context-window management strategy:
//   When the transcript grows too large, the oldest entries are summarised
//   into a single "[COMPACTED SUMMARY]" entry, keeping the most recent turns
//   intact for immediate coherence.

import Foundation

// MARK: - Entry

/// A single turn in a conversation — either a user message or a model reply.
public struct ConversationEntry: Sendable, Codable, Equatable {
    /// `"user"` or `"assistant"`.
    public var role: String

    /// The text content of this turn.
    public var content: String

    /// Wall-clock time the entry was created.
    public var timestamp: Date

    /// Names of any tools the model invoked during this turn.
    public var toolsUsed: [String]?

    public init(
        role: String,
        content: String,
        timestamp: Date = Date(),
        toolsUsed: [String]? = nil
    ) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolsUsed = toolsUsed
    }
}

// MARK: - Store

/// Actor-isolated transcript store with automatic context-window compaction.
///
/// Usage:
/// ```swift
/// let store = ConversationStore()
/// await store.addEntry(ConversationEntry(role: "user", content: "Hello"))
///
/// if await store.shouldCompact(maxTokens: 4096) {
///     try await store.compact(using: model, maxTokens: 4096)
/// }
///
/// let text = await store.transcript()
/// ```
public actor ConversationStore: Sendable {

    // Recent entries preserved verbatim during compaction so the model
    // always sees the most immediate conversational context.
    private static let recentEntriesToKeep = 5

    private var entries: [ConversationEntry] = []

    public init() {}

    // MARK: - Public API

    /// Appends a new entry to the transcript.
    public func addEntry(_ entry: ConversationEntry) {
        entries.append(entry)
    }

    /// Removes the last entry. Used to roll back a dangling user turn when
    /// the subsequent model call throws.
    public func removeLastEntry() {
        guard !entries.isEmpty else { return }
        entries.removeLast()
    }

    /// Removes all entries, resetting the conversation to empty.
    public func clear() {
        entries = []
    }

    // MARK: - Persistence

    /// Encodes the transcript to JSON and writes it to `url`.
    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: url, options: .atomic)
    }

    /// Replaces the current transcript with entries decoded from `url`.
    /// Throws if the file is missing or malformed.
    public func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        entries = try JSONDecoder().decode([ConversationEntry].self, from: data)
    }

    /// Returns the full conversation formatted as plain text.
    /// Each turn is rendered as `[role] content`, separated by blank lines.
    public func transcript() -> String {
        entries.map { "[\($0.role)] \($0.content)" }.joined(separator: "\n\n")
    }

    /// Number of entries currently in the store.
    public var entryCount: Int { entries.count }

    /// Returns `true` when the transcript is long enough that context-window
    /// overflow is a risk.
    ///
    /// Heuristic: 1 token ≈ 4 characters (conservative English estimate).
    public func shouldCompact(maxTokens: Int) -> Bool {
        // Avoid materialising the full transcript string; sum content lengths instead.
        let totalChars = entries.reduce(0) { $0 + $1.content.count }
        return totalChars > maxTokens * 4
    }

    /// Summarises the oldest entries into a single compacted entry using
    /// `model`, then replaces them in-place.
    ///
    /// The `maxTokens` guard inside `compact` is intentionally removed — the
    /// caller (`SDKIntegration`) already checked `shouldCompact` before calling,
    /// and re-checking inside the actor would recompute O(n) state for no benefit.
    public func compact(using model: any LanguageModelProviding, maxTokens: Int) async throws {
        guard entries.count > Self.recentEntriesToKeep else { return }

        let splitIndex = entries.index(entries.endIndex, offsetBy: -Self.recentEntriesToKeep)
        let oldEntries = Array(entries[..<splitIndex])
        let recentEntries = Array(entries[splitIndex...])

        let historyText = oldEntries
            .map { "[\($0.role)] \($0.content)" }
            .joined(separator: "\n")

        let prompt = """
        The following is a conversation history that needs to be condensed. \
        Summarise it in 2–3 bullet points, preserving key decisions, facts, \
        and context needed to continue the conversation naturally. Be concise.

        \(historyText)
        """

        let request = ModelRequest(
            content: prompt,
            privacySensitivity: .high,
            taskComplexity: .simple
        )

        let response = try await model.sendMessage(request: request)
        let summaryText = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

        let summaryEntry = ConversationEntry(
            role: "assistant",
            content: "[COMPACTED SUMMARY] \(summaryText)",
            timestamp: Date()
        )

        entries = [summaryEntry] + recentEntries
    }
}
