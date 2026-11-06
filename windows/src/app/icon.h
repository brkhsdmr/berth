// Uygulama simgesi kodla çizilir: kaynak dosyası (.rc) gerekmez.
#pragma once
#include <windows.h>

/// Üst üste üç pencere. `tray` true ise görev çubuğu temasına göre tek renk çizgi simge,
/// değilse vurgu renkli zeminli uygulama simgesi.
HICON makeAppIcon(int size, bool tray);

/// Dağıtım için app.ico ve mağaza logolarını klasöre yazar (sabit marka rengiyle).
#include <string>
bool writeIconAssets(const std::wstring& folder);
