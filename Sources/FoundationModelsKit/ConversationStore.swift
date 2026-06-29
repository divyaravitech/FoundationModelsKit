// ConversationStore.swift
// Manages the turn-by-turn transcript for a single conversation session.
//
// Context-window management strategy:
//   When the transcript grows too large, the oldest entries are summarised
//   into a single "[COMPACTED SUMMARY]" entry by any LanguageModelProviding
//   conformer, keeping the most recent turns intact for coherence.

import Foundation

// MARK: - Entry

/// A single turn in a conversation — either a user message or a model reply.
public struct ConversationEntry: Sendable, Codable {
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

    // Number of recent entries to preserve untouched during compaction.
    // Keeping the tail ensures the model retains immediate context.
    private static let recentEntriesToKeep = 5

    private var entries: [ConversationEntry] = []

    public init() {}

    // MARK: - Public API

    /// Appends a new entry to the transcript.
    public func addEntry(_ entry: ConversationEntry) {
        entries.append(entry)
    }

    /// Returns the full conversation formatted as plain text.
    /// Each turn is rendered as `[role] content`, separated by blank lines.
    public func transcript() -> String {
        entries.map { "[\($0.role)] \($0.content)" }.joined(separator: "\n\n")
    }

    /// Number of entries currently in the store. Useful for tests and telemetry.
    public var entryCount: Int { entries.count }

    /// Returns `true` when the transcript is long enough that context-window
    /// overflow is a risk.
    ///
    /// Heuristic: 1 token ≈ 4 characters (conservative English estimate).
    public func shouldCompact(maxTokens: Int) -> Bool {
        transcript().count > maxTokens * 4
    }

    /// Summarises the oldest entries into a single compacted entry using
    /// `model`, then replaces them in-place.
    ///
    /// The most recent `recentEntriesToKeep` entries are never touched so
    /// that the model retains the immediate conversational context.
    ///
    /// - Parameters:
    ///   - model: Any backend conforming to `LanguageModelProviding`.
    ///   - maxTokens: Passed through to `shouldCompact` — used here only to
    ///     guard against compacting an already-small transcript.
    public func compact(using model: any LanguageModelProviding, maxTokens: Int) async throws {
        // Nothing to compact if the store is tiny.
        guard entries.count > Self.recentEntriesToKeep else { return }
        guard shouldCompact(maxTokens: maxTokens) else { return }

        let splitIndex = entries.index(entries.endIndex, offsetBy: -Self.recentEntriesToKeep)
        let oldEntries = Array(entries[..<splitIndex])
        let recentEntries = Array(entries[splitIndex...])

        let historyText = oldEntries
            .map { "[\($0.role)] \($0.content)" }
            .joined(separator: "\n")

        let prompt = """
        The following is a conversation history that needs to be condensed. \
        Summarise it in 2–3 bullet points, preserving key decisions, facts, \
        and context that would be needed to continue the conversation naturally. \
        Be concise.

        \(historyText)
        """

        let request = ModelRequest(
            content: prompt,
            privacySensitivity: .high,  // treat history as sensitive by default
            taskComplexity: .simple
        )

        let response = try await model.sendMessage(request: request)
        let summaryText = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

        let summaryEntry = ConversationEntry(
            role: "assistant",
            content: "[COMPACTED SUMMARY] \(summaryText)",
            timestamp: Date(),
            toolsUsed: nil
        )

        entries = [summaryEntry] + recentEntries
    }
}
