import SwiftUI
import UIKit

// The Mappe: every photographed page stays with all answers, so the child can switch between pages,
// e.g. a book page and the worksheet about it. LibraryView is the sheet with all pages,
// PageStrip the row of recent pages in the header (one tap switches).

struct LibraryView: View {
    @ObservedObject var app: AppState

    var body: some View {
        // pages of a Heft are shown as their Heft (pages of an unfinished import would get lost otherwise)
        let books = app.store.hefte
        let bookIds = Set(books.map { $0.id })
        let pages = app.store.pages.filter { info in info.heft.map { !bookIds.contains($0) } ?? true }
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 18)],
                          alignment: .leading, spacing: 22) {
                    LibraryActionTile(symbol: "camera.fill", title: "Neue Seite", filled: true) {
                        // (the photo guide or the camera comes once the Mappe has gone away)
                        app.showLibrary = false
                        app.newPhoto()
                    }
                    // ("Foto wählen" from the Fotos app is in the settings: for the teacher)
                    LibraryActionTile(symbol: "doc.richtext", title: "PDF öffnen", filled: false) {
                        // (the Dateien picker comes once the Mappe has gone away)
                        app.announce("PDF öffnen")
                        app.showLibrary = false
                        app.choosePDF()
                    }
                    ForEach(books) { heft in
                        LibraryPageTile(app: app, info: PageInfo(id: heft.id, title: libraryHeftTitle(heft),
                                                                 created: heft.created))
                    }
                    ForEach(pages) { info in
                        LibraryPageTile(app: app, info: info)
                    }
                }
                .padding(20)
                if pages.isEmpty && books.isEmpty {
                    Text("Die Mappe ist noch leer. Mach ein Foto von einem Blatt.")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(LibraryStyle.slate)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                        .onAppear {
                            // (the child cannot read it)
                            app.say("Die Mappe ist noch leer. Tippe auf die Kamera und mach ein Foto von einem Blatt.")
                        }
                }
            }
        }
        .background(LibraryStyle.background.ignoresSafeArea())
    }

    /// Title, where a page will open (two pages: left or right half), close button.
    @MainActor
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(LibraryStyle.teal)
            Text("Mappe")
                .font(.title.weight(.bold))
                .foregroundColor(LibraryStyle.ink)
            if app.twoPages {
                let side = app.activeSide
                HStack(spacing: 8) {
                    Image(systemName: side == .left ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled")
                        .font(.system(size: 24, weight: .semibold))
                    Text(side == .left ? "Kommt nach links" : "Kommt nach rechts")
                        .font(.headline)
                }
                .foregroundColor(libraryColor(side))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Capsule().fill(libraryColor(side).opacity(0.12)))
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            Button(action: {
                app.showLibrary = false
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(LibraryStyle.slate)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.white))
                    .overlay(Circle().stroke(LibraryStyle.slate.opacity(0.4), lineWidth: 2))
            }
            .buttonStyle(LibraryPressStyle())
            .accessibilityLabel(Text("Mappe schließen"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(Color.white.opacity(0.9))
    }
}

/// Row of the most recent pages in the header; the open ones have a coloured edge.
struct PageStrip: View {
    @ObservedObject var app: AppState

    var body: some View {
        let list = stripPages
        if list.isEmpty {
            Color.clear
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(list) { info in
                        LibraryStripItem(app: app, info: info)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
    }

    /// The newest ~12 pages; an open page is always there, even if it is older.
    @MainActor
    private var stripPages: [PageInfo] {
        var list: [PageInfo] = []
        // (a Heft is reached through the Mappe and its arrows; only its open page shows here)
        var count = 0
        for info in app.store.pages {
            let open = libraryOpenSide(app, info.id) != nil
            if info.heft != nil && !open { continue }
            if count < 12 || open {
                list.append(info)
                count += 1
            }
        }
        return list
    }
}

// MARK: - Tiles

/// "Neue Seite" (camera) and "Foto wählen" (photos): the first tiles of the Mappe.
fileprivate struct LibraryActionTile: View {
    let symbol: String
    let title: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(filled ? LibraryStyle.teal : Color.white)
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(LibraryStyle.teal, style: StrokeStyle(lineWidth: 3, dash: filled ? [] : [10, 7]))
                    Image(systemName: symbol)
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundColor(filled ? Color.white : LibraryStyle.teal)
                }
                .frame(height: LibraryStyle.tileHeight)
                Text(title)
                    .font(.headline)
                    .foregroundColor(LibraryStyle.ink)
                    .lineLimit(2)
                // (keeps the same height as a page tile with its date)
                Text(" ")
                    .font(.caption)
            }
        }
        .buttonStyle(LibraryPressStyle())
        .accessibilityLabel(Text(title))
    }
}

/// One page: picture, title, date. Tap opens it, pressing long asks whether to delete it.
fileprivate struct LibraryPageTile: View {
    @ObservedObject var app: AppState
    let info: PageInfo
    @State private var pressing = false

    var body: some View {
        let side = libraryOpenSide(app, info.id)
        let edge: Color = side.map { libraryColor($0) } ?? Color.black.opacity(0.12)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                picture
                    .frame(maxWidth: .infinity)
                    .frame(height: LibraryStyle.tileHeight)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(edge, lineWidth: side == nil ? 1 : 5))
                    .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
                if let s = side {
                    Image(systemName: libraryBadge(s, twoPages: app.twoPages))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(libraryColor(s)))
                        .padding(8)
                }
            }
            Text(libraryTitle(info))
                .font(.headline)
                .foregroundColor(LibraryStyle.ink)
                .lineLimit(2)
            Text(libraryDateText(info.created))
                .font(.caption)
                .foregroundColor(LibraryStyle.slate)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .scaleEffect(pressing ? 0.95 : 1)
        .animation(.easeInOut(duration: 0.15), value: pressing)
        .onTapGesture {
            app.open(info.id)
            if app.showLibrary { app.showLibrary = false }
        }
        .onLongPressGesture(minimumDuration: 0.8, maximumDistance: 24, perform: {
            pressing = false
            app.askDelete(info)
        }, onPressingChanged: { now in
            pressing = now
        })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Löschen")) {
            app.askDelete(info)
        }
    }

    @MainActor
    @ViewBuilder
    private var picture: some View {
        if let thumb = app.store.thumbnail(info.id) {
            Image(uiImage: thumb)
                .resizable()
                .scaledToFit()
                .padding(6)
        } else {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 60))
                .foregroundColor(LibraryStyle.slate.opacity(0.6))
        }
    }
}

/// One page in the header strip: a tap opens it, pressing long asks whether to delete it (as in the Mappe).
fileprivate struct LibraryStripItem: View {
    @ObservedObject var app: AppState
    let info: PageInfo
    @State private var pressing = false

    var body: some View {
        LibraryStripThumb(thumb: app.store.thumbnail(info.id), side: libraryOpenSide(app, info.id))
            .scaleEffect(pressing ? 0.9 : 1)
            .animation(.easeInOut(duration: 0.15), value: pressing)
            .onTapGesture {
                app.open(info.id)
            }
            .onLongPressGesture(minimumDuration: 0.8, maximumDistance: 20, perform: {
                pressing = false
                // a page of a Heft: the question is about the whole Heft (single Heft pages are not deleted)
                if let h = app.store.heft(containing: info.id) {
                    app.askDelete(PageInfo(id: h.id, title: h.title, created: h.created))
                } else {
                    app.askDelete(info)
                }
            }, onPressingChanged: { now in
                pressing = now
            })
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(libraryTitle(info)))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Löschen")) {
                app.askDelete(info)
            }
    }
}

/// Small picture of a page in the header strip.
fileprivate struct LibraryStripThumb: View {
    let thumb: UIImage?
    let side: Side?

    var body: some View {
        let edge: Color = side.map { libraryColor($0) } ?? Color.black.opacity(0.15)
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
            if let t = thumb {
                Image(uiImage: t)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 26))
                    .foregroundColor(LibraryStyle.slate.opacity(0.6))
            }
            RoundedRectangle(cornerRadius: 8)
                .stroke(edge, lineWidth: side == nil ? 1 : 4)
        }
        .frame(width: 56, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

// MARK: - Helpers

fileprivate enum LibraryStyle {
    static let teal = Color(red: 15.0 / 255, green: 118.0 / 255, blue: 110.0 / 255)
    static let blue = Color(red: 37.0 / 255, green: 99.0 / 255, blue: 235.0 / 255)
    static let slate = Color(red: 71.0 / 255, green: 85.0 / 255, blue: 105.0 / 255)
    static let ink = Color(red: 30.0 / 255, green: 41.0 / 255, blue: 59.0 / 255)
    static let background = Color(red: 238.0 / 255, green: 241.0 / 255, blue: 236.0 / 255)
    static let tileHeight: CGFloat = 210
}

fileprivate struct LibraryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Where a page is shown now: left half (or the only page), right half; nil = not shown.
/// (With one page the hidden second page waits in `right`; it does not count as shown.)
/// A Heft counts as shown when one of its pages is.
@MainActor fileprivate func libraryOpenSide(_ app: AppState, _ id: UUID) -> Side? {
    if let l = app.left, l.id == id || l.page.heft == id { return .left }
    if app.twoPages, let r = app.right, r.id == id || r.page.heft == id { return .right }
    return nil
}

fileprivate func libraryHeftTitle(_ heft: Heft) -> String {
    let n = heft.pageTotal
    return n == 1 ? heft.title : "\(heft.title) · \(n) Seiten"
}

/// Left (or the only page) teal, right blue.
fileprivate func libraryColor(_ side: Side) -> Color {
    switch side {
    case .left: return LibraryStyle.teal
    case .right: return LibraryStyle.blue
    }
}

fileprivate func libraryBadge(_ side: Side, twoPages: Bool) -> String {
    if !twoPages { return "eye.fill" }
    switch side {
    case .left: return "rectangle.lefthalf.filled"
    case .right: return "rectangle.righthalf.filled"
    }
}

fileprivate func libraryTitle(_ info: PageInfo) -> String {
    let t = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? "Seite" : t
}

/// "Heute, 14:55" / "21.10.2026, 09:10" (for the teacher; the child goes by the pictures).
fileprivate func libraryDateText(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "de_DE")
    f.dateStyle = .medium
    f.timeStyle = .short
    f.doesRelativeDateFormatting = true
    return f.string(from: date)
}
