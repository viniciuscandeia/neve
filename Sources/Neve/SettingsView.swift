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
                       Option(pref: .visitors, title: "Visitantes", symbol: "hare"),
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
    var body: some View {
        Button { on.toggle() } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: option.symbol).font(.system(size: 17, weight: .medium))
                Text(option.title).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            }
            .padding(10)
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityValue(on ? "ligado" : "desligado")
        .accessibilityAddTraits(.isToggle)
    }
}

private struct IntensityTile: View {
    @AppStorage(Intensity.key) private var level = 1
    init(store: UserDefaults) { _level = AppStorage(wrappedValue: 1, Intensity.key, store: store) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quantidade").font(.callout.weight(.medium))
            HStack(spacing: 6) {
                ForEach(Intensity.allCases, id: \.rawValue) { v in
                    let sel = level == v.rawValue
                    Button { level = v.rawValue } label: {
                        Image(systemName: intensitySymbols[v.rawValue]).font(.system(size: 16))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .foregroundStyle(sel ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .background(sel ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(v.title)
                    .accessibilityLabel("Quantidade: \(v.title)")
                    .accessibilityAddTraits(sel ? .isSelected : [])
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct Header: View {
    @ObservedObject var panel: PanelState
    let env: SettingsEnv
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PrefBinding(.enabled, env.store) { on in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nevar").font(.callout.weight(.medium))
                        Text(panel.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Nevar", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.small).keyboardShortcut("n")
                }
            }
            if panel.axMissing { FooterRow("Permitir neve no Dock…", "exclamationmark.triangle", action: env.askAccessibility) }
            if panel.metalMissing { Label("Metal indisponível", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 4)
    }
}

private struct MusicNote: View {
    @ObservedObject var panel: PanelState
    let reduceMotion: Bool
    var body: some View {
        let t = !MusicTap.supported ? "Neve dança com a música: requer macOS 14.2 ou mais recente." : reduceMotion ? "Indisponível com Reduzir movimento." : panel.musicNote
        if !t.isEmpty { Text(t).font(.caption).foregroundStyle(.secondary) }
    }
}

private struct FooterRow: View {
    let title: String, symbol: String, chevron: Bool, action: () -> Void
    init(_ title: String, _ symbol: String, chevron: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.chevron = chevron; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack { Label(title, systemImage: symbol); Spacer(); if chevron { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 4)
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
        VStack(spacing: 8) {
            Header(panel: env.panel, env: env)
            Divider()
            IntensityTile(store: env.store)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(tiles, id: \.pref) { o in PrefBinding(o.pref, env.store) { Tile(option: o, on: $0) } }
            }
            VStack(spacing: 2) {
                PrefBinding(.behindWindows, env.store) { switchRow("Atrás das janelas", $0) }
                PrefBinding(.behindLarge, env.store) { switchRow("Neve atrás de janelas grandes", $0) }
            }
            .padding(.horizontal, 4).padding(.top, 2)
            Divider()
            FooterRow("Limpar neve", "sparkles", action: env.clear).keyboardShortcut("k")
            FooterRow("Ajustes", "gearshape", chevron: true, action: env.openWindow).keyboardShortcut(",")
            FooterRow("Sair", "power", action: env.quit).keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 320)
    }
}

// MARK: window (full)

/// The "Ajustes" window: every option, by tab.
struct SettingsWindowView: View {
    let env: SettingsEnv

    private func toggle(_ o: Option) -> some View {
        PrefBinding(o.pref, env.store) { b in Toggle(isOn: b) { Label(o.title, systemImage: o.symbol) } }
    }

    private enum Tab: String, CaseIterable { case geral = "Geral", bonecos = "Bonecos", desempenho = "Desempenho", sistema = "Sistema", brincar = "Como brincar" }
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
                    }
                    PrefBinding(.behindWindows, env.store) { b in Toggle(isOn: b) { Label("Atrás das janelas", systemImage: "square.stack.3d.down.right") } }
                    PrefBinding(.behindLarge, env.store) { b in Toggle(isOn: b) { Label("Neve atrás de janelas grandes", systemImage: "macwindow") } }
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
                    PrefBinding(.showInCaptures, env.store) { b in Toggle(isOn: b) { Label("Mostrar em capturas", systemImage: "camera") } }
                    if !env.isDev { Toggle(isOn: env.login) { Label("Abrir no login", systemImage: "arrow.right.circle") } }
                case .brincar:
                    Text("Segure ⌥ e arraste a neve para fazer bolas.")
                    Text("Arraste uma janela devagar: a neve vai junto.")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460, height: 290)
    }
}
