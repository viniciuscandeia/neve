import CoreGraphics

/// Where the menu-bar panel goes: `gap` below the status item, left edge aligned to it, clamped inside the screen's visible frame.
public func panelFrame(size: CGSize, anchor: CGRect, visible: CGRect, gap: CGFloat = 5, margin: CGFloat = 4) -> CGRect {
    let maxX = visible.maxX - margin - size.width, minX = visible.minX + margin
    let x = max(minX, min(anchor.minX, maxX))
    let y = max(visible.minY + margin, anchor.minY - gap - size.height)
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
}

/// Names for the "Nevar em" picker: the main screen is marked, and identical names get their resolution (then a number) appended.
public func screenLabels(names: [String], sizes: [CGSize]) -> [String] {
    var out = zip(names, sizes).map { $0 }.enumerated().map { i, p in
        let dup = names.filter { $0 == p.0 }.count > 1
        return p.0 + (dup ? " (\(Int(p.1.width))×\(Int(p.1.height)))" : "") + (i == 0 ? " (principal)" : "")
    }
    for (i, l) in out.enumerated() where out.filter({ $0 == l }).count > 1 { out[i] = l + " #\(i + 1)" }
    return out
}

/// Caption under "Abrir ao iniciar sessão" after a register / unregister attempt ("" = nothing to say).
public func loginNote(requiresApproval: Bool, failed: Bool) -> String {
    requiresApproval ? "Aprove em Ajustes do Sistema › Itens de Início." : failed ? "Não foi possível alterar; tente em Ajustes do Sistema › Itens de Início." : ""
}

/// Quantidade stepped by an arrow key / VoiceOver adjust, clamped to 0...3.
public func steppedLevel(_ level: Int, by d: Int) -> Int { min(3, max(0, level + d)) }
