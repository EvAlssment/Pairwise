#include "VideoCanvas.h"
#include <QApplication>
#include <QKeyEvent>
#include <QPushButton>
#include <QSignalSpy>
#include <QVBoxLayout>
#include <QtTest>

using namespace pairwise;
class VideoCanvasTests : public QObject {
  Q_OBJECT
  static void key(VideoCanvas &canvas, QEvent::Type type, int code,
                  Qt::KeyboardModifiers modifiers = Qt::NoModifier,
                  bool repeat = false) {
    QKeyEvent event(type, code, modifiers, {}, repeat);
    QApplication::sendEvent(&canvas, &event);
  }
private slots:
  void tabAndShiftTabStayInTheRemoteScreen() {
    QWidget window;
    auto layout = new QVBoxLayout(&window);
    VideoCanvas canvas(&window);
    QPushButton next("Local button", &window);
    layout->addWidget(&canvas);
    layout->addWidget(&next);
    canvas.setControlling(true);
    window.show();
    canvas.setFocus();
    QTRY_VERIFY(canvas.hasFocus());
    QSignalSpy input(&canvas, &VideoCanvas::input);
    QSignalSpy released(&canvas, &VideoCanvas::unfocused);
    key(canvas, QEvent::KeyPress, Qt::Key_Tab);
    key(canvas, QEvent::KeyRelease, Qt::Key_Tab);
    key(canvas, QEvent::KeyPress, Qt::Key_Backtab, Qt::ShiftModifier);
    key(canvas, QEvent::KeyRelease, Qt::Key_Backtab, Qt::ShiftModifier);
    QCOMPARE(input.count(), 4);
    for (int i = 0; i < input.count(); ++i) {
      const auto packet = input[i][0].toJsonObject();
      QCOMPARE(packet["kind"].toString(), QString("key"));
      QCOMPARE(packet["code"].toInt(), 48);
      QCOMPARE(packet["down"].toBool(), i % 2 == 0);
      QCOMPARE(packet["modifiers"].toInteger(), i < 2 ? 0 : (1 << 17));
    }
    QVERIFY(canvas.hasFocus());
    QCOMPARE(released.count(), 0);
  }
  void repeatedTypingKeepsTheKeyHeldUntilPhysicalRelease() {
    VideoCanvas canvas;
    canvas.setControlling(true);
    QSignalSpy input(&canvas, &VideoCanvas::input);
    key(canvas, QEvent::KeyPress, Qt::Key_A);
    key(canvas, QEvent::KeyRelease, Qt::Key_A, Qt::NoModifier, true);
    key(canvas, QEvent::KeyPress, Qt::Key_A, Qt::NoModifier, true);
    key(canvas, QEvent::KeyRelease, Qt::Key_A);
    QCOMPARE(input.count(), 3);
    QCOMPARE(input[0][0].toJsonObject()["down"].toBool(), true);
    QCOMPARE(input[1][0].toJsonObject()["down"].toBool(), true);
    QCOMPARE(input[2][0].toJsonObject()["down"].toBool(), false);
  }
  void sameDisplayNamesKeepIndependentCursorPositionsAndRemoval() {
    VideoCanvas canvas;
    canvas.resize(320, 200);
    QImage frame(320, 200, QImage::Format_RGB32);
    frame.fill(Qt::black);
    canvas.setFrame(frame);
    canvas.setPointer("first", {.25, .5}, true, "Same name");
    canvas.setPointer("second", {.75, .5}, true, "Same name");
    auto snapshot = [&] {
      QImage image(canvas.size(), QImage::Format_ARGB32);
      image.fill(Qt::transparent);
      canvas.render(&image);
      return image;
    };
    auto image = snapshot();
    QCOMPARE(image.pixelColor(QPoint(80, 100)), QColor("#6495ff"));
    QCOMPARE(image.pixelColor(QPoint(240, 100)), QColor("#6495ff"));
    canvas.setPointer("first", {}, false, "Same name");
    image = snapshot();
    QCOMPARE(image.pixelColor(QPoint(80, 100)), QColor(Qt::black));
    QCOMPARE(image.pixelColor(QPoint(240, 100)), QColor("#6495ff"));
  }
  void heldClipboardShortcutDoesNotRepeatTransfers() {
    VideoCanvas canvas;
    canvas.setControlling(true);
    QSignalSpy input(&canvas, &VideoCanvas::input);
    for (auto code : {Qt::Key_C, Qt::Key_V}) {
      key(canvas, QEvent::KeyPress, code, Qt::ControlModifier);
      key(canvas, QEvent::KeyPress, code, Qt::ControlModifier, true);
      key(canvas, QEvent::KeyRelease, code, Qt::ControlModifier);
    }
    QCOMPARE(input.count(), 2);
    QCOMPARE(input[0][0].toJsonObject()["kind"].toString(),
             QString("clipboardCopy"));
    QCOMPARE(input[1][0].toJsonObject()["kind"].toString(),
             QString("clipboardPaste"));
  }
  void escapeReleasesInsteadOfForwardingAndViewingSendsNoKeys() {
    VideoCanvas canvas;
    canvas.setControlling(true);
    QSignalSpy input(&canvas, &VideoCanvas::input);
    QSignalSpy released(&canvas, &VideoCanvas::unfocused);
    key(canvas, QEvent::KeyPress, Qt::Key_Escape);
    key(canvas, QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier, true);
    QCOMPARE(released.count(), 1);
    QCOMPARE(input.count(), 0);
    canvas.setControlling(false);
    key(canvas, QEvent::KeyPress, Qt::Key_A);
    key(canvas, QEvent::KeyRelease, Qt::Key_A);
    QCOMPARE(input.count(), 0);
  }
};
QTEST_MAIN(VideoCanvasTests)
#include "VideoCanvasTests.moc"
