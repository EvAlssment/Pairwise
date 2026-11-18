#include "Platform.h"
#include "Protocol.h"
#include <QApplication>
#include <QClipboard>
#include <QLineEdit>
#include <QUuid>
#include <QtTest>
#include <windows.h>

using namespace pairwise;
class WindowsPlatformTests : public QObject {
  Q_OBJECT
private slots:
  void credentialManagerRoundTripAndRemoval() {
    const auto server =
        "https://pairwise-test.invalid/" + QUuid::createUuid().toString();
    struct Cleanup {
      QString server;
      ~Cleanup() { deleteToken(server); }
    } cleanup{server};
    QVERIFY(loadToken(server).isEmpty());
    QVERIFY(saveToken(server, "synthetic-test-session"));
    QCOMPARE(loadToken(server), QString("synthetic-test-session"));
    QVERIFY(saveToken(server, "replacement-test-session"));
    QCOMPARE(loadToken(server), QString("replacement-test-session"));
    deleteToken(server);
    QVERIFY(loadToken(server).isEmpty());
  }
  void win32KeyboardTranslationAndCleanup() {
    InputInjector injector;
    if (!injector.desktopAvailable())
      QSKIP("No default interactive Windows desktop; physical acceptance "
            "remains required.");
    QLineEdit destination;
    destination.resize(400, 60);
    destination.show();
    destination.raise();
    destination.activateWindow();
    destination.setFocus();
    if (!QTest::qWaitForWindowActive(&destination, 3000))
      QSKIP("Runner cannot activate the isolated input test window.");
    const auto target = reinterpret_cast<HWND>(destination.winId());
    if (GetForegroundWindow() != target)
      QSKIP("Input test window does not own foreground; no input will be "
            "injected.");
    struct Cleanup {
      InputInjector &injector;
      ~Cleanup() { injector.releaseAll(); }
    } cleanup{injector};
    ControlGate gate;
    gate.grant("peer", "consent", 0);
    auto down = message("key", "consent", 1);
    down["code"] = 0;
    down["down"] = true;
    down["modifiers"] = 1 << 17;
    QVERIFY(gate.accept(down, "peer", 1));
    QVERIFY(injector.inject(down, {}));
    auto up = down;
    up["sequence"] = 2;
    up["down"] = false;
    QVERIFY(gate.accept(up, "peer", 2));
    QVERIFY(injector.inject(up, {}));
    gate.revoke();
    injector.releaseAll();
    QTRY_COMPARE(destination.text(), QString("A"));
    QVERIFY(!(GetAsyncKeyState(VK_SHIFT) & 0x8000));
    QVERIFY(!(GetAsyncKeyState('A') & 0x8000));
    QVERIFY(!gate.accept(down, "peer", 3));
  }
  void win32ClipboardCopyAndPasteInOwnedWindow() {
    if (qgetenv("GITHUB_ACTIONS") != "true" ||
        qgetenv("RUNNER_ENVIRONMENT") != "github-hosted")
      QSKIP("Synthetic OS clipboard tests run only on disposable hosted CI; "
            "they never inspect or overwrite a user's clipboard.");
    InputInjector injector;
    if (!injector.desktopAvailable())
      QSKIP("No interactive Windows desktop available for clipboard dispatch.");
    QLineEdit destination;
    destination.resize(500, 60);
    destination.show();
    destination.raise();
    destination.activateWindow();
    destination.setFocus();
    QVERIFY(QTest::qWaitForWindowActive(&destination, 3000));
    const auto target = reinterpret_cast<HWND>(destination.winId());
    QVERIFY(GetForegroundWindow() == target);
    auto clipboard = QApplication::clipboard();
    struct Cleanup {
      InputInjector &injector;
      QClipboard *clipboard;
      ~Cleanup() {
        injector.releaseAll();
        clipboard->clear();
      }
    } cleanup{injector, clipboard};
    clipboard->clear();
    const auto copied = QStringLiteral("Windows copy · 你好");
    destination.setText(copied);
    destination.selectAll();
    QVERIFY(injector.shortcut(false));
    QTRY_COMPARE(clipboard->text(), copied);
    const auto pasted = QStringLiteral("Windows paste · नमस्ते");
    clipboard->setText(pasted);
    destination.selectAll();
    QVERIFY(GetForegroundWindow() == target);
    QVERIFY(injector.shortcut(true));
    QTRY_COMPARE(destination.text(), pasted);
    QVERIFY(!(GetAsyncKeyState(VK_CONTROL) & 0x8000));
    QVERIFY(!(GetAsyncKeyState('C') & 0x8000));
    QVERIFY(!(GetAsyncKeyState('V') & 0x8000));
  }
};
QTEST_MAIN(WindowsPlatformTests)
#include "WindowsPlatformTests.moc"
