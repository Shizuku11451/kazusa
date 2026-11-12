// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shizuku11451

import Foundation
@testable import KazusaCore
import Testing

struct UpdateCheckerTests {
    @Test func comparesVersionsNumerically() {
        func release(_ v: String) -> AppRelease { AppRelease(version: v, notes: "", downloadURL: URL(string: "https://x")!) }
        #expect(release("0.10.0").isNewer(than: "0.9.1"))
        #expect(release("0.2.1").isNewer(than: "0.2"))
        #expect(!release("0.2.0").isNewer(than: "0.2"))
        #expect(!release("0.2.0").isNewer(than: "0.3.0"))
    }

    @Test func parsesGitHubRelease() throws {
        let json = """
        {"tag_name":"v0.3.0","body":"改了很多","html_url":"https://github.com/Shizuku11451/kazusa/releases/tag/v0.3.0",
         "assets":[{"name":"checksums.txt","browser_download_url":"https://e/x.txt"},
                   {"name":"Kazusa-0.3.0-macOS.dmg","browser_download_url":"https://e/Kazusa-0.3.0-macOS.dmg"}]}
        """
        let release = try AppRelease.parse(Data(json.utf8))
        #expect(release.version == "0.3.0")
        #expect(release.notes == "改了很多")
        #expect(release.downloadURL.absoluteString == "https://e/Kazusa-0.3.0-macOS.dmg")
    }
}
