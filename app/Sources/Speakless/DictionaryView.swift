import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DictionaryView: View {
    @EnvironmentObject var app: AppState
    @State private var filter = "All"
    @State private var query = ""
    @State private var searching = false
    @State private var editing: DictEntry? = nil
    @State private var adding = false

    private var entries: [DictEntry] {
        app.dictionary.filter { e in
            (filter == "All" || (filter == "Auto-added" && e.auto) || (filter == "Manually-added" && !e.auto))
                && (query.isEmpty || e.word.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Dictionary").font(.system(size: 34, weight: .semibold, design: .rounded))
                Spacer()
                Button(action: { adding = true }) { Text("New word") }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(.top, 22)

            HStack {
                PillTabs(items: ["All", "Auto-added", "Manually-added"],
                         icons: ["Auto-added": "sparkle", "Manually-added": "pencil"], selection: $filter)
                Spacer()
                if searching {
                    TextField("Search", text: $query)
                        .textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.panel)).frame(width: 200)
                }
                Button(action: { searching.toggle(); if !searching { query = "" } }) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.panel))
                }.buttonStyle(.plain)
            }

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Text(app.dictionary.isEmpty ? "No words yet" : "No matches").font(.system(size: 20, weight: .semibold))
                    Text("Add names, products and jargon here.\nThey are sent to the correction model as hints, so it spells them your way.")
                        .multilineTextAlignment(.center).font(.system(size: 14)).foregroundColor(Theme.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 70)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                        ForEach(entries) { e in WordTile(entry: e, onEdit: { editing = e }) }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .padding(.horizontal, 20)
        .sheet(isPresented: $adding) { WordSheet(entry: nil) }
        .sheet(item: $editing) { WordSheet(entry: $0) }
    }
}

struct WordTile: View {
    @EnvironmentObject var app: AppState
    let entry: DictEntry
    let onEdit: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.auto ? "sparkle" : "pencil")
                .font(.system(size: 12)).foregroundColor(entry.auto ? Theme.green : Theme.secondary).frame(width: 16)
            Text(entry.word).font(.system(size: 15)).lineLimit(1)
            if let h = entry.heardAs, !h.isEmpty {
                Text("← " + h.joined(separator: " ")).font(.system(size: 12)).foregroundColor(Theme.secondary).lineLimit(1)
            }
            Spacer()
            if hover {
                Button(action: onEdit) { Image(systemName: "pencil.line") }.buttonStyle(.plain).help("Edit")
                Button(action: { app.dictionary.removeAll { $0.id == entry.id } }) { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Delete")
            }
        }
        .foregroundColor(hover ? Theme.text : Theme.text.opacity(0.85))
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .onHover { hover = $0 }
    }
}

struct WordSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let entry: DictEntry?
    @State private var word = ""
    @State private var heard = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry == nil ? "New word" : "Edit word").font(.system(size: 20, weight: .semibold))
            Text("A name, product or term you want spelled exactly like this.").font(.system(size: 13)).foregroundColor(Theme.secondary)
            TextField("e.g. Tailscale", text: $word)
                .fieldHighlight().onSubmit(save)
            Text("Often heard as (optional) — what the speech model keeps writing instead, separated by commas. The correction step will change those back to this word.")
                .font(.system(size: 12.5)).foregroundColor(Theme.secondary)
            TextField("e.g. 普通, 铺中", text: $heard)
                .fieldHighlight().onSubmit(save)
            HStack {
                if entry == nil {
                    Button("Import CSV", action: importCSV).buttonStyle(OutlineButtonStyle())
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(OutlineButtonStyle())
                Button(entry == nil ? "Add word" : "Save", action: save).buttonStyle(PrimaryButtonStyle())
                    .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { word = entry?.word ?? ""; heard = (entry?.heardAs ?? []).joined(separator: ", ") }
    }

    private func save() {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        let list = heard.split(whereSeparator: { ",，、;；".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let entry, let i = app.dictionary.firstIndex(where: { $0.id == entry.id }) {
            app.dictionary[i].word = w
            app.dictionary[i].heardAs = list.isEmpty ? nil : list
        } else {
            app.addWord(w, heardAs: list)
        }
        dismiss()
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        // 每行第一列当作一个词
        for line in text.split(whereSeparator: \.isNewline) {
            let first = line.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            app.addWord(first.trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces)))
        }
        dismiss()
    }
}
