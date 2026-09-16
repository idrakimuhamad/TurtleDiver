import SwiftUI

// MARK: - Metrics

/// Shared numbers and colours for the Settings panes, so the window looks like
/// one app instead of nine screens.
enum SettingsStyle {
    static let cardRadius: CGFloat = 10
    static let cardFill = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.09)
    static let hairline = Color.primary.opacity(0.30)
    /// Forms get unreadable when a row stretches across a wide window.
    static let contentMaxWidth: CGFloat = 620
    static let panePadding: CGFloat = 22
    /// Every pane starts its header at the same distance from the titlebar.
    /// `SettingsListPane` used to use 14 while `SettingsPane` used 18, which
    /// read as "no top padding" on the table panes.
    static let paneTopPadding: CGFloat = 18
    static let rowPaddingH: CGFloat = 12
    static let rowPaddingV: CGFloat = 9
}

// MARK: - Titlebar height

/// Reserves a minimum height in the toolbar of every pane, so that a pane whose
/// content declares no toolbar item does not end up with a shorter titlebar —
/// and therefore a higher pane header and sidebar — than one that does.
///
/// This is a *floor*, not a guarantee. `.unifiedCompact` still collapses the
/// toolbar's item row for a pane whose items are short (Policies is the one
/// that does it: 58 pt of chrome instead of 86 pt), and no item height fixes
/// it. Measurements and the open question live in `docs/SETTINGS_LAYOUT.md`.
///
/// It is positioned in the *navigation* section rather than `.principal` on
/// purpose: a `.principal` item reserves the middle of the toolbar, and the
/// title is happier without it. Any toolbar item contributes its height, so
/// the leading section holds the toolbar open just as well.
///
/// The item must also have its background switched off —
/// `sharedBackgroundVisibility(.hidden)` where available, see `detailPane`.
/// macOS 26 gives *every* toolbar item a glass capsule background regardless
/// of placement, and a 1×30 pt capsule draws as a pair of hairlines in the
/// titlebar. That is the whole reason this spacer was ever visible.
struct SettingsToolbarSpacer: View {
    static let height: CGFloat = 30

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 1, height: Self.height)
    }
}

extension SettingsTint {
    var color: Color {
        switch self {
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .purple: return .purple
        case .teal: return .teal
        case .indigo: return .indigo
        case .gray: return .gray
        case .red: return .red
        }
    }
}

// MARK: - Sidebar icon chip

/// The little tinted rounded square next to a sidebar row (System Settings
/// style). Cheap to draw, and it makes the sidebar scannable by shape and
/// colour instead of by text alone.
struct SettingsIconChip: View {
    let symbol: String
    let tint: SettingsTint
    var size: CGFloat = 19

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(tint.color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: tint.color.opacity(0.28), radius: 1, y: 0.5)
    }
}

// MARK: - Pane scaffolding

/// Title + one-line description of a pane. Also used on its own above the
/// table-style panes (Rules, Policies, …) so every pane starts the same way.
struct SettingsPaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            // The subtitle may wrap, but never to more than two lines and
            // never at the expense of the pane's minimum height: the window's
            // very first layout pass proposes a degenerate width, and a
            // `.fixedSize(vertical: true)` subtitle answered that by unfolding
            // to one line per word. The pane then reported that height as its
            // minimum and kept it, which is what used to push the sidebar's
            // search field under the titlebar on the one pane that happened to
            // be on screen during that pass. See `docs/SETTINGS_LAYOUT.md` §3.
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// A scrolling pane made of groups of settings rows.
struct SettingsPane<Content: View>: View {
    let title: String
    let subtitle: String
    private let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPaneHeader(title: title, subtitle: subtitle)
                content
            }
            .padding(.horizontal, SettingsStyle.panePadding)
            .padding(.top, SettingsStyle.paneTopPadding)
            .padding(.bottom, 26)
            .frame(maxWidth: SettingsStyle.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// A pane whose content is one of the existing `List`-based views: same header,
/// then the list fills the rest of the window.
struct SettingsListPane<Content: View>: View {
    let title: String
    let subtitle: String
    private let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPaneHeader(title: title, subtitle: subtitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsStyle.panePadding)
                .padding(.top, SettingsStyle.paneTopPadding)
                .padding(.bottom, 10)
            Divider().opacity(0.5)
            content
        }
    }
}

// MARK: - Groups and rows

struct SettingsCardLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .padding(.leading, 2)
    }
}

/// A titled card that holds rows, with an optional explanatory note below it.
struct SettingsCard<Content: View>: View {
    private let title: String?
    private let note: String?
    private let content: Content

    init(_ title: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                SettingsCardLabel(title)
            }
            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous)
                        .fill(SettingsStyle.cardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous)
                        .strokeBorder(SettingsStyle.cardStroke, lineWidth: 1)
                )
            if let note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// One row: label and optional caption on the left, a control on the right.
///
/// Rows draw their own bottom hairline, and the last row of a group passes
/// `isLast: true` so the card does not end with a stray line. (Interleaving
/// dividers automatically is not possible over a `ViewBuilder`'s children,
/// and being explicit is more predictable than counting them.)
struct SettingsRow<Trailing: View>: View {
    let label: String
    let caption: String?
    let isLast: Bool
    let controlWidth: CGFloat?
    let trailing: Trailing

    init(label: String,
         caption: String? = nil,
         isLast: Bool = false,
         controlWidth: CGFloat? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.caption = caption
        self.isLast = isLast
        self.controlWidth = controlWidth
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary)
                    if let caption {
                        Text(caption)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 10)
                // The control keeps its natural width and the caption wraps
                // instead: paths and ports are read as a unit and truncating
                // them mid-string is worse than a second line of caption.
                Group {
                    if let controlWidth {
                        trailing.frame(width: controlWidth, alignment: .trailing)
                    } else {
                        trailing
                    }
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, SettingsStyle.rowPaddingH)
            .padding(.vertical, SettingsStyle.rowPaddingV)

            if !isLast {
                Divider().opacity(0.35)
            }
        }
    }
}

extension SettingsRow where Trailing == EmptyView {
    /// A display-only row (used for section intros inside a card).
    init(label: String, caption: String? = nil, isLast: Bool = false) {
        self.init(label: label, caption: caption, isLast: isLast) { EmptyView() }
    }
}

struct SettingsToggleRow: View {
    let label: String
    var caption: String? = nil
    var isLast: Bool = false
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(label: label, caption: caption, isLast: isLast) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct SettingsButtonRow: View {
    let label: String
    var caption: String? = nil
    var isLast: Bool = false
    let title: String
    var role: ButtonRole? = nil
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        SettingsRow(label: label, caption: caption, isLast: isLast) {
            Button(title, role: role, action: action)
                .controlSize(.small)
                .disabled(!isEnabled)
        }
    }
}

/// Read-only technical value, monospaced and copyable — ports, paths, ids.
struct SettingsMonoValue: View {
    let value: String
    var isCopyable: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            if isCopyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Copy")
            }
        }
    }
}

/// Opens Finder at a path — the folder itself, or the folder containing a file.
struct SettingsRevealButton: View {
    enum Mode { case file, folder }

    let path: String
    var mode: Mode = .file
    var title: String = "Reveal"

    var body: some View {
        Button(title) {
            let url = URL(fileURLWithPath: path)
            switch mode {
            case .file:
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .folder:
                NSWorkspace.shared.open(url)
            }
        }
        .controlSize(.small)
        .help(path)
    }
}

/// Small coloured status chip.
struct SettingsPill: View {
    enum Tone {
        case ok, warn, error, neutral

        var color: Color {
            switch self {
            case .ok: return .green
            case .warn: return .orange
            case .error: return .red
            case .neutral: return .secondary
            }
        }
    }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.3)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(tone.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone.color.opacity(0.14)))
    }
}

/// A described option tile: icon, title, and the consequence in one or two
/// lines, with the chosen one outlined in the accent colour.
///
/// Used where a control picks between *behaviours* rather than values — a
/// segmented control can only name them, and the name ("Mode: split
/// tunneling") does not say what changes.
struct SettingsChoiceTile: View {
    let icon: String
    let title: String
    let detail: String
    let isSelected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 17)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(10)
            // `maxHeight` makes the shorter of two side-by-side tiles grow to
            // match the taller one, so the pair reads as one control.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.10),
                                  lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Password field with a reveal toggle, sized for a settings row.
struct SettingsSecureField: View {
    let prompt: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if revealed {
                    TextField(prompt, text: $text)
                } else {
                    SecureField(prompt, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .frame(width: 190)

            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(revealed ? "Hide" : "Show")
        }
    }
}

/// Footer for panes that do not apply changes instantly: a state indicator on
/// the left, Revert / Save on the right.
struct SettingsSaveBar: View {
    let isDirty: Bool
    var saveTitle: String = "Save"
    let save: () -> Void
    let revert: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isDirty ? "pencil.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isDirty ? Color.orange : Color.green)
            Text(isDirty ? "Unsaved changes" : "All changes saved")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button("Revert", action: revert)
                .controlSize(.small)
                .disabled(!isDirty)
            Button(saveTitle, action: save)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, SettingsStyle.panePadding)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}
