#include "CallSession.h"
#include "Protocol.h"
#include <QFile>
#include <QJsonDocument>
#include <QSignalSpy>
#include <QTcpServer>
#include <QTcpSocket>
#include <QtTest>

using namespace pairwise;
class FakeApi : public QObject {
public:
  QTcpServer server;
  QStringList paths;
  QList<QJsonObject> invitations;
  QJsonArray calls, requests;
  bool failHeartbeat = false;
  explicit FakeApi() {
    if (!server.listen(QHostAddress::LocalHost))
      qFatal("fake server failed");
    connect(&server, &QTcpServer::newConnection, this, [this] {
      while (auto socket = server.nextPendingConnection()) {
        auto buffer = std::make_shared<QByteArray>();
        connect(socket, &QTcpSocket::readyRead, socket, [this, socket, buffer] {
          *buffer += socket->readAll();
          int split = buffer->indexOf("\r\n\r\n");
          if (split < 0)
            return;
          auto headers = buffer->left(split);
          int length = 0;
          for (auto line : headers.split('\n'))
            if (line.toLower().startsWith("content-length:"))
              length = line.split(':').last().trimmed().toInt();
          if (buffer->size() < split + 4 + length)
            return;
          auto path = QString::fromUtf8(headers.split(' ').value(1));
          paths << path;
          QJsonObject body;
          int status = 200;
          if (path == "/v1/calls" && headers.startsWith("POST ")) {
            invitations.append(
                QJsonDocument::fromJson(buffer->mid(split + 4, length))
                    .object());
            body = {
                {"call", QJsonObject{{"id", "invitation"},
                                     {"status", "pending"},
                                     {"room", QJsonObject{{"id", "room"}}}}}};
          } else if (path == "/v1/login")
            body = {{"token", "test-session"},
                    {"user", QJsonObject{{"id", "self"}, {"name", "Me"}}}};
          else if (path == "/v1/users")
            body = {{"users",
                     QJsonArray{QJsonObject{
                         {"id", "peer"}, {"name", "Peer"}, {"online", true}}}}};
          else if (path == "/v1/calls")
            body = {{"calls", calls}};
          else if (path == "/v1/active-calls")
            body = {{"calls", QJsonArray{}}};
          else if (path == "/v1/join-requests")
            body = {{"requests", requests}};
          else if (path == "/v1/rooms/room/join-requests")
            body = {{"request",
                     QJsonObject{{"id", "approval"},
                                 {"status", "accepted"},
                                 {"requester", QJsonObject{{"id", "self"}}},
                                 {"room", QJsonObject{{"id", "room"}}}}}};
          else if (path.endsWith("/join"))
            body = {{"url", "ws://127.0.0.1:7880"},
                    {"token", "media-token"},
                    {"participantIdentity", "self"}};
          else if (path == "/v1/rooms/room/heartbeat" && failHeartbeat) {
            status = 403;
            body = {{"error", "admission expired"}};
          } else
            body = {{"ok", true}};
          auto bytes = QJsonDocument(body).toJson(QJsonDocument::Compact);
          socket->write("HTTP/1.1 " + QByteArray::number(status) +
                        " OK\r\nContent-Type: application/json\r\nConnection: "
                        "close\r\nContent-Length: " +
                        QByteArray::number(bytes.size()) + "\r\n\r\n" + bytes);
          socket->disconnectFromHost();
        });
        connect(socket, &QTcpSocket::disconnected, socket,
                &QObject::deleteLater);
      }
    });
  }
  QString url() const {
    return "http://127.0.0.1:" + QString::number(server.serverPort());
  }
};
class CoreTests : public QObject {
  Q_OBJECT
private slots:
  void sharedSwiftFixtures() {
    QFile control(QString(PAIRWISE_FIXTURES_DIR) + "/control-v1.json");
    QVERIFY(control.open(QIODevice::ReadOnly));
    auto p = QJsonDocument::fromJson(control.readAll()).object();
    QVERIFY(validControl(p));
    QCOMPARE(qtKey(p["code"].toInt()).value(), int(Qt::Key_C));
    QCOMPARE(p["modifiers"].toInteger(), qint64(1 << 20));
    QFile clipboard(QString(PAIRWISE_FIXTURES_DIR) + "/clipboard-v1.json");
    QVERIFY(clipboard.open(QIODevice::ReadOnly));
    auto part = QJsonDocument::fromJson(clipboard.readAll()).object();
    ClipboardAssembler assembler;
    auto now = QDateTime::fromMSecsSinceEpoch(
        qint64((part["createdAt"].toDouble() + 978307200.0) * 1000));
    auto text = assembler.add(part, "macos", "recipient", now);
    QVERIFY(text);
    QCOMPARE(*text,
             QString::fromUtf8("Pairwise Windows ↔ macOS 🙂\nsecond line"));
  }
  void serverValidation() {
    QVERIFY(serverUrl(" https://team.example/ "));
    QVERIFY(serverUrl("http://127.0.0.1:18080"));
    QVERIFY(serverUrl("http://[::1]:18080"));
    for (auto bad :
         {"http://team.example", "https://user:password@team.example",
          "https://team.example/path", "https://team.example/?secret=x",
          "https://team.example/#x", "file:///etc/passwd", "https://"})
      QVERIFY2(!serverUrl(bad), bad);
    QVERIFY(!mediaUrlAllowed(QUrl("ws://public.example"),
                             QUrl("https://team.example")));
    QVERIFY(!mediaUrlAllowed(QUrl("ws://public.example"),
                             QUrl("http://127.0.0.1")));
    QVERIFY(mediaUrlAllowed(QUrl("wss://media.example"),
                            QUrl("https://team.example")));
  }
  void keyboardAndGeometry() {
    QCOMPARE(macKey(Qt::Key_C).value(), 8);
    QCOMPARE(macKey(Qt::Key_V).value(), 9);
    QCOMPARE(macKey(Qt::Key_Left).value(), 123);
    QCOMPARE(qtKey(0).value(), int(Qt::Key_A));
    QVERIFY(!macKey(Qt::Key_VolumeUp));
    QVERIFY(!qtKey(128));
    QCOMPARE(macModifiers(Qt::ControlModifier | Qt::ShiftModifier),
             quint64((1 << 20) | (1 << 17)));
    QVERIFY(!normalizedPoint({10, 10}, {1920, 1080}, {1000, 1000}));
    auto p = normalizedPoint({500, 500}, {1920, 1080}, {1000, 1000});
    QVERIFY(p);
    QCOMPARE(p->x(), 0.5);
    QCOMPARE(p->y(), 0.5);
    QVERIFY(!normalizedPoint({1, 1}, {}, {100, 100}));
  }
  void callTimestamps() {
    auto d = callDuration({{"startedAt", "2026-10-30T12:00:00.123456789Z"},
                           {"endedAt", "2026-10-30T12:01:15.123456789Z"}});
    QVERIFY(d);
    QCOMPARE(*d, 75);
    QVERIFY(!callDuration({{"createdAt", "2026-10-30T12:00:00Z"},
                           {"endedAt", "2026-10-30T12:01:00Z"}}));
    QVERIFY(!callDuration({{"startedAt", "2026-10-30T12:02:00Z"},
                           {"endedAt", "2026-10-30T12:01:00Z"}}));
  }
  void consentLeaseAndReplay() {
    ControlGate gate;
    auto key = message("key", "epoch", 1);
    key["code"] = 0;
    key["down"] = true;
    key["modifiers"] = 0;
    QVERIFY(!gate.accept(key, "peer", 0));
    gate.grant("peer", "epoch", 0);
    QVERIFY(!gate.accept(key, "attacker", 1));
    QVERIFY(gate.accept(key, "peer", 1));
    QVERIFY(!gate.accept(key, "peer", 2));
    auto pointer = message("pointer", "epoch", 10);
    pointer["x"] = 0.3;
    pointer["y"] = 0.5;
    QVERIFY(gate.accept(pointer, "peer", 2));
    key["sequence"] = 2;
    QVERIFY(gate.accept(key, "peer", 3));
    pointer["sequence"] = 9;
    QVERIFY(!gate.accept(pointer, "peer", 4));
    auto heartbeat = message("heartbeat", "epoch", 3);
    heartbeat["leaseMilliseconds"] = 2000;
    QVERIFY(gate.accept(heartbeat, "peer", 1000));
    QVERIFY(gate.active(2999));
    QVERIFY(!gate.active(3000));
    key["sequence"] = 4;
    QVERIFY(!gate.accept(key, "peer", 3000));
    gate.grant("peer", "fresh", 3000);
    QVERIFY(!gate.accept(key, "peer", 3001));
    gate.revoke();
    QVERIFY(!gate.active(3001));
  }
  void malformedInput() {
    auto p = message("button", "epoch", 1);
    p["x"] = 0.5;
    p["y"] = 0.5;
    p["code"] = 0;
    p["down"] = true;
    QVERIFY(validControl(p));
    p["x"] = 2;
    QVERIFY(!validControl(p));
    p["x"] = 0.5;
    p["code"] = -1;
    QVERIFY(!validControl(p));
    auto key = message("key", "epoch", 2);
    key["code"] = 0;
    key["down"] = true;
    key["modifiers"] = 1;
    QVERIFY(!validControl(key));
    key["modifiers"] = 0;
    QVERIFY(validControl(key));
    key["sequence"] = -1;
    QVERIFY(!validControl(key));
    key["sequence"] = 1.5;
    QVERIFY(!validControl(key));
  }
  void clipboardInterop() {
    QString text =
        QString(8000, 'x') + QString::fromUtf8("🙂é") + QString(8000, QChar(1));
    auto now = QDateTime::fromString("2026-10-30T00:00:00Z", Qt::ISODate);
    auto parts = clipboardParts(text, "local",
                                "00112233-4455-6677-8899-aabbccddeeff", now);
    QVERIFY(parts.size() > 1);
    ClipboardAssembler assembler;
    std::optional<QString> complete;
    for (auto i = parts.rbegin(); i != parts.rend(); ++i) {
      auto envelope = message("clipboardPaste", "epoch", 1);
      envelope["clipboard"] = *i;
      QVERIFY(QJsonDocument(envelope).toJson(QJsonDocument::Compact).size() <=
              MaximumWireBytes);
      auto result = assembler.add(*i, "peer", "local", now);
      if (result)
        complete = result;
    }
    QVERIFY(complete);
    QCOMPARE(*complete, text);
    QVERIFY(!assembler.add(parts.first(), "peer", "local", now));
    QCOMPARE(parts.first()["createdAt"].toDouble(),
             now.toMSecsSinceEpoch() / 1000.0 - 978307200.0);
    QVERIFY(clipboardParts(QString(65537, 'a'), "local",
                           "00112233-4455-6677-8899-aabbccddeeff")
                .isEmpty());
  }
  void clipboardRejection() {
    auto now = QDateTime::currentDateTimeUtc();
    auto p = clipboardParts("test", "local",
                            "00112233-4455-6677-8899-aabbccddeeff", now)
                 .first();
    ClipboardAssembler a;
    QVERIFY(!a.add(p, "peer", "other", now));
    QVERIFY(!a.add(p, "local", "local", now));
    QVERIFY(!a.add(p, "peer", "local", now.addSecs(121)));
    p["parts"] = 999;
    QVERIFY(!a.add(p, "peer", "local", now));
  }
  void apiAndAdmissionLifecycle() {
    FakeApi fake;
    CallSession session;
    QSignalSpy media(&session, &CallSession::connectMedia);
    QSignalSpy stop(&session, &CallSession::disconnectMedia);
    session.login(fake.url(), "me@example.com", "password");
    QTRY_VERIFY(session.signedIn);
    QTRY_VERIFY(fake.paths.contains("/v1/join-requests"));
    session.joinRoom("room");
    QTRY_COMPARE(media.count(), 1);
    QCOMPARE(session.roomId, QString("room"));
    session.mediaConnected();
    fake.failHeartbeat = true;
    session.poll();
    QTRY_VERIFY(session.roomId.isEmpty());
    QVERIFY(stop.count() > 0);
    session.logout();
    QVERIFY(!session.signedIn);
    QVERIFY(session.user.isEmpty());
  }
  void directCallInvitesStayInCurrentRoomAndCanCancel() {
    FakeApi fake;
    CallSession session;
    QSignalSpy media(&session, &CallSession::connectMedia);
    QSignalSpy errors(&session, &CallSession::error);
    session.login(fake.url(), "me@example.com", "password");
    QTRY_VERIFY(session.signedIn);
    session.call("peer");
    QTRY_COMPARE(media.count(), 1);
    QCOMPARE(session.roomId, QString("room"));
    QVERIFY(!fake.invitations.first().contains("roomId"));
    session.mediaConnected();
    session.call("second");
    QTRY_COMPARE(fake.invitations.size(), 2);
    QTRY_VERIFY(!session.busy);
    QCOMPARE(fake.invitations.last()["roomId"].toString(), QString("room"));
    QCOMPARE(media.count(), 1);
    session.answer("unrelated-call", true);
    QCOMPARE(errors.count(), 1);
    QVERIFY(!fake.paths.contains("/v1/calls/unrelated-call/accept"));
    session.cancelCall("invitation");
    QTRY_VERIFY(fake.paths.contains("/v1/calls/invitation/cancel"));
    session.leave();
    QTRY_VERIFY(fake.paths.contains("/v1/rooms/room/leave"));
  }
  void approvalBeforeFirstPollAndNoHistoryReconnect() {
    FakeApi fake;
    CallSession session;
    QSignalSpy media(&session, &CallSession::connectMedia);
    fake.requests = {QJsonObject{{"id", "old"},
                                 {"status", "accepted"},
                                 {"requester", QJsonObject{{"id", "self"}}},
                                 {"room", QJsonObject{{"id", "room"}}}}};
    session.login(fake.url(), "me@example.com", "password");
    QTRY_VERIFY(session.signedIn);
    QTRY_VERIFY(fake.paths.contains("/v1/join-requests"));
    QCOMPARE(media.count(), 0);
    session.requestJoin("room");
    QTRY_COMPARE(media.count(), 1);
    session.leave();
    session.poll();
    QTest::qWait(100);
    QCOMPARE(media.count(), 1);
  }
  void logoutWhileJoining() {
    FakeApi fake;
    CallSession session;
    QSignalSpy media(&session, &CallSession::connectMedia);
    session.login(fake.url(), "me@example.com", "password");
    QTRY_VERIFY(session.signedIn);
    session.joinRoom("room");
    session.logout();
    QTest::qWait(100);
    QVERIFY(!session.signedIn);
    QVERIFY(session.roomId.isEmpty());
    QCOMPARE(media.count(), 0);
  }
};
QTEST_GUILESS_MAIN(CoreTests)
#include "CoreTests.moc"
