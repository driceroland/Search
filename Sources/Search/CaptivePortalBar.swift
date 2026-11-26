import SwiftUI

/// "Wi-Fi sign-in required": a pill at the foot of the window, over nothing
/// the page needs. Offers the login page; goes away by itself once a probe
/// gets through (CaptivePortal), or with ✕ until the next gateway.
struct CaptivePortalBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var portal = CaptivePortal.shared

    var body: some View {
        Group {
            if portal.portalURL != nil {
                HStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                    Text("Wi-Fi sign-in required")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                    Button("Open Login Page") { portal.openPortal(in: browser) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ground)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Palette.ink, in: Capsule())
                    Button { portal.dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .padding(.vertical, 9)
                .background(Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 20, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: portal.portalURL)
    }
}
