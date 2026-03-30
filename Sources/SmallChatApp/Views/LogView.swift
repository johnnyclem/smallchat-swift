import SwiftUI

struct LogView: View {
    let lines: [String]
    let title: String

    init(_ lines: [String], title: String = "Output") {
        self.lines = lines
        self.title = title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(lines.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(lineColor(line))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func lineColor(_ line: String) -> Color {
        if line.contains("WARNING") || line.contains("WARN") {
            return .orange
        } else if line.contains("ERROR") || line.contains("FAILED") {
            return .red
        } else if line.contains("OK") || line.contains("complete") || line.contains("success") {
            return .green
        }
        return .primary
    }
}
