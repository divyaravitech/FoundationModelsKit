// PrivacyChat — a SwiftUI chat app that shows, live, which inference tier
// each message is routed to as you change its privacy level.
//
// Run:  swift run PrivacyChat

import SwiftUI
import FoundationModelsKit

@main
struct PrivacyChatApp: App {
    // An SPM executable has no .app bundle, so AppKit treats it as a background
    // agent: the window never comes to the front. This promotes it to a regular
    // app on launch so `swift run PrivacyChat` behaves like a normal app.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("PrivacyChat — FoundationModelsKit") {
            ContentView()
                .frame(minWidth: 620, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - View model

@Observable
@MainActor
final class ChatViewModel {

    struct Message: Identifiable {
        let id = UUID()
        let role: String
        let text: String
        let tier: ModelTier?
        let sensitivity: PrivacySensitivity?
    }

    var messages: [Message] = []
    var draft: String = ""
    var sensitivity: PrivacySensitivity = .high
    var complexity: TaskComplexity = .simple
    var isSending = false

    /// The tier the *current* draft would be routed to, recomputed live.
    var previewTier: ModelTier?

    private let router: ModelRouter

    init() {
        // Labelled stand-ins so each tier announces itself without needing
        // Apple Intelligence hardware or an API key.
        self.router = ModelRouter(
            onDevice:   DemoBackend(tier: "on-device"),
            pcc:        DemoBackend(tier: "Private Cloud Compute"),
            thirdParty: DemoBackend(tier: "third-party API")
        )

        // Set PRIVACYCHAT_DEMO=1 to preload a conversation that exercises all
        // three tiers — used for documentation screenshots.
        if ProcessInfo.processInfo.environment["PRIVACYCHAT_DEMO"] == "1" {
            seedDemoConversation()
        }
    }

    private func seedDemoConversation() {
        messages = [
            .init(role: "user",
                  text: "What's on my calendar tomorrow?",
                  tier: .onDevice, sensitivity: .high),
            .init(role: "assistant",
                  text: "Handled by on-device. In a real app this would be the model's reply.",
                  tier: .onDevice, sensitivity: nil),
            .init(role: "user",
                  text: "Draft a detailed project retrospective covering our Q3 launch, the incidents we hit, and what we'd change — aim for several paragraphs.",
                  tier: .pcc, sensitivity: .medium),
            .init(role: "assistant",
                  text: "Handled by Private Cloud Compute. In a real app this would be the model's reply.",
                  tier: .pcc, sensitivity: nil),
        ]
        complexity = .complex
        draft = "Summarise my medical notes from the last six months, including every medication change and the reasoning behind each one."

        // PRIVACYCHAT_DEMO_SENSITIVITY lets a screenshot script capture the
        // same draft at different privacy levels for before/after comparisons.
        switch ProcessInfo.processInfo.environment["PRIVACYCHAT_DEMO_SENSITIVITY"] {
        case "low":    sensitivity = .low
        case "medium": sensitivity = .medium
        default:       sensitivity = .high
        }
    }

    /// Recomputes the routing preview whenever the draft or controls change.
    func refreshPreview() async {
        let request = ModelRequest(
            content: draft.isEmpty ? " " : draft,
            privacySensitivity: sensitivity,
            taskComplexity: complexity
        )
        previewTier = await router.resolvedTier(for: request)
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        isSending = true
        defer { isSending = false }

        let request = ModelRequest(
            content: text,
            privacySensitivity: sensitivity,
            taskComplexity: complexity
        )
        let tier = await router.resolvedTier(for: request)

        messages.append(Message(role: "user", text: text, tier: tier, sensitivity: sensitivity))
        draft = ""
        await refreshPreview()

        do {
            let response = try await router.routeRequest(request)
            messages.append(Message(role: "assistant", text: response.content, tier: tier, sensitivity: nil))
        } catch {
            messages.append(Message(
                role: "error",
                text: "No eligible backend for a \(sensitivity.rawValue)-sensitivity request of this size.",
                tier: nil,
                sensitivity: nil
            ))
        }
    }
}

// MARK: - Demo backend

/// Stand-in backend that reports which tier handled the request.
/// Swap for `OnDeviceLanguageModel()` or `AnthropicLanguageModel(...)` for real inference.
private struct DemoBackend: LanguageModelProviding {
    let tier: String

    func sendMessage(request: ModelRequest) async throws -> ModelResponse {
        try await Task.sleep(for: .milliseconds(400))
        return ModelResponse(
            content: "Handled by \(tier). In a real app this would be the model's reply.",
            stopReason: "end_turn",
            usage: .estimated(promptChars: request.content.count, completionChars: 70)
        )
    }
}

// MARK: - Tier presentation

extension ModelTier {
    var label: String {
        switch self {
        case .onDevice:   "On-device"
        case .pcc:        "Private Cloud Compute"
        case .thirdParty: "Third-party API"
        }
    }

    var icon: String {
        switch self {
        case .onDevice:   "iphone"
        case .pcc:        "lock.icloud"
        case .thirdParty: "globe"
        }
    }

    var tint: Color {
        switch self {
        case .onDevice:   .green
        case .pcc:        .blue
        case .thirdParty: .orange
        }
    }

    var explanation: String {
        switch self {
        case .onDevice:   "Data never leaves this device."
        case .pcc:        "Apple-operated servers. No third party involved."
        case .thirdParty: "Sent to an external company's servers."
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @State private var model = ChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            routingBanner
            Divider()
            transcript
            Divider()
            controls
        }
        .task { await model.refreshPreview() }
    }

    // Live routing indicator — the centrepiece of the demo.
    private var routingBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: model.previewTier?.icon ?? "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(model.previewTier?.tint ?? .red)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.previewTier?.label ?? "No eligible backend")
                    .font(.headline)
                Text(model.previewTier?.explanation ?? "This request cannot be fulfilled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("routes to")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background((model.previewTier?.tint ?? .red).opacity(0.10))
        .animation(.easeInOut(duration: 0.2), value: model.previewTier)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                }
                .padding(18)
            }
            .onChange(of: model.messages.count) {
                if let last = model.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try this")
                .font(.headline)
            Text("Send a short message at **High** sensitivity — it stays on-device.\n\nNow switch to **Low** and set complexity to **Complex**, then send a long message. Watch the banner escalate to the cloud.\n\nSwitch back to **High** with the same long message: it refuses to leave the device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 30)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Privacy sensitivity").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $model.sensitivity) {
                        Text("High").tag(PrivacySensitivity.high)
                        Text("Medium").tag(PrivacySensitivity.medium)
                        Text("Low").tag(PrivacySensitivity.low)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Task complexity").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $model.complexity) {
                        Text("Simple").tag(TaskComplexity.simple)
                        Text("Medium").tag(TaskComplexity.medium)
                        Text("Complex").tag(TaskComplexity.complex)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            HStack(spacing: 10) {
                TextField("Type a message…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { Task { await model.send() } }

                Button {
                    Task { await model.send() }
                } label: {
                    if model.isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.draft.isEmpty || model.isSending)
            }
        }
        .padding(18)
        .onChange(of: model.draft)       { Task { await model.refreshPreview() } }
        .onChange(of: model.sensitivity) { Task { await model.refreshPreview() } }
        .onChange(of: model.complexity)  { Task { await model.refreshPreview() } }
    }
}

// MARK: - Message row

struct MessageRow: View {
    let message: ChatViewModel.Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == "user" { Spacer(minLength: 60) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 5) {
                if let tier = message.tier, message.role == "user" {
                    HStack(spacing: 4) {
                        Image(systemName: tier.icon).font(.caption2)
                        Text(tier.label).font(.caption2)
                    }
                    .foregroundStyle(tier.tint)
                }

                Text(message.text)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(background)
                    .foregroundStyle(message.role == "user" ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .textSelection(.enabled)
            }

            if message.role != "user" { Spacer(minLength: 60) }
        }
    }

    private var background: Color {
        switch message.role {
        case "user":  .accentColor
        case "error": .red.opacity(0.15)
        default:      .secondary.opacity(0.14)
        }
    }
}
