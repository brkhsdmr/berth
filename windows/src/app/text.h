// Arayüz dili. Windows'un görüntü dili Türkçe ise Türkçe, değilse İngilizce; ayarlardan
// değiştirilebilir (yeniden başlatınca geçerli olur). Metinler kullanıldıkları yerde iki dilde yazılır.
#pragma once
#include <string>

namespace text {
/// 0: Windows'a uy, 1: Türkçe, 2: İngilizce. Settings::language ile aynı.
enum Language { Automatic = 0, Turkish = 1, English = 2 };

bool english();
inline const wchar_t* tx(const wchar_t* tr, const wchar_t* en) { return english() ? en : tr; }
/// "3 pencere" / "1 window" / "3 windows".
std::wstring windows(size_t n);
/// "2 uygulama" / "1 app" / "2 apps".
std::wstring apps(size_t n);
/// DirectWrite metin biçimleri için yerel ayar adı.
const wchar_t* locale();
} // namespace text

using text::tx;
