import CoreGraphics

/// Geometry of the main window's two presentation states.
///
/// The window is **compact** by default — status, connect button and the four
/// switches, "all essential controls, always at hand" — and grows into the full
/// dashboard on demand. The maths lives here, free of SwiftUI/AppKit, so the
/// app target and the SPM test suite share one definition of the sizes and the
/// clamping rules instead of duplicating magic numbers in `AppDelegate`.
public enum MainWindowLayout {

    // MARK: Target sizes

    /// Compact: single column, no dashboard.
    public static let compactWidth: CGFloat = 380
    public static let compactHeight: CGFloat = 520

    /// Expanded: dashboard with the stat cards, request table and log.
    public static let expandedWidth: CGFloat = 940
    public static let expandedHeight: CGFloat = 780

    /// Space the window leaves around itself so it never fills the display
    /// edge to edge (menu bar, Dock, room to drag).
    public static let minimumScreenMargin = CGSize(width: 80, height: 150)

    // MARK: Sizing

    /// Content size for the window in the given presentation state, clamped so
    /// it fits a display of `screen` size (pass `nil` when unknown).
    ///
    /// The clamp never shrinks the window below the compact size: a small
    /// display still gets a usable window, and the dashboard's content scrolls.
    public static func targetSize(expanded: Bool, screen: CGSize? = nil) -> CGSize {
        let base = expanded
            ? CGSize(width: expandedWidth, height: expandedHeight)
            : CGSize(width: compactWidth, height: compactHeight)
        return clamped(base, to: screen)
    }

    /// Clamps `size` to fit `screen`, honouring `minimumScreenMargin` and
    /// keeping the compact size as the floor.
    public static func clamped(_ size: CGSize, to screen: CGSize?) -> CGSize {
        guard let screen, screen.width > 0, screen.height > 0 else { return size }
        let widest = max(compactWidth, screen.width - minimumScreenMargin.width)
        let tallest = max(compactHeight, screen.height - minimumScreenMargin.height)
        return CGSize(width: min(size.width, widest), height: min(size.height, tallest))
    }
}
