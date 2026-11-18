#pragma once
#include "Api.h"
#include <QElapsedTimer>
#include <QJsonArray>
#include <QSet>
#include <QTimer>

namespace pairwise {
class CallSession : public QObject {
  Q_OBJECT
public:
  explicit CallSession(QObject *parent = nullptr);
  void login(const QString &server, const QString &email,
             const QString &password);
  void restore(const QString &server, const QString &token);
  void logout();
  void call(const QString &userId);
  void answer(const QString &callId, bool accept);
  void cancelCall(const QString &callId);
  void requestJoin(const QString &roomId);
  void resolveJoin(const QString &id, bool accept);
  void cancelRequest(const QString &id);
  void joinRoom(const QString &id);
  void leave();
  void mediaConnected();
  void share(bool enabled, std::function<void(bool)> done);
  void poll();
  QJsonObject user;
  QJsonArray users, calls, activeCalls, joinRequests;
  QString roomId, connectingRoom;
  bool signedIn = false, busy = false, connected = false;
  Api api;
signals:
  void changed();
  void error(const QString &text);
  void authenticated(const QString &server, const QString &token);
  void signedOut();
  void connectMedia(const QString &url, const QString &token);
  void disconnectMedia();
  void missedCall(const QString &name);

private:
  void start(const QJsonObject &person);
  void failure(const ApiResult &result);
  void action(const QString &path, const QJsonObject &body,
              std::function<void(QJsonObject)> done);
  void pollStep(int step, quint64 current);
  void observeApprovals();
  QTimer timer, watchdog;
  QElapsedTimer monotonic;
  qint64 lastRoomHeartbeat = 0;
  bool polling = false, historyLoaded = false;
  quint64 generation = 0, roomGeneration = 0;
  QSet<QString> localRequests, seenMissed;
};
} // namespace pairwise
