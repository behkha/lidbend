import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, about
    var id: String { rawValue }
}

/// System Settings-style window: a sidebar of pages on the left, the selected
/// page on the right.
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var controller = AppController.shared
    @State private var page: SettingsPage? = SettingsView.lastPage

    /// The window reopens on the page it was closed on.
    private static var lastPage: SettingsPage {
        SettingsPage(rawValue: UserDefaults.standard.string(forKey: "settingsPage") ?? "") ?? .appearance
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    SidebarRow(title: "General", symbol: "gearshape.fill", color: .gray)
                        .tag(SettingsPage.general)
                }
                Section {
                    SidebarRow(title: "Appearance", symbol: "circle.lefthalf.filled", color: .blue)
                        .tag(SettingsPage.appearance)
                } header: {
                    SidebarHeader("Settings")
                }
                Section {
                    SidebarRow(title: "About", symbol: "info.circle.fill", color: .gray)
                        .tag(SettingsPage.about)
                } header: {
                    SidebarHeader("Lidbend")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            ScrollView {
                Group {
                    switch page ?? .appearance {
                    case .general:
                        GeneralPage(settings: settings, controller: controller)
                    case .appearance:
                        AppearancePage(settings: settings, controller: controller)
                    case .about:
                        AboutPage(settings: settings)
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 24, bottom: 28, trailing: 24))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 700, height: 640)
        .onChange(of: page) { _, newValue in
            UserDefaults.standard.set((newValue ?? .appearance).rawValue, forKey: "settingsPage")
        }
    }
}

// MARK: - Sidebar

private struct SidebarRow: View {
    var title: String
    var symbol: String
    var color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(symbol: symbol, color: color, size: 22)
        }
        .padding(.vertical, 2)
    }
}

private struct SidebarHeader: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.top, 6)
    }
}

/// The coloured rounded square that System Settings puts in front of a row.
private struct SettingsIcon: View {
    var symbol: String
    var color: Color
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.56, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

private struct PageHeader: View {
    var title: String
    var symbol: String
    var color: Color

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: color, size: 26)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
        }
        .padding(.bottom, 18)
    }
}

// MARK: - Appearance

private struct AppearancePage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: AppController

    private var followingLid: Bool { settings.angleSource == .sensor }

    private var followLid: Binding<Bool> {
        Binding(get: { followingLid },
                set: { settings.angleSource = $0 ? .sensor : .manual })
    }

    /// Dragging sets the manual angle; while following the lid, the slider
    /// just shows the live reading.
    private var angle: Binding<Double> {
        Binding(get: {
            followingLid ? (controller.lidAngle ?? controller.restAngle) : settings.manualAngle
        }, set: { settings.manualAngle = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Appearance", symbol: "circle.lefthalf.filled", color: .blue)

            MacBookFrame {
                BendPreview(controller: controller)
            }
            .padding(.horizontal, 36)
            .frame(maxWidth: .infinity)

            HStack(spacing: 14) {
                Text("\(Int(angle.wrappedValue.rounded()))°")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                Slider(value: angle, in: 0...180)
                    .disabled(followingLid)
                Toggle("Follow lid", isOn: followLid)
                    .toggleStyle(.switch)
                    .disabled(!controller.sensorAvailable)
            }
            .padding(.top, 22)

            if let message = controller.statusMessage {
                StatusNotice(message: message, controller: controller)
                    .padding(.top, 14)
            }

            Text("Style")
                .font(.headline)
                .padding(.top, 26)
                .padding(.bottom, 10)

            HStack(spacing: 14) {
                ForEach(BendStyle.allCases) { style in
                    StyleCard(style: style, controller: controller,
                              selected: settings.style == style) {
                        settings.style = style
                    }
                }
            }

            SettingsGroup {
                SliderRow("Perspective", value: $settings.perspective, in: 0...1)
                SliderRow("Variable blur", value: $settings.blur, in: 0...1)
                SliderRow("Shadow", value: $settings.shadow, in: 0...1)
            }
            .padding(.top, 22)

            SettingsGroup {
                SliderRow("Intensity", value: $settings.intensity, in: 10...90) { "\(Int($0))°" }
                SliderRow("Softness", value: $settings.softness, in: 0...1)
                SettingsRow("Bend line") {
                    Picker("", selection: $settings.foldPreset) {
                        ForEach(FoldPreset.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                if settings.foldPreset == .custom {
                    SliderRow("Position", value: $settings.hingeV, in: 0...0.9)
                }
            }
            .padding(.top, 14)
        }
        .onAppear { controller.retainPreview() }
        .onDisappear { controller.releasePreview() }
    }
}

/// One of the three looks, rendered live at a fixed bend.
private struct StyleCard: View {
    var style: BendStyle
    @ObservedObject var controller: AppController
    var selected: Bool
    var action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            BendPreview(controller: controller, style: style, progress: 0.62,
                        source: .placeholder, framesPerSecond: 12)
                .aspectRatio(1.56, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                      lineWidth: selected ? 2 : 1))
                .padding(1)

            HStack(spacing: 5) {
                Text(style.title)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 12))
                }
            }
            .font(.system(size: 13))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .help(style.blurb)
    }
}

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "General", symbol: "gearshape.fill", color: .gray)

            SettingsGroup {
                ToggleRow("Effect enabled", isOn: $settings.enabled)
                ToggleRow("Sound when the desktop clears", isOn: $settings.playSound)
                ToggleRow("Launch at login", isOn: Binding(
                    get: { LoginItem.isEnabled },
                    set: { LoginItem.setEnabled($0) }))
            }

            GroupTitle("Trigger")
            SettingsGroup {
                SliderRow("Sensitivity", value: $settings.deadband, in: 2...30) { "\(Int($0))°" }
                SliderRow("Full bend at", value: $settings.closedThreshold, in: 5...80) { "\(Int($0))°" }
                SliderRow("Smoothing", value: $settings.motionSmoothing, in: 0...1)
            }
            Text("The effect starts once the lid drops the sensitivity distance below the angle you have been working at, and is fully bent by the time it reaches the closing angle.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            GroupTitle("Status")
            SettingsGroup {
                ValueRow("Hinge", value: controller.lidAngle.map { "\(Int($0.rounded()))°" }
                         ?? (settings.angleSource == .manual
                             ? "\(Int(settings.manualAngle.rounded()))° (manual)"
                             : "No sensor"))
                ValueRow("Resting angle", value: "\(Int(controller.restAngle.rounded()))°")
                ValueRow("Bend", value: "\(Int((controller.progress * 100).rounded()))%")
                ValueRow("Screen Recording",
                         value: controller.hasScreenRecordingPermission ? "Allowed" : "Not allowed")
            }

            if let message = controller.statusMessage {
                StatusNotice(message: message, controller: controller)
                    .padding(.top, 14)
            }
        }
    }
}

// MARK: - About

private struct AboutPage: View {
    @ObservedObject var settings: AppSettings

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "About", symbol: "info.circle.fill", color: .gray)

            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Lidbend")
                    .font(.system(size: 20, weight: .semibold))
                Text(version)
                    .foregroundStyle(.secondary)
                Text("Bends your live desktop as you close the lid, in the spirit of the fold on the dual-screen iPhone. The desktop is captured with ScreenCaptureKit, leaned away in Metal and driven by the hinge sensor.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)

            HStack {
                Button("Reset to Defaults") { settings.resetToDefaults() }
                Spacer()
                Button("Quit Lidbend") { NSApp.terminate(nil) }
            }
            .padding(.top, 40)
        }
    }
}

// MARK: - Building blocks

/// Rounded, inset group of rows with hairline dividers, like a grouped Form.
private struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        _VariadicView.Tree(GroupLayout()) { content() }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private struct GroupLayout: _VariadicView_UnaryViewRoot {
        @ViewBuilder
        func body(children: _VariadicView.Children) -> some View {
            VStack(spacing: 0) {
                ForEach(children) { child in
                    child
                    if child.id != children.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
    }
}

private struct GroupTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.headline)
            .padding(.top, 24)
            .padding(.bottom, 10)
    }
}

private struct SettingsRow<Control: View>: View {
    var title: String
    @ViewBuilder var control: () -> Control

    init(_ title: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.control = control
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .frame(width: 118, alignment: .leading)
            control()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16))
    }
}

private struct SliderRow: View {
    var title: String
    var value: Binding<Double>
    var range: ClosedRange<Double>
    var format: (Double) -> String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
         format: @escaping (Double) -> String = { String(format: "%.0f%%", $0 * 100) }) {
        self.title = title
        self.value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        SettingsRow(title) {
            HStack(spacing: 12) {
                Slider(value: value, in: range)
                Text(format(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

private struct ToggleRow: View {
    var title: String
    var isOn: Binding<Bool>

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self.isOn = isOn
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16))
    }
}

private struct ValueRow: View {
    var title: String
    var value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }
}

private struct StatusNotice: View {
    var message: String
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if controller.needsScreenRecording {
                HStack(spacing: 8) {
                    Button("Allow…") { controller.requestScreenRecordingPermission() }
                        .buttonStyle(.borderedProminent)
                    Button("System Settings") { controller.openScreenRecordingSettings() }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
