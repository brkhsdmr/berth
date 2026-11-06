/// Kısayolun kullanıcıya görünen yazısı. Semboller Apple'ın menü sırasını izler: ⌃ ⌥ ⇧ ⌘.
public enum ShortcutFormat {
    public static func display(control: Bool, option: Bool, shift: Bool, command: Bool, key: String) -> String {
        var symbols = ""
        if control { symbols += "⌃" }
        if option { symbols += "⌥" }
        if shift { symbols += "⇧" }
        if command { symbols += "⌘" }
        return symbols + key
    }

    /// Değiştiricisiz kısayol yazmayı engeller: harf yazarken sahne açılırdı.
    public static func isAcceptable(control: Bool, option: Bool, shift _: Bool, command: Bool) -> Bool {
        control || option || command
    }
}
