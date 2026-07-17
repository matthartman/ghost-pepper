import SwiftUI

/// Wraps the right-side panel of the meeting window with a top toggle that
/// switches between the existing "Models" inventory and the new "Usage report"
/// pane. Both children are pushed the same dependency objects (cleanup +
/// speech managers, usage stats, speech-download wrapper) so the parent owns
/// the data graph and the children stay focused on rendering.
struct RightSidebarView: View {
    @ObservedObject var cleanupManager: TextCleanupManager
    @ObservedObject var modelManager: ModelManager
    @ObservedObject var usageStats: UsageStatsStore
    let onDownloadSpeechModel: (String) -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case models
        case usage

        var id: String { rawValue }
        var title: String {
            switch self {
            case .models: return "Models"
            case .usage: return "Usage report"
            }
        }
    }

    @State private var selectedTab: Tab = .models
    @AppStorage(AppTheme.storageKey) private var selectedThemeID = AppThemeID.current.rawValue

    private var appTheme: AppTheme {
        AppTheme.resolve(selectedThemeID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            switch selectedTab {
            case .models:
                ModelsSidebarView(
                    cleanupManager: cleanupManager,
                    modelManager: modelManager,
                    onDownloadSpeechModel: onDownloadSpeechModel
                )
            case .usage:
                UsageReportView(usageStats: usageStats, cleanupManager: cleanupManager)
            }
        }
        .background(appTheme.controlBackground)
        .tint(appTheme.accent)
    }
}
