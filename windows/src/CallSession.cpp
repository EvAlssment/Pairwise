#include "CallSession.h"
#include "Protocol.h"

namespace pairwise {
CallSession::CallSession(QObject *parent) : QObject(parent) {
  monotonic.start();
  timer.setInterval(3000);
  watchdog.setInterval(500);
  connect(&timer, &QTimer::timeout, this, &CallSession::poll);
  connect(&watchdog, &QTimer::timeout, this, [this] {
    if (!roomId.isEmpty() && monotonic.elapsed() - lastRoomHeartbeat > 20000) {
      leave();
      emit error("Call stopped because the server could not renew admission. "
                 "Rejoin when connected.");
    }
  });
}
void CallSession::login(const QString &server, const QString &email,
                        const QString &password) {
  if (busy || signedIn)
    return;
  auto url = serverUrl(server);
  if (!url) {
    emit error(
        "Enter an HTTPS server address. HTTP is allowed only on loopback.");
    return;
  }
  api.configure(*url);
  busy = true;
  emit changed();
  api.request(
      "/v1/login", "POST", {{"email", email.trimmed()}, {"password", password}},
      this, [this](ApiResult r) {
        busy = false;
        if (!r) {
          failure(r);
          emit changed();
          return;
        }
        auto token = r.body["token"].toString();
        auto person = r.body["user"].toObject();
        if (token.isEmpty() || person["id"].toString().isEmpty()) {
          emit error("The server returned an incompatible sign-in response.");
          emit changed();
          return;
        }
        api.configure(api.server(), token);
        emit authenticated(api.server().toString(), token);
        start(person);
      });
}
void CallSession::restore(const QString &server, const QString &token) {
  if (signedIn || busy || token.isEmpty())
    return;
  auto url = serverUrl(server);
  if (!url)
    return;
  api.configure(*url, token);
  busy = true;
  emit changed();
  api.request("/v1/me", "GET", {}, this, [this](ApiResult r) {
    busy = false;
    if (!r) {
      failure(r);
      emit changed();
      return;
    }
    auto person = r.body["user"].toObject();
    if (person["id"].toString().isEmpty()) {
      emit error("The server returned an incompatible account response.");
      emit changed();
      return;
    }
    start(person);
  });
}
void CallSession::start(const QJsonObject &person) {
  user = person;
  signedIn = true;
  ++generation;
  timer.start();
  watchdog.start();
  poll();
  emit changed();
}
void CallSession::failure(const ApiResult &r) {
  if (r.status == 401) {
    logout();
    emit error("Your session expired. Sign in again.");
  } else
    emit error(r.error);
}
void CallSession::logout() {
  leave();
  api.request("/v1/logout", "POST", {}, this, [](ApiResult) {});
  api.configure(api.server());
  ++generation;
  timer.stop();
  watchdog.stop();
  polling = false;
  busy = false;
  signedIn = false;
  user = {};
  users = {};
  calls = {};
  activeCalls = {};
  joinRequests = {};
  localRequests.clear();
  seenMissed.clear();
  historyLoaded = false;
  emit signedOut();
  emit changed();
}
void CallSession::action(const QString &path, const QJsonObject &body,
                         std::function<void(QJsonObject)> done) {
  if (!signedIn || busy)
    return;
  busy = true;
  emit changed();
  api.request(path, "POST", body, this, [this, done](ApiResult r) {
    busy = false;
    if (!r)
      failure(r);
    else
      done(r.body);
    emit changed();
  });
}
void CallSession::call(const QString &userId) {
  QJsonObject body{{"userId", userId}};
  if (!roomId.isEmpty())
    body["roomId"] = roomId;
  action("/v1/calls", body, [this](QJsonObject r) {
    if (roomId.isEmpty())
      joinRoom(r["call"].toObject()["room"].toObject()["id"].toString());
    poll();
  });
}
void CallSession::answer(const QString &id, bool accept) {
  if (accept && (!roomId.isEmpty() || !connectingRoom.isEmpty())) {
    emit error("Leave the current call before accepting another call.");
    return;
  }
  action("/v1/calls/" + id + (accept ? "/accept" : "/decline"), {},
         [this, accept](QJsonObject r) {
           if (accept)
             joinRoom(r["call"].toObject()["room"].toObject()["id"].toString());
           poll();
         });
}
void CallSession::cancelCall(const QString &id) {
  action("/v1/calls/" + id + "/cancel", {}, [this](QJsonObject) { poll(); });
}
void CallSession::requestJoin(const QString &id) {
  if (!roomId.isEmpty() || !connectingRoom.isEmpty())
    return;
  action("/v1/rooms/" + id + "/join-requests", {}, [this](QJsonObject r) {
    auto req = r["request"].toObject();
    localRequests.insert(req["id"].toString());
    joinRequests.append(req);
    observeApprovals();
    poll();
  });
}
void CallSession::resolveJoin(const QString &id, bool accept) {
  action("/v1/join-requests/" + id + (accept ? "/accept" : "/decline"), {},
         [this](QJsonObject) { poll(); });
}
void CallSession::cancelRequest(const QString &id) {
  localRequests.remove(id);
  action("/v1/join-requests/" + id + "/cancel", {},
         [this](QJsonObject) { poll(); });
}
void CallSession::observeApprovals() {
  if (!roomId.isEmpty() || !connectingRoom.isEmpty())
    return;
  for (const auto &value : joinRequests) {
    auto r = value.toObject();
    const auto id = r["id"].toString();
    if (!localRequests.contains(id) ||
        r["requester"].toObject()["id"] != user["id"])
      continue;
    if (r["status"] == "accepted") {
      localRequests.remove(id);
      joinRoom(r["room"].toObject()["id"].toString());
      return;
    }
    if (r["status"] != "pending")
      localRequests.remove(id);
  }
}
void CallSession::joinRoom(const QString &id) {
  if (id.isEmpty() || !signedIn || !roomId.isEmpty() ||
      !connectingRoom.isEmpty())
    return;
  connectingRoom = id;
  const auto current = ++roomGeneration;
  emit changed();
  api.request("/v1/rooms/" + id + "/join", "POST", {}, this,
              [this, id, current](ApiResult r) {
                if (current != roomGeneration) {
                  if (r)
                    api.request("/v1/rooms/" + id + "/leave", "POST", {}, this,
                                [](ApiResult) {});
                  return;
                }
                connectingRoom.clear();
                if (!r) {
                  failure(r);
                  emit changed();
                  return;
                }
                QUrl media(r.body["url"].toString());
                if (!mediaUrlAllowed(media, api.server()) ||
                    r.body["token"].toString().isEmpty() ||
                    r.body["participantIdentity"] != user["id"]) {
                  api.request("/v1/rooms/" + id + "/leave", "POST", {}, this,
                              [](ApiResult) {});
                  emit error("The server returned an invalid media admission.");
                  emit changed();
                  return;
                }
                roomId = id;
                lastRoomHeartbeat = monotonic.elapsed();
                emit connectMedia(media.toString(), r.body["token"].toString());
                emit changed();
              });
}
void CallSession::mediaConnected() {
  if (roomId.isEmpty())
    return;
  connected = true;
  poll();
  emit changed();
}
void CallSession::leave() {
  ++roomGeneration;
  localRequests.clear();
  const auto previous = roomId;
  roomId.clear();
  connectingRoom.clear();
  connected = false;
  emit disconnectMedia();
  if (!previous.isEmpty())
    api.request("/v1/rooms/" + previous + "/leave", "POST", {}, this,
                [](ApiResult) {});
  emit changed();
}
void CallSession::share(bool enabled, std::function<void(bool)> done) {
  if (roomId.isEmpty() || !connected) {
    done(false);
    return;
  }
  const auto current = roomGeneration;
  api.request("/v1/rooms/" + roomId + "/share", "POST", {{"enabled", enabled}},
              this, [this, current, done](ApiResult r) {
                if (current != roomGeneration) {
                  done(false);
                  return;
                }
                if (!r)
                  failure(r);
                done(bool(r));
              });
}
void CallSession::poll() {
  if (!signedIn || polling)
    return;
  polling = true;
  pollStep(0, generation);
}
void CallSession::pollStep(int step, quint64 current) {
  if (!signedIn || current != generation)
    return;
  if (step == 5 && roomId.isEmpty()) {
    polling = false;
    observeApprovals();
    emit changed();
    return;
  }
  const QStringList paths = {
      "/v1/heartbeat",     "/v1/users",
      "/v1/calls",         "/v1/active-calls",
      "/v1/join-requests", "/v1/rooms/" + roomId + "/heartbeat"};
  const auto roomCurrent = roomGeneration;
  api.request(paths[step], step == 0 || step == 5 ? "POST" : "GET", {}, this,
              [this, step, current, roomCurrent](ApiResult r) {
                if (current != generation)
                  return;
                if (!r) {
                  polling = false;
                  if (step == 5 && (r.status == 403 || r.status == 404) &&
                      roomCurrent == roomGeneration)
                    leave();
                  else
                    failure(r);
                  return;
                }
                if (step == 1)
                  users = r.body["users"].toArray();
                if (step == 2) {
                  calls = r.body["calls"].toArray();
                  for (const auto &v : calls) {
                    auto c = v.toObject();
                    auto id = c["id"].toString();
                    if (c["status"] == "expired" &&
                        c["target"].toObject()["id"] == user["id"] &&
                        !seenMissed.contains(id)) {
                      seenMissed.insert(id);
                      if (historyLoaded)
                        emit missedCall(
                            c["caller"].toObject()["name"].toString());
                    }
                  }
                  historyLoaded = true;
                }
                if (step == 3)
                  activeCalls = r.body["calls"].toArray();
                if (step == 4)
                  joinRequests = r.body["requests"].toArray();
                if (step == 5) {
                  if (roomCurrent == roomGeneration)
                    lastRoomHeartbeat = monotonic.elapsed();
                  polling = false;
                  observeApprovals();
                  emit changed();
                } else
                  pollStep(step + 1, current);
              });
}
} // namespace pairwise
