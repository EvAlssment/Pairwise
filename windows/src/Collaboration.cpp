#include "Collaboration.h"
#include <QClipboard>
#include <QGuiApplication>
#include <QUuid>

namespace pairwise {
static QString uuid() {
  return QUuid::createUuid().toString(QUuid::WithoutBraces);
}
Collaboration::Collaboration(Media *value, QObject *parent)
    : QObject(parent), media(value) {
  clock.start();
  timer.setInterval(16);
  connect(&timer, &QTimer::timeout, this, &Collaboration::tick);
  connect(media, &Media::packet, this, &Collaboration::receive);
  connect(media, &Media::participantJoined, this, [this](const QString &id) {
    participants.insert(id);
    if (host)
      advertise(id);
  });
  connect(media, &Media::participantLeft, this, [this](const QString &id) {
    participants.remove(id);
    pendingRequests.remove(id);
    availability.remove(id);
    cursorSequences.remove(id);
    if (gate.driver == id)
      revoke();
    if (sharer == id)
      view({});
    emit pointer(id, {}, false);
    emit changed();
  });
  connect(media, &Media::reconnecting, this, [this] { end(); });
}
void Collaboration::begin(const QString &identity) {
  end();
  local = identity;
  active = true;
  timer.start();
}
void Collaboration::end() {
  releaseControl();
  revoke();
  active = false;
  timer.stop();
  participants.clear();
  pendingRequests.clear();
  availability.clear();
  cursorSequences.clear();
  local.clear();
  sharer.clear();
  cursorSession.clear();
  remoteCursorSession.clear();
  host = false;
  pendingCopy.clear();
  pendingPaste.clear();
  assembler.reset();
  pendingPointer.reset();
  pendingDrag.reset();
  emit changed();
}
QJsonObject Collaboration::packet(const QString &kind, const QString &epoch) {
  return message(kind, epoch, ++sequence);
}
void Collaboration::send(QJsonObject p, const QString &to, bool reliable) {
  if (active && participants.contains(to))
    media->send(ControlTopic, p, to, reliable);
}
void Collaboration::sharing(bool enabled, bool window, const QRect &physical) {
  revoke();
  releaseControl();
  host = enabled;
  windowShare = window;
  bounds = physical;
  cursorSession = enabled ? uuid() : QString{};
  cursorSequences.clear();
  advertise();
  emit changed();
}
void Collaboration::view(const QString &identity) {
  if (sharer == identity)
    return;
  releaseControl();
  sharer = identity;
  remoteCursorSession = availability.value(sharer)["cursorSession"].toString();
  emit changed();
}
void Collaboration::advertise(const QString &to) {
  if (!active || !host)
    return;
  auto p = packet("availability");
  p["available"] =
      !windowShare && !bounds.isEmpty() && injector.desktopAvailable();
  p["reason"] = windowShare ? "windowShare" : "paused";
  p["cursorSession"] = windowShare ? QString{} : cursorSession;
  p["clipboardEnabled"] = true;
  if (!to.isEmpty())
    send(p, to);
  else
    for (const auto &id : participants)
      send(p, id);
}
void Collaboration::requestControl() {
  if (!active || host || sharer.isEmpty() || requesting || controlling())
    return;
  const auto available = availability.value(sharer);
  if (available.contains("available") && !available["available"].toBool()) {
    emit error("The sharer cannot accept control right now.");
    return;
  }
  requesting = true;
  requestAt = clock.elapsed();
  auto p = packet("request");
  p["cursorSession"] = remoteCursorSession;
  send(p, sharer);
  emit changed();
}
void Collaboration::grant(const QString &id) {
  if (!active || !host || windowShare || !pendingRequests.remove(id) ||
      !participants.contains(id) || !injector.desktopAvailable() ||
      bounds.isEmpty())
    return;
  revoke();
  gate.grant(id, uuid(), clock.elapsed());
  auto p = packet("grant", gate.epoch);
  p["leaseMilliseconds"] = 2000;
  send(p, id);
  emit changed();
}
void Collaboration::releaseControl() {
  if (!viewerEpoch.isEmpty())
    send(packet("release", viewerEpoch), sharer);
  viewerEpoch.clear();
  requesting = false;
  pendingCopy.clear();
  pendingPaste.clear();
  assembler.reset();
  pendingPointer.reset();
  pendingDrag.reset();
  emit changed();
}
void Collaboration::deny(const QString &id) {
  if (pendingRequests.remove(id))
    send(packet("revoke"), id);
}
void Collaboration::revoke() {
  auto driver = gate.driver, epoch = gate.epoch;
  gate.revoke();
  injector.releaseAll();
  assembler.reset();
  if (!driver.isEmpty())
    send(packet("revoke", epoch), driver);
  for (const auto &id : pendingRequests)
    send(packet("revoke"), id);
  pendingRequests.clear();
  emit changed();
}
void Collaboration::input(QJsonObject event) {
  if (!active || viewerEpoch.isEmpty() || host)
    return;
  auto kind = event["kind"].toString();
  auto p = packet(kind, viewerEpoch);
  for (auto i = event.begin(); i != event.end(); ++i)
    p[i.key()] = i.value();
  if (kind == "clipboardCopy") {
    pendingCopy = uuid();
    pendingClipboardAt = clock.elapsed();
    p["clipboardRequestID"] = pendingCopy;
    send(p, sharer);
    return;
  }
  if (kind == "clipboardPaste") {
    pendingPaste = uuid();
    pendingClipboardAt = clock.elapsed();
    auto parts = clipboardParts(QGuiApplication::clipboard()->text(), sharer,
                                pendingPaste);
    if (parts.isEmpty()) {
      pendingPaste.clear();
      emit error("Copy plain text of at most 64 KB before pasting.");
      return;
    }
    for (const auto &part : parts) {
      auto m = packet("clipboardPaste", viewerEpoch);
      m["clipboard"] = part;
      send(m, sharer);
    }
    return;
  }
  if (kind == "pointer") {
    pendingDrag = p;
    return;
  }
  if (kind == "button" || kind == "releaseAll")
    pendingDrag.reset();
  if (validControl(p))
    send(p, sharer);
}
void Collaboration::cursor(const QPointF &position, bool visible) {
  if (!active || host || sharer.isEmpty() || remoteCursorSession.isEmpty())
    return;
  auto p = packet("cursor", remoteCursorSession);
  p["visible"] = visible;
  p["x"] = position.x();
  p["y"] = position.y();
  pendingPointer = p;
}
void Collaboration::tick() {
  if (!active)
    return;
  if (!viewerEpoch.isEmpty() && clock.elapsed() - lastHeartbeat >= 500) {
    lastHeartbeat = clock.elapsed();
    auto p = packet("heartbeat", viewerEpoch);
    p["leaseMilliseconds"] = 2000;
    send(p, sharer);
  }
  if (!gate.driver.isEmpty() &&
      (!gate.active(clock.elapsed()) || !injector.desktopAvailable()))
    revoke();
  if (gate.driver.isEmpty())
    injector.releaseAll();
  if (requesting && clock.elapsed() - requestAt > 5000) {
    requesting = false;
    emit error("Control was not granted. Ask the sharer and try again.");
    emit changed();
  }
  if ((!pendingCopy.isEmpty() || !pendingPaste.isEmpty()) &&
      clock.elapsed() - pendingClipboardAt > 3000) {
    pendingCopy.clear();
    pendingPaste.clear();
    assembler.reset();
    emit error("Remote copy or paste timed out.");
  }
  if (pendingPointer) {
    send(*pendingPointer, sharer, false);
    pendingPointer.reset();
  }
  if (pendingDrag) {
    send(*pendingDrag, sharer, false);
    pendingDrag.reset();
  }
  // Availability is also periodic so viewers joining an existing share recover
  // it.
  if (host && clock.elapsed() - lastAdvertisement >= 1000) {
    lastAdvertisement = clock.elapsed();
    advertise();
  }
}
void Collaboration::receive(const QString &topic, const QJsonObject &p,
                            const QString &sender) {
  if (!active || topic != ControlTopic || sender == local ||
      !participants.contains(sender) || !validControl(p))
    return;
  const auto kind = p["kind"].toString();
  if (kind == "availability" && !host) {
    availability[sender] = p;
    if (sender == sharer) {
      remoteCursorSession = p["cursorSession"].toString();
      if (p["available"] == false)
        releaseControl();
    }
    return;
  }
  if (kind == "request" && host && !windowShare && !bounds.isEmpty()) {
    if (gate.driver == sender && gate.active(clock.elapsed()))
      return;
    if (pendingRequests.contains(sender))
      return;
    if (pendingRequests.size() >= 4)
      return;
    pendingRequests.insert(sender);
    emit controlRequested(sender);
    return;
  }
  if (kind == "grant" && !host && sender == sharer && requesting &&
      !p["epoch"].toString().isEmpty()) {
    viewerEpoch = p["epoch"].toString();
    requesting = false;
    emit changed();
    return;
  }
  if ((kind == "revoke" || kind == "hostPermissionRequired") &&
      sender == sharer) {
    releaseControl();
    return;
  }
  if (kind == "cursor" && host && p["epoch"] == cursorSession &&
      quint64(p["sequence"].toInteger()) > cursorSequences.value(sender)) {
    cursorSequences[sender] = quint64(p["sequence"].toInteger());
    emit pointer(sender, {p["x"].toDouble(), p["y"].toDouble()},
                 p["visible"] != false);
    auto relay = p;
    relay["kind"] = "cursorBroadcast";
    relay["pointerIdentity"] = sender;
    for (const auto &id : participants)
      if (id != sender)
        send(relay, id, false);
    return;
  }
  if (kind == "cursorBroadcast" && sender == sharer &&
      p["epoch"] == remoteCursorSession) {
    auto id = p["pointerIdentity"].toString();
    if (!participants.contains(id) || id == local ||
        quint64(p["sequence"].toInteger()) <= cursorSequences.value(id))
      return;
    cursorSequences[id] = quint64(p["sequence"].toInteger());
    emit pointer(id, {p["x"].toDouble(), p["y"].toDouble()},
                 p["visible"] != false);
    return;
  }
  if ((kind == "clipboardCopied" || kind == "clipboardPasted" ||
       kind == "clipboardFailure") &&
      sender == sharer && p["epoch"] == viewerEpoch && !viewerEpoch.isEmpty()) {
    clipboard(p, sender);
    return;
  }
  if (!host || windowShare || !gate.accept(p, sender, clock.elapsed()))
    return;
  if (kind == "release") {
    revoke();
    return;
  }
  if (kind == "clipboardCopy") {
    copy(p, sender);
    return;
  }
  if (kind == "clipboardPaste") {
    if (auto text = assembler.add(p["clipboard"].toObject(), sender, local)) {
      QGuiApplication::clipboard()->setText(*text);
      const bool success = injector.shortcut(true);
      auto result =
          packet(success ? "clipboardPasted" : "clipboardFailure", gate.epoch);
      result["clipboardRequestID"] = p["clipboard"].toObject()["id"];
      send(result, sender);
      if (!success)
        revoke();
    }
    return;
  }
  if (kind == "pointer") {
    // Independent cursors must not move the owner's pointer while hovering.
    emit pointer(sender, {p["x"].toDouble(), p["y"].toDouble()}, true);
    if (injector.dragging() && !injector.inject(p, bounds))
      revoke();
    return;
  }
  if (!injector.inject(p, bounds)) {
    revoke();
    emit error("Windows refused remote input. Control stopped; elevated apps "
               "and secure desktop are unsupported.");
  }
}
void Collaboration::copy(const QJsonObject &p, const QString &sender) {
  const auto id = p["clipboardRequestID"].toString();
  if (QUuid(id).isNull())
    return;
  const auto epoch = gate.epoch;
  auto *clipboard = QGuiApplication::clipboard();
  auto connection = std::make_shared<QMetaObject::Connection>();
  auto finished = std::make_shared<bool>(false);
  auto fail = [this, id, sender, epoch, connection, finished] {
    if (*finished)
      return;
    *finished = true;
    disconnect(*connection);
    if (!gate.active(clock.elapsed()) || gate.epoch != epoch)
      return;
    auto result = packet("clipboardFailure", epoch);
    result["clipboardRequestID"] = id;
    send(result, sender);
  };
  *connection = connect(clipboard, &QClipboard::dataChanged, this,
                        [this, id, sender, epoch, connection, finished] {
                          if (*finished)
                            return;
                          *finished = true;
                          disconnect(*connection);
                          if (!gate.active(clock.elapsed()) ||
                              gate.driver != sender || gate.epoch != epoch)
                            return;
                          const auto parts = clipboardParts(
                              QGuiApplication::clipboard()->text(), sender, id);
                          for (const auto &part : parts) {
                            auto result = packet("clipboardCopied", epoch);
                            result["clipboardRequestID"] = id;
                            result["clipboard"] = part;
                            send(result, sender);
                          }
                          if (parts.isEmpty()) {
                            auto result = packet("clipboardFailure", epoch);
                            result["clipboardRequestID"] = id;
                            send(result, sender);
                          }
                        });
  if (!injector.shortcut(false))
    fail();
  QTimer::singleShot(1000, this, fail);
}
void Collaboration::clipboard(const QJsonObject &p, const QString &sender) {
  const auto id = p["clipboardRequestID"].toString(),
             kind = p["kind"].toString();
  if (id.isEmpty() || (id != pendingCopy && id != pendingPaste))
    return;
  if (kind == "clipboardFailure") {
    pendingCopy.clear();
    pendingPaste.clear();
    emit error("The remote app could not copy or paste plain text.");
  } else if (kind == "clipboardPasted" && id == pendingPaste)
    pendingPaste.clear();
  else if (kind == "clipboardCopied" && id == pendingCopy &&
           p["clipboard"].toObject()["id"] == id) {
    if (auto text = assembler.add(p["clipboard"].toObject(), sender, local)) {
      QGuiApplication::clipboard()->setText(*text);
      pendingCopy.clear();
    }
  }
}
} // namespace pairwise
