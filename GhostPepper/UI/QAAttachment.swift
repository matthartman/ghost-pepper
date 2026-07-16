import SwiftUI

/// One piece of context the user has attached to a Q&A turn via the @-mention
/// picker. Holds enough for the agent to fetch the source via its existing
/// `read_file` tool, plus a label for the chip UI.
struct QAAttachment: Identifiable, Equatable {
    let id: String
    let title: String
    let relativePath: String
    let kindGlyph: String

    @MainActor
    static func from(entry: CommandKHaystackEntry, archiveRoot: URL) -> QAAttachment? {
        switch entry.kind {
        case .wiki(let item, let folderTitle):
            guard let rel = relative(item.fileURL, to: archiveRoot) else { return nil }
            return QAAttachment(
                id: "wiki-\(item.fileURL.path)",
                title: item.title,
                relativePath: rel,
                kindGlyph: folderTitle == "People" ? "person.crop.circle" : "books.vertical"
            )
        case .person(let kind, let item):
            let url = MarkdownArchivePaths.entryURL(in: archiveRoot, kind: kind, slug: item.slug)
            guard let rel = relative(url, to: archiveRoot) else { return nil }
            return QAAttachment(
                id: "person-\(kind.rawValue)-\(item.slug)",
                title: item.canonicalName,
                relativePath: rel,
                kindGlyph: "person.crop.circle"
            )
        case .meeting(let history, _):
            guard let rel = relative(history.fileURL, to: archiveRoot) else { return nil }
            return QAAttachment(
                id: "file-\(history.fileURL.path)",
                title: history.name,
                relativePath: rel,
                kindGlyph: "doc.text"
            )
        case .note(let history, _):
            guard let rel = relative(history.fileURL, to: archiveRoot) else { return nil }
            return QAAttachment(
                id: "file-\(history.fileURL.path)",
                title: history.name,
                relativePath: rel,
                kindGlyph: "note.text"
            )
        }
    }

    private static func relative(_ url: URL, to root: URL) -> String? {
        let urlPath = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard urlPath.hasPrefix(prefix) else { return nil }
        return String(urlPath.dropFirst(prefix.count))
    }
}

struct AttachmentChip: View {
    let attachment: QAAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.kindGlyph)
                .font(.system(size: 10))
                .foregroundColor(.orange)
            Text(attachment.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(10)
        .help(attachment.relativePath)
    }
}
