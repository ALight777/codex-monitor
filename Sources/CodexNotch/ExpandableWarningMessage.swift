import AppKit
import SwiftUI

struct ExpandableWarningMessage: View {
    let message: String
    @State private var showsDetails = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(message)
                    .font(.system(size: showsDetails ? 11 : 9.6, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.70, blue: 0.38))
                    .lineLimit(showsDetails ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .help(message)
                Button {
                    copied = false
                    showsDetails.toggle()
                } label: {
                    Image(systemName: showsDetails ? "chevron.up" : "info.circle")
                        .font(.system(size: 12))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 1.0, green: 0.70, blue: 0.38))
                .accessibilityLabel(showsDetails ? "收起错误详情" : "查看完整错误")
                .help(showsDetails ? "收起错误详情" : "查看并复制完整错误")
            }
            if showsDetails {
                Button(copied ? "已复制" : "复制错误") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                    copied = true
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(red: 1.0, green: 0.55, blue: 0.25).opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(red: 1.0, green: 0.55, blue: 0.25).opacity(0.16), lineWidth: 1)
        )
    }
}
