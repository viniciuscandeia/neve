import SwiftUI
import NeveCore

/// What both Ajustes UIs need from the controller. Bool options are @AppStorage on the app's defaults store (same keys as always);
/// the controller reacts through its UserDefaults observer. Target screen and login go through controller closures.
struct SettingsEnv {
    let store: UserDefaults
    let isDev: Bool
    let target: Binding<String>
    let login: Binding<Bool>
    let openWindow: () -> Void
    let panel: PanelState
    let askAccessibility, clear, quit: () -> Void
}

/// Live status shown at the top of the menu panel; the controller keeps it current (updateStatus / syncOverlays).
@MainActor final class PanelState: ObservableObject {
    @Published var status = ""
    @Published var axMissing = false
    @Published var metalMissing = false
    @Published var musicNote = ""
    @Published var reduceMotion = false
    @Published var screens: [(title: String, id: String)] = []   // empty with one screen
    @Published var loginOn = false
    @Published var loginNote = ""
}

/// Hands a Bool pref's binding (backed by the app's defaults store) to `content`.
private struct PrefBinding<Content: View>: View {
    @AppStorage private var on: Bool
    let content: (Binding<Bool>) -> Content
    init(_ p: Pref, _ store: UserDefaults, @ViewBuilder content: @escaping (Binding<Bool>) -> Content) {
        _on = AppStorage(wrappedValue: p.defaultValue, p.rawValue, store: store)
        self.content = content
    }
    var body: some View { content($on) }
}

private struct Option { let pref: Pref; let title: String; let symbol: String }
private let figures = [Option(pref: .snowman, title: "Boneco de neve", symbol: "figure.stand"),
                       Option(pref: .walk, title: "Andam e brigam", symbol: "figure.walk"),
                       Option(pref: .visitors, title: "Visitantes", symbol: "pawprint"),
                       Option(pref: .sleigh, title: "Trenó do Papai Noel", symbol: "gift")]
private let economyOpt = Option(pref: .economy, title: "Modo econômico", symbol: "leaf")
private let ambientOpt = Option(pref: .ambient, title: "Modo ambiente", symbol: "sun.max")
private let musicOpt = Option(pref: .music, title: "Neve dança com a música", symbol: "music.note")
private let stillOpt = Option(pref: .stillSnow, title: "Neve parada", symbol: "pause.circle")
private let intensitySymbols = ["snowflake", "cloud.snow", "cloud.snow.fill", "wind.snow"]

// MARK: popover (quick)

private let onTileText = Color(nsColor: .alternateSelectedControlTextColor)

private extension View {
    /// Accent when on; subtle fill when off (stronger fill plus a 1pt border with Increase Contrast).
    func tileBackground(on: Bool, contrast: ColorSchemeContrast, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let hi = contrast == .increased
        return background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(hi ? 0.18 : 0.08)), in: shape)
            .overlay { if hi && !on { shape.strokeBorder(Color.primary, lineWidth: 1) } }
    }
}

private struct IntensityTile: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(Intensity.key) private var level = 1
    @FocusState private var focused: Bool
    init(store: UserDefaults) { _level = AppStorage(wrappedValue: 1, Intensity.key, store: store) }
    var body: some View {
        let current = Intensity(rawValue: level)?.title ?? ""
        VStack(alignment: .leading, spacing: 8) {
            (Text("Quantidade").font(.callout.weight(.medium)) + Text(" · \(current)").font(.caption).foregroundColor(.secondary))
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                ForEach(Intensity.allCases, id: \.rawValue) { v in
                    let sel = level == v.rawValue
                    Button { level = v.rawValue } label: {
                        Image(systemName: intensitySymbols[v.rawValue]).font(.system(size: 16))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .foregroundStyle(sel ? AnyShapeStyle(onTileText) : AnyShapeStyle(.primary))
                            .tileBackground(on: sel, contrast: contrast, radius: 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(v.title)
                    .accessibilityLabel(v.title)
                    .accessibilityAddTraits(sel ? .isSelected : [])
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .focusable()
        .focused($focused)
        .onMoveCommand { d in
            if d == .left { level = steppedLevel(level, by: -1) } else if d == .right { level = steppedLevel(level, by: 1) }
        }
        .onAppear { for d in [0.0, 0.25] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { focused = true } } }   // 2nd try: the panel is key only after it has opened
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in focused = true }   // the panel opens on Quantidade: ←/→ work at once
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quantidade")
        .accessibilityValue(current)
        .accessibilityAdjustableAction { d in level = steppedLevel(level, by: d == .increment ? 1 : -1) }
    }
}

/// Shown wherever the Accessibility permission is offered; the app works fully without it.
let axHint = "Opcional. Sem ela, não há neve no Dock e as janelas são seguidas com menos rapidez."

private struct Header: View {
    @ObservedObject var panel: PanelState
    let env: SettingsEnv
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PrefBinding(.enabled, env.store) { on in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nevar").font(.callout.weight(.medium))
                        Text(panel.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Nevar", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .contentShape(Rectangle())
                .onTapGesture { on.wrappedValue.toggle() }
            }
            if panel.metalMissing { Label("Este Mac não consegue desenhar a neve. Ela fica desativada.", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 4)
    }
}

private struct AccessRow: View {
    @ObservedObject var panel: PanelState
    let ask: () -> Void
    var body: some View {
        if panel.axMissing {
            Button(action: ask) { Label("Permitir Acessibilidade…", systemImage: "hand.raised") }
            Text(axHint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MusicNote: View {
    @ObservedObject var panel: PanelState
    let reduceMotion: Bool
    var body: some View {
        let t = !MusicTap.supported ? "Precisa do macOS 14.2 ou mais novo." : reduceMotion ? "Desativado porque Reduzir movimento está ligado." : panel.musicNote
        if !t.isEmpty { Text(t).font(.caption).foregroundStyle(.secondary) }
    }
}

private struct FooterRow: View {
    let title: String, symbol: String, shortcut: String?, badge: Bool, action: () -> Void
    @State private var hover = false
    init(_ title: String, _ symbol: String, shortcut: String? = nil, badge: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.shortcut = shortcut; self.badge = badge; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                if badge { Circle().fill(Color.orange).frame(width: 6, height: 6).accessibilityHidden(true) }
                Spacer()
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The menu panel: Nevar, Quantidade and three actions; every other option lives in the Ajustes window. Sized by its content.
struct QuickSettingsView: View {
    let env: SettingsEnv
    @ObservedObject var panel: PanelState

    init(env: SettingsEnv) { self.env = env; panel = env.panel }

    var body: some View {
        VStack(spacing: 12) {
            Header(panel: panel, env: env)
            IntensityTile(store: env.store)
            Divider()
            VStack(spacing: 2) {
                FooterRow("Limpar neve", "eraser", shortcut: "⌘K", action: env.clear).keyboardShortcut("k")
                FooterRow("Ajustes…", "gearshape", shortcut: "⌘,", badge: panel.axMissing, action: env.openWindow).keyboardShortcut(",")
                    .accessibilityHint(panel.axMissing ? "Falta a permissão de Acessibilidade, opcional." : "")
                FooterRow("Sair", "power", shortcut: "⌘Q", action: env.quit).keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

// MARK: window (full)

/// A key cap: the symbol on a small rounded background.
private struct Kbd: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key).font(.callout.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// The "Ajustes" window: every option, by tab.
struct SettingsWindowView: View {
    let env: SettingsEnv
    @ObservedObject var panel: PanelState
    init(env: SettingsEnv) { self.env = env; panel = env.panel }

    private func toggle(_ o: Option) -> some View {
        PrefBinding(o.pref, env.store) { b in Toggle(isOn: b) { Label(o.title, systemImage: o.symbol) } }
    }

    private enum Tab: String, CaseIterable { case geral = "Geral", bonecos = "Bonecos", desempenho = "Desempenho", sistema = "Sistema", dicas = "Dicas" }
    @State private var tab = Tab.geral

    var body: some View {
        VStack(spacing: 0) {
            Picker("Seção", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], 16)
            Form {
                switch tab {
                case .geral:
                    if !panel.screens.isEmpty {
                        PrefBinding(.economy, env.store) { eco in
                            Picker(selection: eco.wrappedValue ? .constant("main") : env.target) {
                                Text("Todas as telas").tag("all")
                                Text("Tela principal").tag("main")
                                ForEach(panel.screens, id: \.id) { Text($0.title).tag($0.id) }
                            } label: { Label("Nevar em", systemImage: "display") }
                                .disabled(eco.wrappedValue)
                            if eco.wrappedValue { Text("O modo econômico usa só a tela principal.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    PrefBinding(.behindWindows, env.store) { behind in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(isOn: behind) { Label("Atrás das janelas", systemImage: "square.stack.3d.down.right") }
                            Text("A neve cai só no chão, por trás das janelas.").font(.caption).foregroundStyle(.secondary)
                        }
                        PrefBinding(.behindLarge, env.store) { b in
                            VStack(alignment: .leading, spacing: 2) {
                                Toggle(isOn: b) { Label("Atrás de janelas grandes", systemImage: "macwindow") }.disabled(behind.wrappedValue)
                                Text(behind.wrappedValue ? "Já incluído em Atrás das janelas." : "Os flocos passam por trás de janelas grandes.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                case .bonecos:
                    ForEach(figures, id: \.pref) { toggle($0) }
                case .desempenho:
                    toggle(economyOpt)
                    Text("20–30 fps, só a tela principal, menos efeitos.").font(.caption).foregroundStyle(.secondary)
                    toggle(ambientOpt)
                    PrefBinding(.music, env.store) { b in
                        Toggle(isOn: b) { Label(musicOpt.title, systemImage: musicOpt.symbol) }
                            .disabled(!MusicTap.supported || panel.reduceMotion)
                    }
                    MusicNote(panel: env.panel, reduceMotion: panel.reduceMotion)
                    PrefBinding(.pointerPush, env.store) { b in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(isOn: b) { Label("Cursor empurra os flocos", systemImage: "cursorarrow.motionlines") }
                            Text("Desligado, os flocos no ar ignoram o cursor; ele ainda varre a neve acumulada.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if panel.reduceMotion { toggle(stillOpt) }
                case .sistema:
                    PrefBinding(.showInCaptures, env.store) { b in Toggle(isOn: b) { Label("Aparecer em capturas de tela", systemImage: "camera") } }
                    AccessRow(panel: env.panel, ask: env.askAccessibility)
                    if !env.isDev {
                        Toggle(isOn: Binding(get: { panel.loginOn }, set: { env.login.wrappedValue = $0 })) { Label("Abrir ao iniciar sessão", systemImage: "power.circle") }
                        if !panel.loginNote.isEmpty { Text(panel.loginNote).font(.caption).foregroundStyle(.secondary) }
                    }
                case .dicas:
                    Label { HStack(spacing: 4) { Text("Segure"); Kbd("⌥"); Text("e arraste a neve para fazer bolas.") } } icon: { Image(systemName: "hand.draw") }
                    Label("Arraste uma janela devagar: a neve vai junto.", systemImage: "macwindow.on.rectangle")
                    Label("Varra o cursor sobre um presente para estourá-lo em confete.", systemImage: "gift")
                    Label { HStack(spacing: 4) { Kbd("⌥"); Text("e clique em um presente para abri-lo.") } } icon: { Image(systemName: "cursorarrow.click") }
                    Label { HStack(spacing: 4) { Text("Segure"); Kbd("⌥"); Text("com o cursor parado perto de um boneco: ele joga uma bola em você.") } } icon: { Image(systemName: "snowflake") }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460)
        .frame(minHeight: 400)
    }
}
