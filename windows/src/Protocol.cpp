#include "Protocol.h"
#include <QJsonDocument>
#include <QUuid>
#include <cmath>
#include <limits>

namespace pairwise {
std::optional<QUrl> serverUrl(const QString &input) {
  QUrl url(input.trimmed(), QUrl::StrictMode);
  const bool local = QStringList{"localhost", "127.0.0.1", "::1"}.contains(
      url.host().toLower());
  if (!url.isValid() || url.host().isEmpty() || !url.userInfo().isEmpty() ||
      url.hasQuery() || url.hasFragment() ||
      (url.path() != "" && url.path() != "/") ||
      (url.scheme() != "https" && !(url.scheme() == "http" && local)))
    return {};
  url.setPath("");
  return url;
}
bool mediaUrlAllowed(const QUrl &url, const QUrl &api) {
  return url.isValid() && !url.host().isEmpty() && url.userInfo().isEmpty() &&
         !url.hasFragment() &&
         (url.scheme() == "wss" ||
          (api.scheme() == "http" && url.scheme() == "ws" &&
           QStringList{"localhost", "127.0.0.1", "::1"}.contains(
               url.host().toLower())));
}
static const QMap<int, int> &keys() {
  static const QMap<int, int> table = {{Qt::Key_A, 0},
                                       {Qt::Key_S, 1},
                                       {Qt::Key_D, 2},
                                       {Qt::Key_F, 3},
                                       {Qt::Key_H, 4},
                                       {Qt::Key_G, 5},
                                       {Qt::Key_Z, 6},
                                       {Qt::Key_X, 7},
                                       {Qt::Key_C, 8},
                                       {Qt::Key_V, 9},
                                       {Qt::Key_B, 11},
                                       {Qt::Key_Q, 12},
                                       {Qt::Key_W, 13},
                                       {Qt::Key_E, 14},
                                       {Qt::Key_R, 15},
                                       {Qt::Key_Y, 16},
                                       {Qt::Key_T, 17},
                                       {Qt::Key_1, 18},
                                       {Qt::Key_2, 19},
                                       {Qt::Key_3, 20},
                                       {Qt::Key_4, 21},
                                       {Qt::Key_6, 22},
                                       {Qt::Key_5, 23},
                                       {Qt::Key_Equal, 24},
                                       {Qt::Key_9, 25},
                                       {Qt::Key_7, 26},
                                       {Qt::Key_Minus, 27},
                                       {Qt::Key_8, 28},
                                       {Qt::Key_0, 29},
                                       {Qt::Key_BracketRight, 30},
                                       {Qt::Key_O, 31},
                                       {Qt::Key_U, 32},
                                       {Qt::Key_BracketLeft, 33},
                                       {Qt::Key_I, 34},
                                       {Qt::Key_P, 35},
                                       {Qt::Key_Return, 36},
                                       {Qt::Key_L, 37},
                                       {Qt::Key_J, 38},
                                       {Qt::Key_Apostrophe, 39},
                                       {Qt::Key_K, 40},
                                       {Qt::Key_Semicolon, 41},
                                       {Qt::Key_Backslash, 42},
                                       {Qt::Key_Comma, 43},
                                       {Qt::Key_Slash, 44},
                                       {Qt::Key_N, 45},
                                       {Qt::Key_M, 46},
                                       {Qt::Key_Period, 47},
                                       {Qt::Key_Tab, 48},
                                       {Qt::Key_Space, 49},
                                       {Qt::Key_QuoteLeft, 50},
                                       {Qt::Key_Backspace, 51},
                                       {Qt::Key_Escape, 53},
                                       {Qt::Key_F17, 64},
                                       {Qt::Key_F18, 79},
                                       {Qt::Key_F19, 80},
                                       {Qt::Key_Enter, 76},
                                       {Qt::Key_F5, 96},
                                       {Qt::Key_F6, 97},
                                       {Qt::Key_F7, 98},
                                       {Qt::Key_F3, 99},
                                       {Qt::Key_F8, 100},
                                       {Qt::Key_F9, 101},
                                       {Qt::Key_F11, 103},
                                       {Qt::Key_F13, 105},
                                       {Qt::Key_F16, 106},
                                       {Qt::Key_F14, 107},
                                       {Qt::Key_F10, 109},
                                       {Qt::Key_F12, 111},
                                       {Qt::Key_F15, 113},
                                       {Qt::Key_Home, 115},
                                       {Qt::Key_PageUp, 116},
                                       {Qt::Key_Delete, 117},
                                       {Qt::Key_F4, 118},
                                       {Qt::Key_End, 119},
                                       {Qt::Key_F2, 120},
                                       {Qt::Key_PageDown, 121},
                                       {Qt::Key_F1, 122},
                                       {Qt::Key_Left, 123},
                                       {Qt::Key_Right, 124},
                                       {Qt::Key_Down, 125},
                                       {Qt::Key_Up, 126}};
  return table;
}
std::optional<int> macKey(int key) {
  auto i = keys().find(key);
  return i == keys().end() ? std::nullopt : std::optional(i.value());
}
std::optional<int> qtKey(int code) {
  for (auto i = keys().begin(); i != keys().end(); ++i)
    if (i.value() == code)
      return i.key();
  return {};
}
quint64 macModifiers(Qt::KeyboardModifiers m) {
  // Primary shortcuts: Windows Ctrl -> macOS Command. Windows Meta -> macOS
  // Control.
  return (m.testFlag(Qt::ShiftModifier) ? 1ULL << 17 : 0) |
         (m.testFlag(Qt::ControlModifier) ? 1ULL << 20 : 0) |
         (m.testFlag(Qt::AltModifier) ? 1ULL << 19 : 0) |
         (m.testFlag(Qt::MetaModifier) ? 1ULL << 18 : 0);
}
QRectF fittedRect(const QSize &video, const QSize &canvas) {
  if (video.isEmpty() || canvas.isEmpty())
    return {};
  auto size = QSizeF(video);
  size.scale(QSizeF(canvas), Qt::KeepAspectRatio);
  return {(canvas.width() - size.width()) / 2,
          (canvas.height() - size.height()) / 2, size.width(), size.height()};
}
std::optional<QPointF> normalizedPoint(const QPointF &point, const QSize &video,
                                       const QSize &canvas) {
  const auto r = fittedRect(video, canvas);
  if (r.isEmpty() || !r.contains(point))
    return {};
  return QPointF((point.x() - r.x()) / r.width(),
                 (point.y() - r.y()) / r.height());
}
static QDateTime date(const QJsonValue &value) {
  return QDateTime::fromString(value.toString(), Qt::ISODateWithMs);
}
std::optional<qint64> callDuration(const QJsonObject &call) {
  auto start = date(call["startedAt"]), end = date(call["endedAt"]);
  if (!start.isValid() || !end.isValid() || end < start)
    return {};
  return start.secsTo(end);
}
QJsonObject message(const QString &kind, const QString &epoch,
                    quint64 sequence) {
  return {{"version", 1},
          {"kind", kind},
          {"epoch", epoch},
          {"sequence", qint64(sequence)}};
}
static bool integer(const QJsonValue &v, double min, double max) {
  const double d = v.toDouble(std::numeric_limits<double>::quiet_NaN());
  return std::isfinite(d) && d >= min && d <= max && std::floor(d) == d;
}
bool validControl(const QJsonObject &p) {
  if (p["version"] != 1 || !p["epoch"].isString() ||
      p["epoch"].toString().size() > 128 ||
      !integer(p["sequence"], 1, 9007199254740991.0) || !p["kind"].isString())
    return false;
  const auto kind = p["kind"].toString();
  const QSet<QString> known = {"request",          "grant",
                               "revoke",           "release",
                               "heartbeat",        "releaseAll",
                               "availability",     "hostPermissionRequired",
                               "pointer",          "cursor",
                               "cursorBroadcast",  "key",
                               "button",           "scroll",
                               "clipboardCopy",    "clipboardPaste",
                               "clipboardCopied",  "clipboardPasted",
                               "clipboardFailure", "latencyProbe",
                               "latencyProbeAck"};
  if (!known.contains(kind))
    return false;
  if (kind == "pointer" || kind == "button" ||
      ((kind == "cursor" || kind == "cursorBroadcast") &&
       p["visible"] != false)) {
    for (auto field : {"x", "y"}) {
      double d = p[field].toDouble(-1);
      if (!std::isfinite(d) || d < 0 || d > 1)
        return false;
    }
  }
  if (kind == "key" &&
      (!integer(p["code"], 0, 127) || !p["down"].isBool() ||
       !integer(p["modifiers"], 0, (1 << 24) - 1) ||
       (p["modifiers"].toInteger() &
        ~((1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)))))
    return false;
  if (kind == "button" && (!integer(p["code"], 0, 2) || !p["down"].isBool()))
    return false;
  if (kind == "scroll")
    for (auto f : {"deltaX", "deltaY"}) {
      double d = p[f].toDouble(1e9);
      if (!std::isfinite(d) || std::abs(d) > 200)
        return false;
    }
  if (kind == "heartbeat" && p.contains("leaseMilliseconds") &&
      !integer(p["leaseMilliseconds"], 100, 2000))
    return false;
  return QJsonDocument(p).toJson(QJsonDocument::Compact).size() <=
         MaximumWireBytes;
}
void ControlGate::grant(const QString &identity, const QString &value,
                        qint64 now) {
  revoke();
  if (identity.isEmpty() || value.isEmpty())
    return;
  driver = identity;
  epoch = value;
  expiry = now + 2000;
}
void ControlGate::revoke() {
  driver.clear();
  epoch.clear();
  expiry = 0;
  orderedSequence = pointerSequence = 0;
}
bool ControlGate::active(qint64 now) const {
  return !driver.isEmpty() && now < expiry;
}
bool ControlGate::accept(const QJsonObject &p, const QString &sender,
                         qint64 now) {
  if (!validControl(p) || !active(now) || sender != driver ||
      p["epoch"].toString() != epoch)
    return false;
  auto sequence = quint64(p["sequence"].toInteger());
  if (p["kind"] == "pointer") {
    if (sequence <= qMax(orderedSequence, pointerSequence))
      return false;
    pointerSequence = sequence;
  } else {
    if (sequence <= orderedSequence)
      return false;
    orderedSequence = sequence;
  }
  if (p["kind"] == "heartbeat")
    expiry = now + qBound(qint64(100), p["leaseMilliseconds"].toInteger(2000),
                          qint64(2000));
  return true;
}
static double swiftTime(QDateTime now) {
  return now.toMSecsSinceEpoch() / 1000.0 - 978307200.0;
}
QList<QJsonObject> clipboardParts(const QString &text, const QString &recipient,
                                  const QString &id, QDateTime now) {
  if (text.isEmpty() || text.toUtf8().size() > MaximumTextBytes ||
      recipient.isEmpty() || recipient.toUtf8().size() > 256 ||
      QUuid(id).isNull())
    return {};
  QStringList chunks;
  QString chunk;
  int bytes = 0, escaped = 0;
  const auto scalars = text.toUcs4();
  for (char32_t scalar : scalars) {
    QString s = QString::fromUcs4(&scalar, 1);
    int size = s.toUtf8().size();
    int esc =
        scalar < 32
            ? 6
            : ((scalar == '"' || scalar == '\\' || scalar == '/') ? 2 : size);
    if (bytes + size > 6144 || escaped + esc > 12288) {
      chunks << chunk;
      chunk.clear();
      bytes = escaped = 0;
    }
    chunk += s;
    bytes += size;
    escaped += esc;
  }
  if (!chunk.isEmpty())
    chunks << chunk;
  if (chunks.size() > 33)
    return {};
  QList<QJsonObject> result;
  for (int i = 0; i < chunks.size(); ++i)
    result.append({{"version", 1},
                   {"id", id},
                   {"recipientIdentity", recipient},
                   {"createdAt", swiftTime(now)},
                   {"part", i},
                   {"parts", chunks.size()},
                   {"text", chunks[i]}});
  return result;
}
std::optional<QString> ClipboardAssembler::add(const QJsonObject &p,
                                               const QString &sender,
                                               const QString &local,
                                               QDateTime now) {
  const qint64 ms = now.toMSecsSinceEpoch();
  for (auto i = pending.begin(); i != pending.end();)
    if (swiftTime(now) - i->created > 120)
      i = pending.erase(i);
    else
      ++i;
  for (auto i = completed.begin(); i != completed.end();)
    if (ms - i.value() > 120000)
      i = completed.erase(i);
    else
      ++i;
  auto id = p["id"].toString();
  QString key = sender + ":" + id;
  double created =
      p["createdAt"].toDouble(std::numeric_limits<double>::quiet_NaN());
  if (p["version"] != 1 || QUuid(id).isNull() || sender.isEmpty() ||
      sender == local || p["recipientIdentity"] != local ||
      !std::isfinite(created) || created > swiftTime(now) + 5 ||
      swiftTime(now) - created > 120 || !integer(p["parts"], 1, 33) ||
      !integer(p["part"], 0, p["parts"].toInt() - 1) || !p["text"].isString() ||
      p["text"].toString().isEmpty() || completed.contains(key) ||
      QJsonDocument(p).toJson(QJsonDocument::Compact).size() > MaximumWireBytes)
    return {};
  if (!pending.contains(key)) {
    if (pending.size() >= 16)
      return {};
    pending.insert(key, {p["parts"].toInt(), 0, created, {}});
  }
  auto &item = pending[key];
  int index = p["part"].toInt();
  auto text = p["text"].toString();
  if (item.count != p["parts"].toInt() || item.created != created) {
    pending.remove(key);
    return {};
  }
  if (item.texts.contains(index)) {
    if (item.texts[index] != text)
      pending.remove(key);
    return {};
  }
  item.bytes += text.toUtf8().size();
  if (item.bytes > MaximumTextBytes) {
    pending.remove(key);
    return {};
  }
  item.texts.insert(index, text);
  if (item.texts.size() != item.count)
    return {};
  QString result;
  for (const auto &part : item.texts)
    result += part;
  pending.remove(key);
  if (completed.size() >= 1024)
    return {};
  completed.insert(key, ms);
  return result;
}
void ClipboardAssembler::reset() {
  pending.clear();
  completed.clear();
}
} // namespace pairwise
