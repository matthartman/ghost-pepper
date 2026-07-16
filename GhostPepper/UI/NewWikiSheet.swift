import SwiftUI

/// Approval flow for dynamically created wikis. Shows pending model-proposed
/// wiki kinds (approve/dismiss), lets the user ask the local model for
/// suggestions on demand, and supports defining a wiki manually. Approving
/// registers the kind and kicks off a background backfill from the existing
/// meeting cards — nothing is created without an explicit approve.
struct NewWikiSheet: View {
    @ObservedObject var state: MeetingWindowState
    @Environment(\.dismiss) private var dismiss

    @State private var isGenerating = false
    @State private var generateMessage: String?
    @State private var approvedSlugs: Set<String> = []

    // Manual creation fields.
    @State private var customName: String = ""
    @State private var customNoun: String = ""
    @State private var customHint: String = ""
    @State private var customIcon: String = "folder"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundColor(.orange)
            Text("New 2nd Brain")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }

            Text("2nd Brains are folders of dossiers built from your meetings by the local model — like the People index, for any category. Approve a suggestion or define your own.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            proposalsSection

            Divider()

            customSection

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Proposals

    @ViewBuilder
    private var proposalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Suggestions")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    generateProposals()
                } label: {
                    if isGenerating {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.55)
                            Text("Analyzing meetings…")
                        }
                    } else {
                        Label("Suggest 2nd Brains", systemImage: "wand.and.stars")
                    }
                }
                .disabled(isGenerating)
                .font(.system(size: 12))
            }

            if let generateMessage {
                Text(generateMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if state.wikiProposals.isEmpty && !isGenerating {
                Text("No pending suggestions. The local model proposes 2nd Brains once it has digested enough meetings — or ask it now.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ForEach(state.wikiProposals) { proposal in
                proposalRow(proposal)
            }
        }
    }

    private func proposalRow(_ proposal: WikiKindProposal) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: proposal.spec.iconSystemName)
                .font(.system(size: 14))
                .foregroundColor(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.spec.displayName)
                    .font(.system(size: 13, weight: .medium))
                if !proposal.rationale.isEmpty {
                    Text(proposal.rationale)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if approvedSlugs.contains(proposal.spec.slug) {
                Label("Building…", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            } else {
                Button("Dismiss") {
                    WikiKindStore.shared.removeProposal(slug: proposal.spec.slug)
                    state.loadIndexes()
                }
                .font(.system(size: 11))
                Button("Approve") {
                    approve(proposal.spec)
                }
                .font(.system(size: 11))
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }

    // MARK: - Manual creation

    @ViewBuilder
    private var customSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Define your own")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                TextField("Name (e.g. Companies)", text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                TextField("Singular (e.g. company)", text: $customNoun)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 150)
            }

            TextField("What counts as one? (guides extraction)", text: $customHint)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            HStack(spacing: 8) {
                Picker("Icon", selection: $customIcon) {
                    ForEach(WikiKindSpec.allowedIcons, id: \.self) { icon in
                        Image(systemName: icon).tag(icon)
                    }
                }
                .frame(maxWidth: 140)

                Spacer()

                Button("Create 2nd Brain") {
                    let name = customName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    let spec = WikiKindSpec(
                        slug: MarkdownArchivePaths.slugForIndexEntry(name),
                        displayName: name,
                        entityNoun: customNoun.trimmingCharacters(in: .whitespaces).lowercased(),
                        iconSystemName: customIcon,
                        extractionHint: customHint.trimmingCharacters(in: .whitespaces),
                        createdAt: Date()
                    )
                    approve(spec)
                    customName = ""
                    customNoun = ""
                    customHint = ""
                }
                .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
    }

    // MARK: - Actions

    private func approve(_ spec: WikiKindSpec) {
        approvedSlugs.insert(spec.slug)
        state.onApproveWikiKind?(spec)
        state.loadIndexes()
    }

    private func generateProposals() {
        guard let generate = state.onGenerateWikiProposals else { return }
        isGenerating = true
        generateMessage = nil
        Task { @MainActor in
            defer { isGenerating = false }
            do {
                let proposals = try await generate()
                state.loadIndexes()
                if proposals.isEmpty {
                    generateMessage = "Nothing new to suggest — either too few meetings are digested yet, or the existing 2nd Brains already cover the archive."
                }
            } catch {
                generateMessage = "Suggestion run failed: \(error.localizedDescription)"
            }
        }
    }
}
