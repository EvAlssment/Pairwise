#include "Capture.h"
#include "Platform.h"
#include <QApplication>
#include <QImage>
#include <QProcess>
#include <QSignalSpy>
#include <QUuid>
#include <QtTest>
#include <cstdlib>

using namespace pairwise;
class CaptureTests : public QObject {
  Q_OBJECT
  QCapturableWindow ownWindow(const QString &title) {
    for (const auto &window : QWindowCapture::capturableWindows())
      if (window.description() == title)
        return window;
    return {};
  }
private slots:
  void invalidWindowDoesNotStartSharing() {
    Capture capture;
    QSignalSpy errors(&capture, &Capture::error);
    QVERIFY(!capture.shareWindow({}));
    QVERIFY(!capture.sharing());
    QVERIFY(!capture.windowSharing());
    QVERIFY(!capture.cameraActive());
    QCOMPARE(errors.size(), 1);
  }
  void nativeOwnWindowPixelsStopAndSourceClosure() {
    if (!InputInjector().desktopAvailable())
      QSKIP("Requires an interactive Windows desktop; never captures a user "
            "desktop or hardware device.");
    const auto title =
        "Pairwise synthetic capture " + QUuid::createUuid().toString();
    QProcess source;
    struct Cleanup {
      QProcess &source;
      ~Cleanup() {
        if (source.state() != QProcess::NotRunning) {
          source.kill();
          source.waitForFinished(5000);
        }
      }
    } cleanup{source};
    source.start(QCoreApplication::applicationFilePath(),
                 {"--capture-source-window", title});
    QVERIFY(source.waitForStarted(5000));
    QTRY_VERIFY_WITH_TIMEOUT(ownWindow(title).isValid(), 5000);
    Capture capture;
    QSignalSpy frames(&capture, &Capture::frame);
    QSignalSpy stopped(&capture, &Capture::stoppedSharing);
    QSignalSpy errors(&capture, &Capture::error);
    QVERIFY(capture.shareWindow(ownWindow(title)));
    QTRY_VERIFY_WITH_TIMEOUT(!frames.isEmpty() || !errors.isEmpty(), 10000);
    QVERIFY2(!frames.isEmpty(), errors.isEmpty()
                                    ? "No native capture frames"
                                    : qPrintable(errors.last()[0].toString()));
    QVERIFY(frames.last()[0].toBool());
    const auto image = qvariant_cast<QImage>(frames.last()[1]);
    QVERIFY(image.width() >= 200 && image.height() >= 100);
    const auto center = image.pixelColor(image.width() / 2, image.height() / 2);
    const auto detail =
        QString("Owned synthetic window captured as %1x%2; center=%3")
            .arg(image.width())
            .arg(image.height())
            .arg(center.name());
    QVERIFY2(std::abs(center.red() - 18) < 20, qPrintable(detail));
    QVERIFY2(std::abs(center.green() - 88) < 20, qPrintable(detail));
    QVERIFY2(std::abs(center.blue() - 160) < 20, qPrintable(detail));
    QVERIFY(capture.windowSharing());
    QVERIFY(capture.controlBounds().isEmpty()); // Window shares stay view-only.
    capture.stopShare();
    QVERIFY(!capture.sharing());
    QCOMPARE(stopped.size(), 1);
    frames.clear();
    QTest::qWait(150);
    QVERIFY(frames.isEmpty());
    QVERIFY(capture.shareWindow(ownWindow(title)));
    QTRY_VERIFY_WITH_TIMEOUT(!frames.isEmpty(), 10000);
    source.kill();
    QVERIFY(source.waitForFinished(5000));
    QTRY_VERIFY_WITH_TIMEOUT(!capture.sharing(), 10000);
    QTRY_COMPARE_WITH_TIMEOUT(stopped.size(), 2, 10000);
    frames.clear();
    QTest::qWait(150);
    QVERIFY(frames.isEmpty());
    QVERIFY(!capture.cameraActive());
  }
};
int main(int argc, char **argv) {
  QApplication app(argc, argv);
  if (app.arguments().size() == 3 &&
      app.arguments()[1] == "--capture-source-window") {
    // The only capture source is this owned child process's synthetic window.
    QWidget source;
    source.setWindowTitle(app.arguments()[2]);
    source.resize(640, 360);
    source.setStyleSheet("background-color: rgb(18, 88, 160);");
    source.show();
    return app.exec();
  }
  CaptureTests tests;
  return QTest::qExec(&tests, argc, argv);
}
#include "CaptureTests.moc"
