import AppKit
import SwiftUI

/// Always-on indicator in the bottom-right corner of the active screen. A small pill in standby
/// that opens into a waveform while recording and flattens while transcribing. Never takes clicks or focus.
@MainActor
final class PillPanel {
    /// Room for the open pill; the pill itself hugs the bottom-right corner of this box.
    private static let size = NSSize(width: 120, height: 40)
    private static let inset: CGFloat = 12

    private let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

    init(state: AppState) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PillView(state: state))
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        place()
        panel.orderFrontRegardless()
    }

    /// Moves to the screen the user is working on. Called on launch, display changes and each dictation.
    func place() {
        guard let frame = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.maxX - Self.size.width - Self.inset, y: frame.minY + Self.inset))
    }
}

private struct PillView: View {
    let state: AppState

    private static let barCount = 11
    private static let midnight = Color(red: 0.05, green: 0.09, blue: 0.22)
    private static let standbyBorder = Color(red: 0.42, green: 0.49, blue: 0.66)
    private static let openBorder = Color(red: 0.18, green: 0.25, blue: 0.42)

    private var isOpen: Bool { state.phase == .recording || state.phase == .transcribing }

    var body: some View {
        HStack(spacing: 2) {
            if isOpen {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(.white)
                        .frame(width: 3, height: barHeight(index))
                        .opacity(state.phase == .transcribing ? 0.45 : 1)
                }
            }
        }
        .frame(width: isOpen ? 96 : 40, height: isOpen ? 26 : 9)
        .background(Capsule().fill(Self.midnight))
        .overlay(Capsule().strokeBorder(isOpen ? Self.openBorder : Self.standbyBorder, lineWidth: 1.5))
        .opacity(state.phase == .loading ? 0.5 : 1)
        .animation(.spring(duration: 0.25, bounce: 0.35), value: isOpen)
        .animation(.linear(duration: 0.08), value: state.levels)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    /// The newest level sits in the middle bar and older ones ripple outward, so loud syllables spread from the center.
    private func barHeight(_ index: Int) -> CGFloat {
        guard state.phase == .recording else { return 3 }
        let distance = abs(index - Self.barCount / 2)
        let falloff = 1 - CGFloat(distance) * 0.08
        return 3 + 17 * CGFloat(state.levels[distance]) * falloff
    }
}
