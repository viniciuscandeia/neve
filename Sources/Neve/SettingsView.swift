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
    let askAccessibility, restoreDefaults: () -> Void
}

/// Live status shown at the top of the menu; the controller keeps it current (updateStatus / syncOverlays).
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
private let figures = [Option(pref: .snowman, title: tr("Boneco de neve"), symbol: "figure.stand"),
                       Option(pref: .walk, title: tr("Andam e brigam"), symbol: "figure.walk"),
                       Option(pref: .visitors, title: tr("Visitantes"), symbol: "pawprint"),
                       Option(pref: .sleigh, title: tr("Trenó do Papai Noel"), symbol: "gift")]
private let economyOpt = Option(pref: .economy, title: tr("Modo econômico"), symbol: "leaf")
private let ambientOpt = Option(pref: .ambient, title: tr("Modo ambiente"), symbol: "sun.max")
private let musicOpt = Option(pref: .music, title: tr("Neve dança com a música"), symbol: "music.note")
private let stillOpt = Option(pref: .stillSnow, title: tr("Neve parada"), symbol: "pause.circle")
private let intensitySymbols = ["snowflake", "cloud.snow", "cloud.snow.fill", "wind.snow"]

// MARK: menu items

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

let menuWidth: CGFloat = 270

struct IntensityTile: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(Intensity.key) private var level = 1
    init(store: UserDefaults) { _level = AppStorage(wrappedValue: 1, Intensity.key, store: store) }
    var body: some View {
        let current = Intensity(rawValue: level)?.title ?? ""
        VStack(alignment: .leading, spacing: 8) {
            (Text(tr("Quantidade")).font(.callout.weight(.medium)) + Text(" · \(current)").font(.caption).foregroundColor(.secondary))
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
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(width: menuWidth)
        .environment(\.controlActiveState, .key)   // menu windows are never key: without this the controls draw dimmed
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Quantidade"))
        .accessibilityValue(current)
        .accessibilityAdjustableAction { d in level = steppedLevel(level, by: d == .increment ? 1 : -1) }
    }
}

/// Shown wherever the Accessibility permission is offered; the app works fully without it.
var axHint: String { tr("Opcional. Sem ela, não há neve no Dock e as janelas são seguidas com menos rapidez.") }

/// Top item of the menu: the Nevar switch with the live status under it.
struct MenuHeader: View {
    @ObservedObject var panel: PanelState
    let env: SettingsEnv
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PrefBinding(.enabled, env.store) { on in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Nevar")).font(.headline)
                        Text(panel.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle(tr("Nevar"), isOn: on).labelsHidden().toggleStyle(.switch)
                }
                .contentShape(Rectangle())
                .onTapGesture { on.wrappedValue.toggle() }
            }
            if panel.metalMissing { Label(tr("Este Mac não consegue desenhar a neve. Ela fica desativada."), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(width: menuWidth)
        .environment(\.controlActiveState, .key)
    }
}

private struct AccessRow: View {
    @ObservedObject var panel: PanelState
    let ask: () -> Void
    var body: some View {
        if panel.axMissing {
            Button(action: ask) { Label(tr("Permitir Acessibilidade…"), systemImage: "hand.raised") }
            Text(axHint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MusicNote: View {
    @ObservedObject var panel: PanelState
    let reduceMotion: Bool
    var body: some View {
        let t = !MusicTap.supported ? tr("Precisa do macOS 14.2 ou mais novo.") : reduceMotion ? tr("Desativado porque Reduzir movimento está ligado.") : panel.musicNote
        if !t.isEmpty { Text(t).font(.caption).foregroundStyle(.secondary) }
    }
}

// MARK: window (full)

enum SettingsTab: String, CaseIterable {
    case geral, bonecos, desempenho, sistema
    var title: String { [tr("Geral"), tr("Bonecos"), tr("Desempenho"), tr("Sistema")][Self.allCases.firstIndex(of: self)!] }
    var symbol: String { ["slider.horizontal.3", "figure.walk", "speedometer", "gearshape.2"][Self.allCases.firstIndex(of: self)!] }
    static let key = "settingsTab"
}

/// One tab of the "Ajustes" window (each is hosted by its own controller in an NSTabViewController with toolbar tabs).
struct SettingsPane: View {
    let env: SettingsEnv
    let tab: SettingsTab
    @ObservedObject var panel: PanelState
    init(env: SettingsEnv, tab: SettingsTab) { self.env = env; self.tab = tab; panel = env.panel }

    private func toggle(_ o: Option) -> some View {
        PrefBinding(o.pref, env.store) { b in Toggle(isOn: b) { Label(o.title, systemImage: o.symbol) } }
    }

    var body: some View {
        Form {
            switch tab {
            case .geral:
                IntensityPicker(store: env.store)
                if !panel.screens.isEmpty {
                    PrefBinding(.economy, env.store) { eco in
                        Picker(selection: eco.wrappedValue ? .constant("main") : env.target) {
                            Text(tr("Todas as telas")).tag("all")
                            Text(tr("Tela principal")).tag("main")
                            ForEach(panel.screens, id: \.id) { Text($0.title).tag($0.id) }
                        } label: { Label(tr("Nevar em"), systemImage: "display") }
                            .disabled(eco.wrappedValue)
                        if eco.wrappedValue { Text(tr("O modo econômico usa só a tela principal.")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                PrefBinding(.behindWindows, env.store) { behind in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: behind) { Label(tr("Atrás das janelas"), systemImage: "square.stack.3d.down.right") }
                        Text(tr("A neve cai só no chão, por trás das janelas.")).font(.caption).foregroundStyle(.secondary)
                    }
                    PrefBinding(.behindLarge, env.store) { b in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(isOn: b) { Label(tr("Atrás de janelas grandes"), systemImage: "macwindow") }.disabled(behind.wrappedValue)
                            Text(behind.wrappedValue ? tr("Já incluído em Atrás das janelas.") : tr("Os flocos passam por trás de janelas grandes.")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(tr("Dica: segure ⌥ e arraste a neve para fazer bolas.")).font(.caption).foregroundStyle(.secondary)
            case .bonecos:
                ForEach(figures, id: \.pref) { toggle($0) }
            case .desempenho:
                toggle(economyOpt)
                Text(tr("20–30 fps, só a tela principal, menos efeitos.")).font(.caption).foregroundStyle(.secondary)
                toggle(ambientOpt)
                PrefBinding(.music, env.store) { b in
                    Toggle(isOn: b) { Label(musicOpt.title, systemImage: musicOpt.symbol) }
                        .disabled(!MusicTap.supported || panel.reduceMotion)
                }
                MusicNote(panel: env.panel, reduceMotion: panel.reduceMotion)
                PrefBinding(.pointerPush, env.store) { b in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: b) { Label(tr("Cursor empurra os flocos"), systemImage: "cursorarrow.motionlines") }
                        Text(tr("Desligado, o cursor não mexe nos flocos no ar nem empurra a neve acumulada.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if panel.reduceMotion { toggle(stillOpt) }
            case .sistema:
                PrefBinding(.showInCaptures, env.store) { b in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: b) { Label(tr("Aparecer em capturas de tela"), systemImage: "camera") }
                        Text(tr("Nem todo app de captura respeita esta opção.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                AccessRow(panel: env.panel, ask: env.askAccessibility)
                if !env.isDev {
                    Toggle(isOn: Binding(get: { panel.loginOn }, set: { env.login.wrappedValue = $0 })) { Label(tr("Abrir ao iniciar sessão"), systemImage: "power.circle") }
                    if !panel.loginNote.isEmpty { Text(panel.loginNote).font(.caption).foregroundStyle(.secondary) }
                }
                Button(tr("Restaurar padrões"), action: env.restoreDefaults)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 300)
    }
}

/// Quantidade in Ajustes: a segmented picker, so the level is also reachable from the keyboard.
private struct IntensityPicker: View {
    @AppStorage(Intensity.key) private var level = 1
    init(store: UserDefaults) { _level = AppStorage(wrappedValue: 1, Intensity.key, store: store) }
    var body: some View {
        Picker(selection: $level) {
            ForEach(Intensity.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
        } label: { Label(tr("Quantidade"), systemImage: "snowflake") }
            .pickerStyle(.segmented)
    }
}
