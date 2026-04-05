import AppKit
import SwiftUI

struct OnboardingView: View {
    @AppStorage("terminalFontFamily") private var savedFontFamily = ""
    @AppStorage("terminalFontSize") private var savedFontSize: Double = 0

    @State private var selectedFont = ""
    @State private var fontSize: Double = 13
    let onDone: () -> Void

    private struct FontOption: Identifiable {
        let id: String  // PostScript name
        let displayName: String
        let description: String
        var isInstalled: Bool { NSFont(name: id, size: 14) != nil }
    }

    private struct FontSection: Identifiable {
        let id: String
        let title: String
        let fonts: [FontOption]
    }

    private var fontSections: [FontSection] {
        [
            FontSection(id: "ko", title: "🇰🇷 Korean", fonts: [
                FontOption(id: "D2Coding", displayName: "D2Coding", description: "네이버 코딩 폰트 — 한글 고정폭 1위"),
                FontOption(id: "D2CodingLigature", displayName: "D2Coding Ligature", description: "D2Coding + 합자(ligature) 지원"),
            ]),
            FontSection(id: "ja", title: "🇯🇵 Japanese", fonts: [
                FontOption(id: "SarasaMonoJ-Regular", displayName: "Sarasa Mono J", description: "Source Han Sans + Iosevka 합성"),
                FontOption(id: "NotoSansMonoCJKjp", displayName: "Noto Sans Mono CJK JP", description: "Google Noto CJK 일본어"),
            ]),
            FontSection(id: "en", title: "🌐 Universal", fonts: [
                FontOption(id: "JetBrainsMono-Regular", displayName: "JetBrains Mono", description: "Developer favorite — 가독성, 리가처"),
                FontOption(id: "FiraCode-Regular", displayName: "Fira Code", description: "리가처 선구자, Mozilla 제작"),
                FontOption(id: "SFMono-Regular", displayName: "SF Mono", description: "Apple 공식 모노스페이스"),
                FontOption(id: "Menlo", displayName: "Menlo", description: "macOS 기본 모노 폰트"),
            ]),
        ]
    }

    private var allFonts: [FontOption] {
        fontSections.flatMap(\.fonts)
    }

    var body: some View {
        VStack(spacing: 24) {

            VStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.purple)
                Text("Welcome to CodeSpark")
                    .font(.title)
                    .fontWeight(.bold)
                Text("터미널 폰트를 선택하세요")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()


            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(fontSections) { section in
                        let installedFonts = section.fonts.filter(\.isInstalled)
                        if !installedFonts.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                ForEach(section.fonts) { font in
                                    HStack(spacing: 12) {
                                        Image(systemName: selectedFont == font.id ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedFont == font.id ? .purple : .secondary)

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(font.displayName)
                                                    .font(.system(.body, weight: .medium))
                                                if !font.isInstalled {
                                                    Text("not installed")
                                                        .font(.caption2)
                                                        .foregroundStyle(.orange)
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 1)
                                                        .background(.orange.opacity(0.15), in: Capsule())
                                                }
                                            }
                                            Text(font.description)
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }

                                        Spacer()

                                        if font.isInstalled {
                                            Text(">_ hello")
                                                .font(.custom(font.id, size: 13))
                                                .foregroundStyle(.primary)
                                        }
                                    }
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(selectedFont == font.id ? Color.purple.opacity(0.1) : .clear)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if font.isInstalled { selectedFont = font.id }
                                    }
                                    .opacity(font.isInstalled ? 1 : 0.5)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 350)


            HStack {
                Text("Size")
                    .font(.headline)
                Stepper(value: $fontSize, in: 8...24, step: 1) {
                    Text("\(Int(fontSize)) pt")
                        .monospacedDigit()
                }
            }

            Divider()


            Button {
                savedFontFamily = selectedFont
                savedFontSize = fontSize
                onDone()
            } label: {
                Text("Start")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .controlSize(.large)
        }
        .padding(30)
        .frame(width: 440)
        .onAppear {
            // Pre-select first installed font
            if selectedFont.isEmpty {
                selectedFont = allFonts.first(where: { $0.isInstalled })?.id ?? "Menlo"
            }
        }
    }
}
