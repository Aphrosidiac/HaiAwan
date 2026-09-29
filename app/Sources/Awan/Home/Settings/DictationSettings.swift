import SwiftUI

/// Settings → Dictation: language (auto-detect or pinned) and the personal dictionary.
struct DictationSettings: View {
    @ObservedObject private var prefs = Prefs.shared
    @Local private var search = ""
    @Local private var newWord = ""

    static let maxWords = 50

    var body: some View {
        SettingsPageHeader(title: "Dictation", subtitle: "Languages and the words Awan should spell right.")

        SettingsGroup(label: "Language", footer: "Auto-detect follows you across languages mid-sentence. Pin one language for the most accurate results.") {
            SettingToggle(title: "Auto-detect language", subtitle: "Awan works out the language as you speak.", isOn: $prefs.dictationAutoDetect)
            VStack(alignment: .leading, spacing: 10) {
                SettingsSearchField(placeholder: "Search languages", text: $search)
                if filtered.isEmpty {
                    Text("No languages match “\(search)”").font(.awan(12.5)).foregroundStyle(SettingsStyle.dim)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(filtered) { lang in languageCell(lang) }
                    }
                    .opacity(prefs.dictationAutoDetect ? 0.45 : 1)
                }
            }
            .padding(.leading, 14).padding(.trailing, 13.5)
            .padding(.top, 14).padding(.bottom, 14)
        }

        SettingsGroup(label: "Dictionary", footer: "Up to \(Self.maxWords) words. Awan leans toward these spellings: names, jargon, product words.") {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 7.5) {
                    SettingsInputField(placeholder: "Add a word", text: $newWord, onSubmit: add)
                    Button("Add", action: add)
                        .buttonStyle(.gel(.lime, height: 32, padding: 12, fontSize: 14.5))
                        .disabled(!canAdd)
                }
                if !prefs.dictionary.isEmpty {
                    FlowRow(spacing: 8) {
                        ForEach(prefs.dictionary, id: \.self) { w in wordChip(w) }
                    }
                }
            }
            .padding(.leading, 14).padding(.trailing, 13.5)
            .padding(.top, 12.5).padding(.bottom, 13)
        }
    }

    private var filtered: [DictationLanguage] {
        guard !search.isEmpty else { return DictationLanguage.ordered }
        let q = search.lowercased()
        return DictationLanguage.all.filter { $0.name.lowercased().contains(q) || $0.native.lowercased().contains(q) || $0.id == q }
    }

    /// Reference tile: 142×53, radius 10, white 2 % fill; name 14.5 at +14, native 12.5 at +31;
    /// the pinned language keeps its ring + check even while auto-detect dims the grid.
    private func languageCell(_ lang: DictationLanguage) -> some View {
        let selected = prefs.dictationLanguage == lang.id
        let showNative = lang.native != lang.name
        return Button {
            // Picking a language pins it (turns auto-detect off).
            prefs.dictationLanguage = lang.id
            prefs.dictationAutoDetect = false
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(lang.name).font(.awan(13.75, .medium)).foregroundStyle(Theme.text.opacity(selected ? 1 : 0.62)).lineLimit(1)
                    if showNative {
                        Text(lang.native).font(.awan(12, .medium)).foregroundStyle(SettingsStyle.dim).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if selected { SettingsCheckBadge(size: 19) }
            }
            .padding(.leading, 13).padding(.trailing, 12.5)
            .frame(maxWidth: .infinity, minHeight: 53, maxHeight: 53, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.white.opacity(0.03) : Color.white.opacity(0.015)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Theme.lime.opacity(0.9) : SettingsStyle.stroke, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(prefs.dictationAutoDetect ? "Pin \(lang.name) (turns off auto-detect)" : lang.name)
    }

    private func wordChip(_ w: String) -> some View {
        HStack(spacing: 7) {
            Text(w).font(.awan(14.5, .semibold)).foregroundStyle(Theme.text)
            Button {
                prefs.dictionary.removeAll { $0 == w }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(SettingsStyle.navText)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10).padding(.trailing, 11)
        .frame(height: 25)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }

    private var trimmed: String { newWord.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool {
        !trimmed.isEmpty && prefs.dictionary.count < Self.maxWords && !prefs.dictionary.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func add() {
        guard canAdd else { return }
        prefs.dictionary.append(String(trimmed.prefix(48)))
        newWord = ""
    }
}

struct DictationLanguage: Identifiable, Hashable {
    let id: String      // ISO 639-1
    let name: String
    let native: String

    /// The reference lists the twelve most used languages first, then the rest A–Z.
    static let popular = ["en", "es", "fr", "de", "hi", "zh", "ja", "ko", "pt", "ru", "ar", "it"]
    static var ordered: [DictationLanguage] {
        popular.compactMap { id in all.first { $0.id == id } } + all.filter { !popular.contains($0.id) }
    }

    static let all: [DictationLanguage] = [
        .init(id: "af", name: "Afrikaans", native: "Afrikaans"),
        .init(id: "ar", name: "Arabic", native: "العربية"),
        .init(id: "be", name: "Belarusian", native: "Беларуская"),
        .init(id: "bn", name: "Bengali", native: "বাংলা"),
        .init(id: "bs", name: "Bosnian", native: "Bosanski"),
        .init(id: "bg", name: "Bulgarian", native: "Български"),
        .init(id: "ca", name: "Catalan", native: "Català"),
        .init(id: "zh", name: "Chinese", native: "中文"),
        .init(id: "hr", name: "Croatian", native: "Hrvatski"),
        .init(id: "cs", name: "Czech", native: "Čeština"),
        .init(id: "da", name: "Danish", native: "Dansk"),
        .init(id: "nl", name: "Dutch", native: "Nederlands"),
        .init(id: "en", name: "English", native: "English"),
        .init(id: "et", name: "Estonian", native: "Eesti"),
        .init(id: "fi", name: "Finnish", native: "Suomi"),
        .init(id: "fr", name: "French", native: "Français"),
        .init(id: "de", name: "German", native: "Deutsch"),
        .init(id: "el", name: "Greek", native: "Ελληνικά"),
        .init(id: "gu", name: "Gujarati", native: "ગુજરાતી"),
        .init(id: "he", name: "Hebrew", native: "עברית"),
        .init(id: "hi", name: "Hindi", native: "हिन्दी"),
        .init(id: "hu", name: "Hungarian", native: "Magyar"),
        .init(id: "is", name: "Icelandic", native: "Íslenska"),
        .init(id: "id", name: "Indonesian", native: "Bahasa Indonesia"),
        .init(id: "it", name: "Italian", native: "Italiano"),
        .init(id: "ja", name: "Japanese", native: "日本語"),
        .init(id: "kn", name: "Kannada", native: "ಕನ್ನಡ"),
        .init(id: "kk", name: "Kazakh", native: "Қазақ тілі"),
        .init(id: "ko", name: "Korean", native: "한국어"),
        .init(id: "lv", name: "Latvian", native: "Latviešu"),
        .init(id: "lt", name: "Lithuanian", native: "Lietuvių"),
        .init(id: "mk", name: "Macedonian", native: "Македонски"),
        .init(id: "ms", name: "Malay", native: "Bahasa Melayu"),
        .init(id: "ml", name: "Malayalam", native: "മലയാളം"),
        .init(id: "mr", name: "Marathi", native: "मराठी"),
        .init(id: "ne", name: "Nepali", native: "नेपाली"),
        .init(id: "no", name: "Norwegian", native: "Norsk"),
        .init(id: "fa", name: "Persian", native: "فارسی"),
        .init(id: "pl", name: "Polish", native: "Polski"),
        .init(id: "pt", name: "Portuguese", native: "Português"),
        .init(id: "ro", name: "Romanian", native: "Română"),
        .init(id: "ru", name: "Russian", native: "Русский"),
        .init(id: "sr", name: "Serbian", native: "Српски"),
        .init(id: "sk", name: "Slovak", native: "Slovenčina"),
        .init(id: "sl", name: "Slovenian", native: "Slovenščina"),
        .init(id: "es", name: "Spanish", native: "Español"),
        .init(id: "sw", name: "Swahili", native: "Kiswahili"),
        .init(id: "sv", name: "Swedish", native: "Svenska"),
        .init(id: "tl", name: "Tagalog", native: "Tagalog"),
        .init(id: "ta", name: "Tamil", native: "தமிழ்"),
        .init(id: "te", name: "Telugu", native: "తెలుగు"),
        .init(id: "th", name: "Thai", native: "ไทย"),
        .init(id: "tr", name: "Turkish", native: "Türkçe"),
        .init(id: "uk", name: "Ukrainian", native: "Українська"),
        .init(id: "ur", name: "Urdu", native: "اردو"),
        .init(id: "vi", name: "Vietnamese", native: "Tiếng Việt"),
        .init(id: "cy", name: "Welsh", native: "Cymraeg"),
    ]
}
