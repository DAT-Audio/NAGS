import SwiftUI

/// Settings → Credits: the same text as the About window's (`Credits`), standing still, with a
/// way to the licences: protocol attribution is kept in a tab, not the main text. There is one
/// source, so the two cannot drift apart.
public struct Acknowledgements: View {
    public init() {}

    public var body: some View {
        ForEach(Credits.sections) { section in
            Section(section.title) {
                ForEach(section.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        if !item.title.isEmpty {
                            Text(item.title).font(.system(size: 12, weight: .semibold))
                        }
                        Text(item.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mutedLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        Section {
            HStack {
                Text(Credits.copyright).font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                Spacer()
                Button("Licences\u{2026}") { LicencesWindow.show() }
            }
        }
    }
}
