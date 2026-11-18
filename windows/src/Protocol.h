#pragma once
#include <QDateTime>
#include <QJsonObject>
#include <QMap>
#include <QPointF>
#include <QRectF>
#include <QSet>
#include <QSize>
#include <QUrl>
#include <optional>

namespace pairwise {
inline constexpr auto ControlTopic = "pairdesk.control.v1";
inline constexpr qint64 MaximumWireBytes = 15000;
inline constexpr qint64 MaximumTextBytes = 64 * 1024;
std::optional<QUrl> serverUrl(const QString &input);
bool mediaUrlAllowed(const QUrl &url, const QUrl &api);
std::optional<int> macKey(int qtKey);
std::optional<int> qtKey(int macCode);
quint64 macModifiers(Qt::KeyboardModifiers modifiers);
QRectF fittedRect(const QSize &video, const QSize &canvas);
std::optional<QPointF> normalizedPoint(const QPointF &point, const QSize &video,
                                       const QSize &canvas);
std::optional<qint64> callDuration(const QJsonObject &call);

// Explicit v1 codec: key codes are Apple virtual key codes on EVERY platform.
// Qt/Win32 codes must never be written directly into a v1 packet.
QJsonObject message(const QString &kind, const QString &epoch,
                    quint64 sequence);
bool validControl(const QJsonObject &packet);
class ControlGate {
public:
  void grant(const QString &identity, const QString &epoch, qint64 now);
  void revoke();
  bool active(qint64 now) const;
  bool accept(const QJsonObject &packet, const QString &sender, qint64 now);
  QString driver, epoch;

private:
  qint64 expiry = 0;
  quint64 orderedSequence = 0, pointerSequence = 0;
};

QList<QJsonObject>
clipboardParts(const QString &text, const QString &recipient, const QString &id,
               QDateTime now = QDateTime::currentDateTimeUtc());
class ClipboardAssembler {
public:
  std::optional<QString> add(const QJsonObject &part, const QString &sender,
                             const QString &local,
                             QDateTime now = QDateTime::currentDateTimeUtc());
  void reset();

private:
  struct Partial {
    int count = 0;
    qint64 bytes = 0;
    double created = 0;
    QMap<int, QString> texts;
  };
  QMap<QString, Partial> pending;
  QMap<QString, qint64> completed;
};
} // namespace pairwise
