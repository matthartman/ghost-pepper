import SwiftUI

struct ModelInventoryCard: View {
    let rows: [RuntimeModelRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                ModelInventoryRow(row: row)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct ModelInventoryRow: View {
    let row: RuntimeModelRow

    var body: some View {
        HStack(spacing: 8) {
            ModelInventoryStatusIndicator(status: row.status)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.callout)
                        .foregroundStyle(.primary)

                    if row.isSelected {
                        Text("Selected")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(row.sizeDescription)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var statusText: String {
        switch row.status {
        case .loaded:
            return "Loaded"
        case .loading:
            return "Loading"
        case .notLoaded:
            return "Not loaded"
        case .downloading(let progress?):
            return "Downloading \(Int(progress * 100))%"
        case .downloading(nil):
            return "Preparing"
        }
    }
}

private struct ModelInventoryStatusIndicator: View {
    let status: RuntimeModelStatus

    var body: some View {
        Group {
            switch status {
            case .loaded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .loading:
                ProgressView()
                    .controlSize(.mini)
            case .notLoaded:
                Image(systemName: "circle")
                    .foregroundStyle(.quaternary)
            case .downloading(let progress):
                PieProgressIndicator(progress: progress)
            }
        }
        .font(.caption)
        .frame(width: 14, height: 14)
    }
}

private struct PieProgressIndicator: View {
    let progress: Double?
    @State private var rotation = Angle.zero

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)

            if let progress {
                PieSliceShape(progress: max(0.05, min(progress, 1)))
                    .fill(Color.orange)
            } else {
                PieSliceShape(progress: 0.28)
                    .fill(Color.orange)
                    .rotationEffect(rotation)
                    .onAppear {
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            rotation = .degrees(360)
                        }
                    }
            }
        }
    }
}

private struct PieSliceShape: Shape {
    let progress: Double

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let startAngle = Angle.degrees(-90)
        let endAngle = Angle.degrees(-90 + max(0, min(progress, 1)) * 360)

        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
