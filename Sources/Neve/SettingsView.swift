import SwiftUI

/// The "Ajustes" popover. Bool options are @AppStorage on the app's defaults store (same keys as always);
/// the controller reacts through its UserDefaults observer. Target screen and login go through controller closures.
struct SettingsView: View {
    let screens: [(title: String, id: String)]
    let reduceMotion: Bool
    let isDev: Bool
    let target: Binding<String>
    let login: Binding<Bool>

    @AppStorage private var economy: Bool
    @AppStorage private var ambient: Bool
    @AppStorage private var behind: Bool
    @AppStorage private var behindLarge: Bool
    @AppStorage private var still: Bool
    @AppStorage private var snowman: Bool
    @AppStorage private var walk: Bool
    @AppStorage private var visitors: Bool
    @AppStorage private var sleigh: Bool
    @AppStorage private var captures: Bool

    init(store: UserDefaults, screens: [(title: String, id: String)], reduceMotion: Bool, isDev: Bool, target: Binding<String>, login: Binding<Bool>) {
        self.screens = screens; self.reduceMotion = reduceMotion; self.isDev = isDev; self.target = target; self.login = login
        func pref(_ p: Pref) -> AppStorage<Bool> { AppStorage(wrappedValue: p.defaultValue, p.rawValue, store: store) }
        _economy = pref(.economy); _ambient = pref(.ambient); _behind = pref(.behindWindows); _behindLarge = pref(.behindLarge)
        _still = pref(.stillSnow); _snowman = pref(.snowman); _walk = pref(.walk); _visitors = pref(.visitors)
        _sleigh = pref(.sleigh); _captures = pref(.showInCaptures)
    }

    var body: some View {
        Form {
            Section("Onde") {
                Picker(selection: target) {
                    Text("Todas as telas").tag("all")
                    Text("Só na tela principal").tag("main")
                    ForEach(screens, id: \.id) { Text($0.title).tag($0.id) }
                } label: { Label("Nevar em", systemImage: "display") }
                    .disabled(economy)
                Toggle(isOn: $behind) { Label("Atrás das janelas", systemImage: "square.stack.3d.down.right") }
                Toggle(isOn: $behindLarge) { Label("Neve atrás de janelas grandes", systemImage: "macwindow") }
            }
            Section("Bonecos e bichos") {
                Toggle(isOn: $snowman) { Label("Boneco de neve", systemImage: "figure.stand") }
                Toggle(isOn: $walk) { Label("Bonecos andam e brigam", systemImage: "figure.walk") }
                Toggle(isOn: $visitors) { Label("Visitantes", systemImage: "hare") }
                Toggle(isOn: $sleigh) { Label("Trenó do Papai Noel", systemImage: "gift") }
            }
            Section("Desempenho") {
                Toggle(isOn: $economy) { Label("Modo econômico", systemImage: "leaf") }
                Toggle(isOn: $ambient) { Label("Modo ambiente", systemImage: "sun.max") }
            }
            if reduceMotion {
                Section("Acessibilidade") {
                    Toggle(isOn: $still) { Label("Neve parada (movimento reduzido)", systemImage: "pause.circle") }
                }
            }
            Section("Sistema") {
                Toggle(isOn: $captures) { Label("Mostrar em capturas", systemImage: "camera") }
                if !isDev { Toggle(isOn: login) { Label("Abrir no login", systemImage: "arrow.right.circle") } }
            }
            Section("Como brincar") {
                Text("Segure ⌥ e arraste a neve para fazer bolas.")
                Text("Arraste uma janela devagar: a neve vai junto.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 320, height: reduceMotion ? 790 : 730)   // Form scrolls and has no intrinsic height; ponytail: eyeballed, retune if rows change
    }
}
