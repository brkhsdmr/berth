#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include "remote.h"
#include "source.h"

#pragma comment(lib, "ws2_32")

namespace {
constexpr const char* kPort = "47654";
}

RemoteLink::~RemoteLink() { stop(); }

void RemoteLink::configure(const std::wstring& host, const std::wstring& token, HWND notify, UINT message) {
    if (host == host_ && token == token_ && (running_ || host.empty())) return;
    stop();
    host_ = host;
    token_ = token;
    notify_ = notify;
    message_ = message;
    if (host.empty() || token.empty()) {
        setStatus(tx(L"Kapalı", L"Off"));
        return;
    }
    running_ = true;
    thread_ = std::thread(&RemoteLink::run, this, host, toUtf8(token));
}

void RemoteLink::stop() {
    running_ = false;
    unsigned long long s = socket_.exchange(~0ull);
    if (s != ~0ull) closesocket(SOCKET(s)); // Bekleyen recv/connect çağrısını çözer.
    if (thread_.joinable()) thread_.join();
}

std::wstring RemoteLink::status() const {
    std::lock_guard<std::mutex> guard(lock_);
    return status_;
}

void RemoteLink::setStatus(const std::wstring& s) {
    std::lock_guard<std::mutex> guard(lock_);
    status_ = s;
}

void RemoteLink::run(std::wstring host, std::string token) {
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    wchar_t computer[MAX_COMPUTERNAME_LENGTH + 1] = L"Windows";
    DWORD length = MAX_COMPUTERNAME_LENGTH + 1;
    GetComputerNameW(computer, &length);
    std::string hello = "HELLO " + token + " " + toUtf8(computer) + "\n";

    while (running_) {
        setStatus(tx(L"Bağlanıyor…", L"Connecting…"));
        addrinfoW hints{};
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_protocol = IPPROTO_TCP;
        addrinfoW* found = nullptr;
        SOCKET s = INVALID_SOCKET;
        if (GetAddrInfoW(host.c_str(), L"47654", &hints, &found) == 0) {
            for (auto* a = found; a && s == INVALID_SOCKET; a = a->ai_next) {
                SOCKET candidate = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
                if (candidate == INVALID_SOCKET) continue;
                socket_ = candidate;
                if (connect(candidate, a->ai_addr, int(a->ai_addrlen)) == 0) s = candidate;
                else if (socket_.exchange(~0ull) != ~0ull) closesocket(candidate);
            }
            FreeAddrInfoW(found);
        }
        if (s == INVALID_SOCKET) {
            setStatus(tx(L"Mac'e ulaşılamıyor; yeniden denenecek.", L"Can't reach the Mac; will retry."));
        } else {
            BOOL keep = TRUE;
            setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, reinterpret_cast<const char*>(&keep), sizeof keep);
            send(s, hello.c_str(), int(hello.size()), 0);
            std::string buffer;
            // 25 sn ses yoksa PING gönderilir, Mac PONG ile yanıtlar; üç kez yanıt gelmezse bağlantı ölüdür.
            DWORD shortTimeout = 25000;
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&shortTimeout), sizeof shortTimeout);
            int silent = 0;
            while (running_) {
                char chunk[256];
                int n = recv(s, chunk, sizeof chunk, 0);
                if (n == 0) break;
                if (n < 0) {
                    if (WSAGetLastError() != WSAETIMEDOUT || ++silent > 2) break;
                    send(s, "PING\n", 5, 0); // Sessizlik: canlı mı?
                    continue;
                }
                silent = 0;
                buffer.append(chunk, n);
                size_t newline;
                while ((newline = buffer.find('\n')) != std::string::npos) {
                    std::string line = buffer.substr(0, newline);
                    buffer.erase(0, newline + 1);
                    if (!line.empty() && line.back() == '\r') line.pop_back();
                    if (line == "OK") { denied_ = false; blocked_ = false; setStatus(tx(L"Bağlı: ", L"Connected: ") + host); }
                    else if (line == "BLOCKED") {
                        blocked_ = true;
                        setStatus(tx(L"Mac bu bilgisayarın bağlantısını kesti; Mac'teki Berth ayarlarından izin verin.",
                                     L"The Mac disconnected this PC; allow it again in Berth's settings on the Mac."));
                    }
                    else if (line == "DENIED") { denied_ = true; setStatus(tx(L"Kod kabul edilmedi; Mac'teki kodu girin.", L"Code rejected; enter the code shown on the Mac.")); }
                    else if (line == "TOGGLE" && notify_) PostMessageW(notify_, message_, 0, 0);
                    else if (line == "APPWINDOWS" && notify_) PostMessageW(notify_, message_, 1, 0); // Mac'te aşağı kaydırma.
                }
            }
            if (socket_.exchange(~0ull) != ~0ull) closesocket(s);
            if (running_ && !denied_ && !blocked_) setStatus(tx(L"Bağlantı koptu; yeniden denenecek.", L"Connection lost; will retry."));
        }
        // Yeniden denemeden önce bekle; kapatılırsa hemen çık. Engellendiyse Mac'te izin verilene
        // kadar seyrek denenir.
        int wait = blocked_ ? 300 : 50;
        blocked_ = false;
        for (int i = 0; i < wait && running_; ++i) Sleep(100);
    }
    WSACleanup();
}
