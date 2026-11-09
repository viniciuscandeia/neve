import SwiftUI
import NeveCore

/// What both Ajustes UIs need from the controller. Bool options are @AppStorage on the app's defaults store (same keys as always);
/// the controller reacts through its UserDefaults observer. Target screen and login go through controller closures.
struct SettingsEnv {
    let store: UserDefaults
    let screens: [(title: String, id: String)]
    let reduceMotion: Bool
    let isDev: Bool
    let target: Binding<String>
    let login: Binding<Bool>
    let openWindow: () -> Void
    let panel: PanelState
    let askAccessibility, clear, quit: () -> Void
}

/// Live status shown at the top of the popover; the controller keeps it current (updateStatus / syncOverlays).
@MainActor final class PanelState: ObservableObject {
    @Published var status = ""
    @Published var axMissing = false
    @Published var metalMissing = false
    @Published var musicNote = ""
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

private struct Tile: View {
    let option: Option
    @Binding var on: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Button { on.toggle() } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: option.symbol).font(.system(size: 17, weight: .medium))
                Text(option.title).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            }
            .padding(10)
            .foregroundStyle(on ? AnyShapeStyle(onTileText) : AnyShapeStyle(.primary))
            .tileBackground(on: on, contrast: contrast, radius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityValue(on ? "ligado" : "desligado")
        .accessibilityAddTraits(.isToggle)
    }
}

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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quantidade")
        .accessibilityValue(current)
    }
}

/// Shown wherever the Accessibility permission is offered; the app works fully without it.
let axHint = "Opcional. Deixa a neve acompanhar janelas e o Dock com mais rapidez."

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
            if panel.axMissing {
                VStack(alignment: .leading, spacing: 6) {
                    Text(axHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    FooterRow("Permitir Acessibilidade…", "hand.raised", action: env.askAccessibility)
                }
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    let title: String, symbol: String, chevron: Bool, shortcut: String?, action: () -> Void
    @State private var hover = false
    init(_ title: String, _ symbol: String, chevron: Bool = false, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.chevron = chevron; self.shortcut = shortcut; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
                if chevron { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(hover ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The popover: Control-Center-style tiles. Sized by its content (the hosting controller reports preferredContentSize).
struct QuickSettingsView: View {
    let env: SettingsEnv

    private func switchRow(_ title: String, _ on: Binding<Bool>) -> some View {
        HStack { Text(title).font(.callout); Spacer(); Toggle(title, isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.small) }
    }

    var body: some View {
        let tiles = figures + [economyOpt, ambientOpt] + (env.reduceMotion ? [stillOpt] : []) + (MusicTap.supported && !env.reduceMotion ? [musicOpt] : [])
        VStack(spacing: 12) {
            Header(panel: env.panel, env: env)
            Divider()
            VStack(spacing: 6) {
                IntensityTile(store: env.store)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(tiles, id: \.pref) { o in PrefBinding(o.pref, env.store) { Tile(option: o, on: $0) } }
                }
                if MusicTap.supported && !env.reduceMotion { MusicNote(panel: env.panel, reduceMotion: false).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4) }
            }
            VStack(spacing: 6) {
                PrefBinding(.behindWindows, env.store) { switchRow("Atrás das janelas", $0) }
                PrefBinding(.behindLarge, env.store) { switchRow("Atrás de janelas grandes", $0) }
            }
            .padding(.horizontal, 4)
            Divider()
            VStack(spacing: 2) {
                FooterRow("Limpar neve", "eraser", shortcut: "⌘K", action: env.clear).keyboardShortcut("k")
                FooterRow("Ajustes…", "gearshape", shortcut: "⌘,", action: env.openWindow).keyboardShortcut(",")
                FooterRow("Sair", "power", shortcut: "⌘Q", action: env.quit).keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 320)
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

    private func toggle(_ o: Option) -> some View {
        PrefBinding(o.pref, env.store) { b in Toggle(isOn: b) { Label(o.title, systemImage: o.symbol) } }
    }

    private enum Tab: String, CaseIterable { case geral = "Geral", bonecos = "Bonecos", desempenho = "Desempenho", sistema = "Sistema", brincar = "Dicas" }
    @State private var tab = Tab.geral

    var body: some View {
        VStack(spacing: 0) {
            Picker("Seção", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], 16)
            Form {
                switch tab {
                case .geral:
                    PrefBinding(.economy, env.store) { eco in
                        Picker(selection: env.target) {
                            Text("Todas as telas").tag("all")
                            Text("Só na tela principal").tag("main")
                            ForEach(env.screens, id: \.id) { Text($0.title).tag($0.id) }
                        } label: { Label("Nevar em", systemImage: "display") }
                            .disabled(eco.wrappedValue)
                        if eco.wrappedValue { Text("O modo econômico usa só a tela principal.").font(.caption).foregroundStyle(.secondary) }
                    }
                    PrefBinding(.behindWindows, env.store) { b in Toggle(isOn: b) { Label("Atrás das janelas", systemImage: "square.stack.3d.down.right") } }
                    PrefBinding(.behindLarge, env.store) { b in Toggle(isOn: b) { Label("Atrás de janelas grandes", systemImage: "macwindow") } }
                case .bonecos:
                    ForEach(figures, id: \.pref) { toggle($0) }
                case .desempenho:
                    toggle(economyOpt)
                    toggle(ambientOpt)
                    PrefBinding(.music, env.store) { b in
                        Toggle(isOn: b) { Label(musicOpt.title, systemImage: musicOpt.symbol) }
                            .disabled(!MusicTap.supported || env.reduceMotion)
                    }
                    MusicNote(panel: env.panel, reduceMotion: env.reduceMotion)
                    if env.reduceMotion { toggle(stillOpt) }
                case .sistema:
                    PrefBinding(.showInCaptures, env.store) { b in Toggle(isOn: b) { Label("Aparecer em capturas de tela", systemImage: "camera") } }
                    AccessRow(panel: env.panel, ask: env.askAccessibility)
                    if !env.isDev { Toggle(isOn: env.login) { Label("Abrir ao iniciar sessão", systemImage: "power.circle") } }
                case .brincar:
                    Label { HStack(spacing: 4) { Text("Segure"); Kbd("⌥"); Text("e arraste a neve para fazer bolas.") } } icon: { Image(systemName: "hand.draw") }
                    Label("Arraste uma janela devagar: a neve vai junto.", systemImage: "macwindow.on.rectangle")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460)
        .frame(minHeight: 290)
    }
}
