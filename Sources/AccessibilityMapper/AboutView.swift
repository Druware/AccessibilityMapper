//  AboutView.swift
//  AccessibilityMapper
//
//  Created by Andrew Satori on 2026/05/22.
//  Copyright © 2026 Druware Software Designs. All rights reserved.
//
//  DUAL LICENSE
//  ============
//  Druware Software Designs (the copyright holder) may publish and distribute
//  compiled binaries of this software under the terms of the Commercial License
//  (see LICENSE-COMMERCIAL in the project root).
//
//  All other parties must use, modify, and distribute this source code
//  exclusively under the GNU General Public License v3 (see LICENSE).


import SwiftUI

struct AboutView: View {
    private let appVersion: String = {
        let ver   = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(ver) (\(build))"
    }()

    var body: some View {
        VStack(spacing: 0) {
            // ── Icon + name ───────────────────────────────────────────
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 28)

            Text("Accessibility Mapper")
                .font(.title2.bold())
                .padding(.top, 10)

            Text("Version \(appVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Divider()
                .padding(.horizontal, 24)
                .padding(.vertical, 18)

            // ── Copyright ─────────────────────────────────────────────
            VStack(spacing: 4) {
                Text("Copyright © 2026 Druware Software Designs")
                    .font(.footnote.weight(.medium))
                Text("Dual Licensed — Open Source & Commercial")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // ── Dual license notice ────────────────────────────────────
            VStack(spacing: 10) {
                VStack(spacing: 4) {
                    Text("Open Source License")
                        .fontWeight(.medium)
                    (Text("This source code is available under the ")
                    + Text("GNU General Public License v3").fontWeight(.medium)
                    + Text(". You may use, modify, and distribute it under those terms."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Link("View GPL v3 license", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                }

                Divider()
                    .padding(.horizontal, 40)

                VStack(spacing: 4) {
                    Text("Commercial License")
                        .fontWeight(.medium)
                    Text("A commercial license is available from Druware Software Designs for use in proprietary or closed-source products.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Link("Learn about commercial licensing", destination: URL(string: "https://druware.com/accessibilitymapper/licensing")!)
                }
            }
            .font(.caption)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .padding(.top, 14)

            Spacer(minLength: 24)
        }
        .frame(width: 380)
        .fixedSize()
    }
}
