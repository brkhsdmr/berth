// Mac'teki Berth'e bağlanan istemci. Windows App (RDP) öndeyken Mac'te yapılan
// trackpad hareketi bu bağlantıdan "TOGGLE" olarak gelir. Bağlantıyı Windows açtığı için güvenlik
// duvarında kural gerekmez.
#pragma once
#include <windows.h>
#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include "text.h"

class RemoteLink {
public:
    ~RemoteLink();
    /// Boş adres bağlantıyı kapatır. `notify` penceresine her komutta `message` gönderilir.
    void configure(const std::wstring& host, const std::wstring& token, HWND notify, UINT message);
    std::wstring status() const;

private:
    void run(std::wstring host, std::string token);
    void stop();
    void setStatus(const std::wstring& s);

    std::thread thread_;
    std::atomic<bool> running_{false};
    std::atomic<unsigned long long> socket_{~0ull};
    HWND notify_ = nullptr;
    UINT message_ = 0;
    mutable std::mutex lock_;
    std::wstring status_ = tx(L"Kapalı", L"Off");
    bool denied_ = false;
    std::wstring host_, token_;
};
