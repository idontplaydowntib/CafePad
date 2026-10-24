// SPDX-License-Identifier: MPL-2.0

import Foundation

enum BundledGameFixes {
    /// Installs the bundled pack once. Existing packs, including user edits, stay intact.
    static func installIfNeeded() {
        let manager = FileManager.default
        let packName = "CafePad_NSMBU_CrashFix"
        let parent = GraphicPackPaths.imported
        let destination = parent.appendingPathComponent(packName, isDirectory: true)
        guard !manager.fileExists(atPath: destination.path) else { return }

        guard let resources = Bundle.main.resourceURL else {
            cemu_bridge_log_checkpoint("Bundled game fix: app resources are unavailable")
            return
        }
        let source = resources
            .appendingPathComponent("CemuData", isDirectory: true)
            .appendingPathComponent("graphicPacks", isDirectory: true)
            .appendingPathComponent(packName, isDirectory: true)
        let temporary = parent.appendingPathComponent(
            ".\(packName).\(UUID().uuidString).tmp", isDirectory: true)

        defer {
            if manager.fileExists(atPath: temporary.path) {
                do {
                    try manager.removeItem(at: temporary)
                } catch {
                    cemu_bridge_log_checkpoint("Bundled game fix: temporary cleanup failed: \(error.localizedDescription)")
                }
            }
        }

        do {
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
            for name in ["rules.txt", "patch_CrashFix.asm"] {
                try manager.copyItem(at: source.appendingPathComponent(name),
                                     to: temporary.appendingPathComponent(name))
            }
            // Another installer may have finished while these files were copied.
            guard !manager.fileExists(atPath: destination.path) else { return }
            try manager.moveItem(at: temporary, to: destination)
        } catch {
            cemu_bridge_log_checkpoint("Bundled game fix: installation failed: \(error.localizedDescription)")
        }
    }
}
