#pragma once
#include "Media.h"
#include "Platform.h"
#include "Protocol.h"
#include <QElapsedTimer>
#include <QTimer>

namespace pairwise {
class Collaboration : public QObject {
  Q_OBJECT
public:
  explicit Collaboration(Media *media, QObject *parent = nullptr);
  void begin(const QString &identity);
  void end();
  void sharing(bool enabled, bool window = false, const QRect &bounds = {});
  void view(const QString &sharer);
  void requestControl();
  void grant(const QString &identity);
  void releaseControl();
  void revoke();
  void deny(const QString &identity);
  void input(QJsonObject event);
  void cursor(const QPointF &position, bool visible = true);
  bool awaitingConsent(const QString &identity) const {
    return active && host && !windowShare && pendingRequests.contains(identity);
  }
  bool controlling() const { return !viewerEpoch.isEmpty(); }
  bool hosting() const { return !gate.driver.isEmpty(); }
  QString driver() const { return gate.driver; }
signals:
  void changed();
  void controlRequested(const QString &identity);
  void error(const QString &text);
  void pointer(const QString &identity, const QPointF &point, bool visible);

private:
  void receive(const QString &topic, const QJsonObject &p,
               const QString &sender);
  void send(QJsonObject p, const QString &to, bool reliable = true);
  void tick();
  void advertise(const QString &to = {});
  void copy(const QJsonObject &p, const QString &sender);
  void clipboard(const QJsonObject &p, const QString &sender);
  QJsonObject packet(const QString &kind, const QString &epoch = {});
  Media *media;
  QTimer timer;
  QElapsedTimer clock;
  QSet<QString> participants, pendingRequests;
  QString local, sharer, viewerEpoch, cursorSession, remoteCursorSession;
  QString pendingCopy, pendingPaste;
  qint64 pendingClipboardAt = 0, requestAt = 0, lastHeartbeat = 0,
         lastAdvertisement = 0;
  bool active = false, host = false, windowShare = false, requesting = false;
  QRect bounds;
  quint64 sequence = 0;
  QMap<QString, QJsonObject> availability;
  QMap<QString, quint64> cursorSequences;
  std::optional<QJsonObject> pendingPointer, pendingDrag;
  ControlGate gate;
  InputInjector injector;
  ClipboardAssembler assembler;
};
} // namespace pairwise
