#include "Platform.h"
#include "Protocol.h"
#include <QCryptographicHash>
#include <QWidget>
#include <cmath>
#ifdef Q_OS_WIN
// clang-format off: wincred.h requires Windows types to be declared first.
#include <windows.h>
#include <wincred.h>
// clang-format on
#endif

namespace pairwise {
static QString target(const QString &server) {
  return "Pairwise/" +
         QString::fromLatin1(QCryptographicHash::hash(
                                 server.toUtf8(), QCryptographicHash::Sha256)
                                 .toHex());
}
bool saveToken(const QString &server, const QString &token) {
#ifdef Q_OS_WIN
  auto name = target(server).toStdWString();
  auto bytes = token.toUtf8();
  if (bytes.size() > CRED_MAX_CREDENTIAL_BLOB_SIZE)
    return false;
  CREDENTIALW credential{};
  credential.Type = CRED_TYPE_GENERIC;
  credential.TargetName = name.data();
  credential.UserName = const_cast<wchar_t *>(L"Pairwise");
  credential.CredentialBlobSize = DWORD(bytes.size());
  credential.CredentialBlob = reinterpret_cast<BYTE *>(bytes.data());
  credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
  return CredWriteW(&credential, 0);
#else
  Q_UNUSED(server);
  Q_UNUSED(token);
  return false;
#endif
}
QString loadToken(const QString &server) {
#ifdef Q_OS_WIN
  PCREDENTIALW credential = nullptr;
  auto name = target(server).toStdWString();
  if (!CredReadW(name.c_str(), CRED_TYPE_GENERIC, 0, &credential))
    return {};
  QString token =
      QString::fromUtf8(reinterpret_cast<char *>(credential->CredentialBlob),
                        credential->CredentialBlobSize);
  CredFree(credential);
  return token;
#else
  Q_UNUSED(server);
  return {};
#endif
}
void deleteToken(const QString &server) {
#ifdef Q_OS_WIN
  auto name = target(server).toStdWString();
  CredDeleteW(name.c_str(), CRED_TYPE_GENERIC, 0);
#else
  Q_UNUSED(server);
#endif
}
bool excludeFromCapture(QWidget *window) {
#ifdef Q_OS_WIN
  return SetWindowDisplayAffinity(reinterpret_cast<HWND>(window->winId()),
                                  0x11);
#else
  Q_UNUSED(window);
  return false;
#endif
}
std::optional<QRect> physicalDisplayRect(const QString &name) {
#ifdef Q_OS_WIN
  struct Match {
    QString name;
    std::optional<QRect> bounds;
  } match{name, {}};
  EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR monitor, HDC, LPRECT, LPARAM data) -> BOOL {
        auto *m = reinterpret_cast<Match *>(data);
        MONITORINFOEXW info{};
        info.cbSize = sizeof(info);
        if (GetMonitorInfoW(monitor, &info) &&
            QString::fromWCharArray(info.szDevice) == m->name) {
          auto r = info.rcMonitor;
          m->bounds = QRect(r.left, r.top, r.right - r.left, r.bottom - r.top);
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&match));
  return match.bounds;
#else
  Q_UNUSED(name);
  return {};
#endif
}
bool InputInjector::desktopAvailable() const {
#ifdef Q_OS_WIN
  HDESK desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!desktop)
    return false;
  wchar_t name[256]{};
  DWORD size = 0;
  bool result =
      GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name), &size) &&
      QString::fromWCharArray(name) == "Default";
  CloseDesktop(desktop);
  return result;
#else
  return false;
#endif
}
bool InputInjector::key(int code, bool down) {
#ifdef Q_OS_WIN
  INPUT event{};
  event.type = INPUT_KEYBOARD;
  event.ki.wVk = WORD(code);
  event.ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
  if (code == VK_DELETE || code == VK_HOME || code == VK_END ||
      code == VK_PRIOR || code == VK_NEXT ||
      (code >= VK_LEFT && code <= VK_DOWN))
    event.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
  event.ki.dwExtraInfo = 0x50414952;
  if (SendInput(1, &event, sizeof(event)) != 1)
    return false;
  if (down)
    heldKeys.insert(code);
  else
    heldKeys.remove(code);
  return true;
#else
  Q_UNUSED(code);
  Q_UNUSED(down);
  return false;
#endif
}
bool InputInjector::button(int code, bool down) {
#ifdef Q_OS_WIN
  const DWORD flags[3][2] = {{MOUSEEVENTF_LEFTUP, MOUSEEVENTF_LEFTDOWN},
                             {MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_RIGHTDOWN},
                             {MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MIDDLEDOWN}};
  if (code < 0 || code > 2)
    return false;
  INPUT e{};
  e.type = INPUT_MOUSE;
  e.mi.dwFlags = flags[code][down ? 1 : 0];
  e.mi.dwExtraInfo = 0x50414952;
  if (SendInput(1, &e, sizeof(e)) != 1)
    return false;
  if (down)
    heldButtons.insert(code);
  else
    heldButtons.remove(code);
  return true;
#else
  Q_UNUSED(code);
  Q_UNUSED(down);
  return false;
#endif
}
bool InputInjector::move(double x, double y, const QRect &bounds) {
#ifdef Q_OS_WIN
  if (bounds.isEmpty() || !std::isfinite(x) || !std::isfinite(y) || x < 0 ||
      x > 1 || y < 0 || y > 1)
    return false;
  int left = GetSystemMetrics(SM_XVIRTUALSCREEN),
      top = GetSystemMetrics(SM_YVIRTUALSCREEN),
      width = GetSystemMetrics(SM_CXVIRTUALSCREEN),
      height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  if (width <= 1 || height <= 1)
    return false;
  INPUT e{};
  e.type = INPUT_MOUSE;
  e.mi.dwFlags =
      MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
  e.mi.dx = LONG(std::llround((bounds.x() + x * (bounds.width() - 1) - left) *
                              65535.0 / (width - 1)));
  e.mi.dy = LONG(std::llround((bounds.y() + y * (bounds.height() - 1) - top) *
                              65535.0 / (height - 1)));
  e.mi.dwExtraInfo = 0x50414952;
  return SendInput(1, &e, sizeof(e)) == 1;
#else
  Q_UNUSED(x);
  Q_UNUSED(y);
  Q_UNUSED(bounds);
  return false;
#endif
}
bool InputInjector::modifiers(quint64 flags) {
#ifdef Q_OS_WIN
  // Mac Command and Control both map to the Windows primary shortcut key.
  const QMap<int, bool> wanted = {
      {VK_SHIFT, bool(flags & (1 << 17))},
      {VK_CONTROL, bool(flags & ((1 << 18) | (1 << 20)))},
      {VK_MENU, bool(flags & (1 << 19))}};
  for (auto i = wanted.begin(); i != wanted.end(); ++i)
    if (heldKeys.contains(i.key()) != i.value() && !key(i.key(), i.value()))
      return false;
  return true;
#else
  Q_UNUSED(flags);
  return false;
#endif
}
bool InputInjector::inject(const QJsonObject &p, const QRect &bounds) {
  if (!desktopAvailable())
    return false;
  const auto kind = p["kind"].toString();
  if (kind == "pointer")
    return move(p["x"].toDouble(), p["y"].toDouble(), bounds);
  if (kind == "button")
    return move(p["x"].toDouble(), p["y"].toDouble(), bounds) &&
           button(p["code"].toInt(), p["down"].toBool());
  if (kind == "releaseAll") {
    releaseAll();
    return true;
  }
#ifdef Q_OS_WIN
  if (kind == "scroll") {
    for (auto axis : {"deltaX", "deltaY"}) {
      double delta = p[axis].toDouble();
      if (delta == 0)
        continue;
      INPUT e{};
      e.type = INPUT_MOUSE;
      e.mi.dwFlags =
          QString(axis) == "deltaX" ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
      e.mi.mouseData = DWORD(LONG(std::llround(delta * WHEEL_DELTA)));
      e.mi.dwExtraInfo = 0x50414952;
      if (SendInput(1, &e, sizeof(e)) != 1)
        return false;
    }
    return true;
  }
  if (kind == "key") {
    int code = p["code"].toInt();
    bool down = p["down"].toBool();
    // v1 modifier-key packets carry the resulting modifier flags. Do not
    // inject a second transition that could undo those flags.
    if (code >= 54 && code <= 63)
      return modifiers(quint64(p["modifiers"].toInteger()));
    auto qt = qtKey(code);
    if (!qt)
      return false;
    int vk = 0;
    if ((*qt >= Qt::Key_A && *qt <= Qt::Key_Z) ||
        (*qt >= Qt::Key_0 && *qt <= Qt::Key_9))
      vk = *qt;
    else if (*qt >= Qt::Key_F1 && *qt <= Qt::Key_F19)
      vk = VK_F1 + *qt - Qt::Key_F1;
    else {
      const QMap<int, int> special = {{Qt::Key_Return, VK_RETURN},
                                      {Qt::Key_Enter, VK_RETURN},
                                      {Qt::Key_Tab, VK_TAB},
                                      {Qt::Key_Space, VK_SPACE},
                                      {Qt::Key_Backspace, VK_BACK},
                                      {Qt::Key_Delete, VK_DELETE},
                                      {Qt::Key_Escape, VK_ESCAPE},
                                      {Qt::Key_Left, VK_LEFT},
                                      {Qt::Key_Right, VK_RIGHT},
                                      {Qt::Key_Up, VK_UP},
                                      {Qt::Key_Down, VK_DOWN},
                                      {Qt::Key_Home, VK_HOME},
                                      {Qt::Key_End, VK_END},
                                      {Qt::Key_PageUp, VK_PRIOR},
                                      {Qt::Key_PageDown, VK_NEXT},
                                      {Qt::Key_Minus, VK_OEM_MINUS},
                                      {Qt::Key_Equal, VK_OEM_PLUS},
                                      {Qt::Key_BracketLeft, VK_OEM_4},
                                      {Qt::Key_BracketRight, VK_OEM_6},
                                      {Qt::Key_Backslash, VK_OEM_5},
                                      {Qt::Key_Semicolon, VK_OEM_1},
                                      {Qt::Key_Apostrophe, VK_OEM_7},
                                      {Qt::Key_Comma, VK_OEM_COMMA},
                                      {Qt::Key_Period, VK_OEM_PERIOD},
                                      {Qt::Key_Slash, VK_OEM_2},
                                      {Qt::Key_QuoteLeft, VK_OEM_3}};
      vk = special.value(*qt);
    }
    return vk && modifiers(quint64(p["modifiers"].toInteger())) &&
           key(vk, down);
  }
#endif
  return kind == "heartbeat";
}
bool InputInjector::shortcut(bool paste) {
#ifdef Q_OS_WIN
  if (!desktopAvailable())
    return false;
  releaseAll();
  const int code = paste ? 'V' : 'C';
  bool ok = key(VK_CONTROL, true) && key(code, true) && key(code, false) &&
            key(VK_CONTROL, false);
  releaseAll();
  return ok;
#else
  Q_UNUSED(paste);
  return false;
#endif
}
void InputInjector::releaseAll() {
  auto keys = heldKeys, buttons = heldButtons;
  for (int k : keys)
    key(k, false);
  for (int b : buttons)
    button(b, false);
}
} // namespace pairwise
