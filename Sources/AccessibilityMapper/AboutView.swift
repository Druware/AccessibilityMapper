//  AboutView.swift
//  AccessibilityMapper
//
//  Created by Andrew Satori on 2026/05/22.
//  Copyright © 2026 Druware Software Development. All rights reserved.


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
                Text("Copyright © 2026 Druware Software Development")
                    .font(.footnote.weight(.medium))
                Text("All rights reserved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // ── GPL notice ────────────────────────────────────────────
            VStack(spacing: 6) {
                (Text("This program is free software: you can redistribute it and/or modify it under the terms of the ")
                + Text("GNU General Public License").fontWeight(.medium)
                + Text(" as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version."))
                    .multilineTextAlignment(.center)

                Text("This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Link("View full license text (GPL v3)", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                    .font(.footnote)
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
