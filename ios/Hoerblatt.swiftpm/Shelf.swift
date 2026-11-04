import SwiftUI
import UIKit

// The Schrank (teacher, November 2026): the child's Mappe and the strip at the top show only what is handed out
// today; everything else waits here. Only teachers open it (in the Mappe, press the Schrank button for 1 s).
// New pages (photo, PDF, Schreibblatt) are handed out at once; at the end of the day everything goes back by
// itself, and a teacher can put things back any time. Several teachers use the iPad: pages and Hefte can get a
// subject (names the teachers choose); the child never sees subjects.

struct ShelfView: View {
    @ObservedObject var app: AppState
    /// nil: all subjects; "" : without a subject.
    @State private var filter: String? = nil
    /// The name typed for a new subject (a field right in the list: the keyboard did not come up in an alert).
    @State private var newName = ""
    /// The subject being renamed, and its new name.
    @State private var editing: String? = nil
    @State private var editText = ""
    /// "Neues Fach …" in a page's tag menu: scroll to the field and put the cursor there.
    @State private var wantNew = false
    @FocusState private var focus: ShelfFocus?
    @State private var deleting: ShelfEntry? = nil
    @State private var askPutAwayAll = false
    @State private var message: String? = nil

    var body: some View {
        let all = entries
        let outList = all.filter { app.store.isOut($0.id) }
        let inside = all.filter { !app.store.isOut($0.id) }
        NavigationStack {
          ScrollViewReader { proxy in
            List {
                actionsSection(outCount: outList.count)
                outSection(outList)
                ForEach(groups(inside), id: \.key) { group in
                    Section {
                        if group.entries.isEmpty {
                            Text("Nichts in diesem Fach.")
                                .foregroundColor(.secondary)
                        }
                        ForEach(group.entries) { e in
                            row(e, out: false)
                        }
                    } header: {
                        Text(group.title)
                    }
                }
                subjectsSection
            }
            .listStyle(.insetGrouped)
            .onChange(of: wantNew) { _, on in
                guard on else { return }
                wantNew = false
                withAnimation {
                    proxy.scrollTo(ShelfFocus.newSubject, anchor: .center)
                }
                // (after the menu has gone away, or the keyboard does not come)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    focus = .newSubject
                }
            }
            .navigationTitle("Schrank")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        app.closeShelf()
                    }
                    .font(.headline)
                }
            }
            .confirmationDialog(deleting.map { "„\($0.title)“ löschen?" } ?? "", isPresented: deletingShown,
                                titleVisibility: .visible) {
                Button("In den Papierkorb", role: .destructive) {
                    if let e = deleting { app.deleteNow(e.id) }
                    deleting = nil
                }
                Button("Abbrechen", role: .cancel) {
                    deleting = nil
                }
            } message: {
                Text("Mit allen Antworten. Im Papierkorb (Einstellungen) lässt es sich \(PageStore.trashDays) Tage lang zurückholen.")
            }
            .confirmationDialog("Alles in den Schrank legen?", isPresented: $askPutAwayAll, titleVisibility: .visible) {
                Button("Alles weglegen") {
                    app.store.putAwayAll()
                }
                Button("Abbrechen", role: .cancel) {
                }
            } message: {
                Text("Das Kind sieht danach nichts mehr in der Mappe, bis wieder etwas ausgegeben wird. Antworten bleiben.")
            }
          }
        }
        .onAppear {
            app.speaker.stop()
            app.store.tidyShelf()
            if let f = filter, !f.isEmpty, !app.store.shelf.subjects.contains(f) { filter = nil }
        }
    }

    // MARK: - Sections

    @MainActor
    private func actionsSection(outCount: Int) -> some View {
        Section {
            Button(action: {
                app.choosePDFFromShelf()
            }) {
                SwiftUI.Label("PDF öffnen (Heft)", systemImage: "doc.richtext")
            }
            Button(action: {
                // (the Schrank closes, then the Fotos app opens)
                app.showPicker = true
            }) {
                SwiftUI.Label("Foto aus der Fotos-App wählen", systemImage: "photo.on.rectangle")
            }
            Button(action: {
                askPutAwayAll = true
            }) {
                SwiftUI.Label("Alles weglegen", systemImage: "tray.and.arrow.down")
            }
            .disabled(outCount == 0)
            if !app.store.shelf.subjects.isEmpty {
                Picker(selection: $filter) {
                    Text("Alle Fächer").tag(String?.none)
                    ForEach(app.store.shelf.subjects, id: \.self) { s in
                        Text(s).tag(String?.some(s))
                    }
                    Text("Ohne Fach").tag(String?.some(""))
                } label: {
                    SwiftUI.Label("Im Schrank zeigen", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            if let m = message {
                Text(m)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        } footer: {
            Text("Neue Seiten und Hefte liegen sofort beim Kind. Am Ende des Tages kommt alles von selbst in den Schrank; alle Antworten bleiben. Eine geöffnete PDF wird sofort ausgegeben.")
        }
    }

    @MainActor
    private func outSection(_ list: [ShelfEntry]) -> some View {
        Section {
            if list.isEmpty {
                Text("Gerade liegt nichts beim Kind.")
                    .foregroundColor(.secondary)
            }
            ForEach(list) { e in
                row(e, out: true)
            }
        } header: {
            Text("Liegt heute beim Kind")
        } footer: {
            Text("Nur das sieht das Kind in der Mappe und oben in der Leiste.")
        }
    }

    @MainActor
    private var subjectsSection: some View {
        Section {
            ForEach(app.store.shelf.subjects, id: \.self) { s in
                if editing == s {
                    HStack(spacing: 12) {
                        SwiftUI.Image(systemName: "tag")
                            .foregroundColor(ShelfStyle.teal)
                        TextField("Name des Fachs", text: $editText)
                            .focused($focus, equals: .rename)
                            .submitLabel(.done)
                            .onSubmit { commitRename() }
                        Button("Fertig") {
                            commitRename()
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Button(action: {
                        editText = s
                        editing = s
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            focus = .rename
                        }
                    }) {
                        HStack {
                            SwiftUI.Label(s, systemImage: "tag")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(shelfCount(entries.filter { app.store.shelf.subject(of: $0.id) == s }.count))
                                .foregroundColor(.secondary)
                            SwiftUI.Image(systemName: "pencil")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .onDelete { rows in
                let names = rows.map { app.store.shelf.subjects[$0] }
                for n in names { app.store.removeSubject(n) }
                if let f = filter, names.contains(f) { filter = nil }
            }
            .onMove { from, to in
                app.store.moveSubjects(from: from, to: to)
            }
            HStack(spacing: 12) {
                SwiftUI.Image(systemName: "plus.circle")
                    .foregroundColor(ShelfStyle.teal)
                TextField("Neues Fach, z. B. Deutsch", text: $newName)
                    .focused($focus, equals: .newSubject)
                    .submitLabel(.done)
                    .onSubmit { addSubject() }
                Button("Anlegen") {
                    addSubject()
                }
                .buttonStyle(.borderedProminent)
                .tint(ShelfStyle.teal)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .id(ShelfFocus.newSubject)
        } header: {
            Text("Fächer")
        } footer: {
            Text("Für mehrere Lehrkräfte: Jede Seite und jedes Heft kann ein Fach bekommen (Knopf mit dem Etikett). Das Kind sieht keine Fächer. Ein Fach antippen benennt es um, nach links wischen löscht es (die Seiten bleiben, nur ohne Fach).")
        }
    }

    // MARK: - One page or Heft

    @MainActor
    private func row(_ e: ShelfEntry, out: Bool) -> some View {
        let subject = app.store.shelf.subject(of: e.id)
        return HStack(spacing: 12) {
            ShelfThumb(image: app.store.thumbnail(e.id), heft: e.heft)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(shelfDetails(e, subject: subject))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            subjectMenu(e, subject: subject)
            if out {
                Button(action: {
                    app.store.putAway(e.id)
                }) {
                    Text("Weglegen")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.bordered)
                .tint(ShelfStyle.slate)
            } else {
                Button(action: {
                    app.store.handOut(e.id)
                }) {
                    Text("Ausgeben")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .tint(ShelfStyle.teal)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading) {
            Button(action: {
                app.openFromShelf(e.id)
            }) {
                SwiftUI.Label("Öffnen", systemImage: "eye")
            }
            .tint(ShelfStyle.blue)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: {
                deleting = e
            }) {
                SwiftUI.Label("Löschen", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(action: {
                app.openFromShelf(e.id)
            }) {
                SwiftUI.Label("Ausgeben und öffnen", systemImage: "eye")
            }
            if out {
                Button(action: { app.store.putAway(e.id) }) {
                    SwiftUI.Label("Weglegen", systemImage: "tray.and.arrow.down")
                }
            } else {
                Button(action: { app.store.handOut(e.id) }) {
                    SwiftUI.Label("Ausgeben", systemImage: "tray.and.arrow.up")
                }
            }
            Button(role: .destructive, action: {
                deleting = e
            }) {
                SwiftUI.Label("Löschen", systemImage: "trash")
            }
        }
    }

    @MainActor
    private func subjectMenu(_ e: ShelfEntry, subject: String?) -> some View {
        Menu {
            Button(action: { app.store.setSubject(e.id, nil) }) {
                if subject == nil {
                    SwiftUI.Label("Ohne Fach", systemImage: "checkmark")
                } else {
                    Text("Ohne Fach")
                }
            }
            ForEach(app.store.shelf.subjects, id: \.self) { s in
                Button(action: { app.store.setSubject(e.id, s) }) {
                    if subject == s {
                        SwiftUI.Label(s, systemImage: "checkmark")
                    } else {
                        Text(s)
                    }
                }
            }
            Divider()
            Button(action: {
                wantNew = true
            }) {
                SwiftUI.Label("Neues Fach …", systemImage: "plus")
            }
        } label: {
            Image(systemName: subject == nil ? "tag" : "tag.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(subject == nil ? ShelfStyle.slate : ShelfStyle.teal)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(Text(subject.map { "Fach: \($0)" } ?? "Fach wählen"))
    }

    // MARK: - Data

    /// Hefte and single pages (pages of a Heft count as their Heft), newest first.
    @MainActor
    private var entries: [ShelfEntry] {
        let books = app.store.hefte
        let bookIds = Set(books.map { $0.id })
        var list: [ShelfEntry] = books.map {
            ShelfEntry(id: $0.id, title: $0.title, created: $0.created, pages: $0.pageTotal, heft: true)
        }
        for info in app.store.pages where info.heft.map({ !bookIds.contains($0) }) ?? true {
            let t = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
            list.append(ShelfEntry(id: info.id, title: t.isEmpty ? "Seite" : t, created: info.created, pages: 1,
                                   heft: false))
        }
        return list.sorted { $0.created > $1.created }
    }

    /// What is in the Schrank, by subject (as the filter says), then without a subject.
    @MainActor
    private func groups(_ inside: [ShelfEntry]) -> [ShelfGroup] {
        let subjects = app.store.shelf.subjects
        var result: [ShelfGroup] = []
        if subjects.isEmpty {
            return [ShelfGroup(key: "-", title: "Im Schrank", entries: inside)]
        }
        for s in subjects where filter == nil || filter == s {
            let list = inside.filter { app.store.shelf.subject(of: $0.id) == s }
            if list.isEmpty && filter == nil { continue }
            result.append(ShelfGroup(key: "s-" + s, title: "Im Schrank · " + s, entries: list))
        }
        if filter == nil || filter == "" {
            let list = inside.filter { app.store.shelf.subject(of: $0.id) == nil }
            if !list.isEmpty || filter == "" || result.isEmpty {
                result.append(ShelfGroup(key: "-", title: "Im Schrank · ohne Fach", entries: list))
            }
        }
        return result
    }

    private func addSubject() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return }
        if app.store.addSubject(name) {
            message = "Fach angelegt: \(name)"
            newName = ""
            focus = nil
        } else {
            message = "Das Fach „\(name)“ gibt es schon."
        }
    }

    private func commitRename() {
        guard let old = editing else { return }
        if !app.store.renameSubject(old, to: editText) {
            message = "Diesen Namen gibt es schon (oder er ist leer)."
        } else if filter == old {
            filter = app.store.shelf.subjects.contains(editText.trimmingCharacters(in: .whitespaces))
                ? editText.trimmingCharacters(in: .whitespaces) : nil
        }
        editing = nil
        focus = nil
    }

    private var deletingShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}

/// The Schrank button in the Mappe: opens only after pressing 1 s (a ring fills meanwhile, as at the gear), so the
/// child does not open it by tapping.
struct ShelfKnob: View {
    @ObservedObject var app: AppState
    @GestureState private var holding = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
            Circle()
                .stroke(ShelfStyle.slate.opacity(0.4), lineWidth: 2)
            Circle()
                .trim(from: 0, to: holding ? 1 : 0)
                .stroke(ShelfStyle.teal, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(holding ? Animation.linear(duration: 1) : Animation.easeOut(duration: 0.15), value: holding)
            // (the cabinet symbol, or a box where this iPadOS has no cabinet)
            Image(systemName: UIImage(systemName: "cabinet") != nil ? "cabinet" : "archivebox")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(ShelfStyle.slate)
        }
        .frame(width: 64, height: 64)
        .contentShape(Circle())
        .gesture(
            LongPressGesture(minimumDuration: 1, maximumDistance: 30)
                .updating($holding) { pressing, state, _ in
                    state = pressing
                }
                .onEnded { _ in
                    app.showShelf = true
                }
        )
        .accessibilityLabel(Text("Schrank für Lehrkräfte, 1 Sekunde lang drücken"))
    }
}

// MARK: - Pieces

struct ShelfEntry: Identifiable, Hashable {
    var id: UUID
    var title: String
    var created: Date
    var pages: Int
    var heft: Bool
}

/// The text fields of the Schrank.
fileprivate enum ShelfFocus: Hashable {
    case newSubject, rename
}

fileprivate struct ShelfGroup {
    var key: String
    var title: String
    var entries: [ShelfEntry]
}

fileprivate struct ShelfThumb: View {
    let image: UIImage?
    let heft: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white)
            if let t = image {
                Image(uiImage: t)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            } else {
                Image(systemName: "doc.text.fill")
                    .foregroundColor(ShelfStyle.slate.opacity(0.6))
            }
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.black.opacity(0.15), lineWidth: 1)
            if heft {
                Image(systemName: "book.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Circle().fill(ShelfStyle.teal))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(2)
            }
        }
        .frame(width: 46, height: 58)
    }
}

fileprivate enum ShelfStyle {
    static let teal = Color(red: 15.0 / 255, green: 118.0 / 255, blue: 110.0 / 255)
    static let blue = Color(red: 37.0 / 255, green: 99.0 / 255, blue: 235.0 / 255)
    static let slate = Color(red: 71.0 / 255, green: 85.0 / 255, blue: 105.0 / 255)
}

/// "Heute, 10:15 · 40 Seiten · Deutsch"
fileprivate func shelfDetails(_ e: ShelfEntry, subject: String?) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateStyle = .medium
    f.timeStyle = .short
    f.doesRelativeDateFormatting = true
    var parts = [f.string(from: e.created)]
    if e.heft { parts.append(e.pages == 1 ? "1 Seite" : "\(e.pages) Seiten") }
    if let s = subject { parts.append(s) }
    return parts.joined(separator: " · ")
}

fileprivate func shelfCount(_ n: Int) -> String {
    return n == 1 ? "1 Eintrag" : "\(n) Einträge"
}
