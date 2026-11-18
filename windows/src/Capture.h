#pragma once
#include <QCamera>
#include <QElapsedTimer>
#include <QMediaCaptureSession>
#include <QObject>
#include <QPointer>
#include <QScreenCapture>
#include <QVideoSink>
#include <QWidget>
#include <QWindowCapture>
namespace pairwise {
class Capture : public QObject {
  Q_OBJECT
public:
  explicit Capture(QObject *parent = nullptr);
  ~Capture() override;
  void startCamera(const QCameraDevice &device, bool previewOnly = false);
  void stopCamera();
  bool shareScreen(QScreen *screen);
  bool shareWindow(const QCapturableWindow &window);
  void stopShare();
  bool cameraActive() const { return camera && camera->isActive(); }
  bool sharing() const { return shareRequested; }
  bool windowSharing() const { return shareRequested && windowRequested; }
  QRect controlBounds() const { return physicalBounds; }
signals:
  void frame(bool screen, const QImage &image);
  void preview(const QImage &image);
  void changed();
  void stoppedSharing();
  void error(const QString &text);

private:
  void receive(bool share, const QVideoFrame &frame);
  QMediaCaptureSession cameraSession, shareSession;
  std::unique_ptr<QCamera> camera;
  QScreenCapture screen;
  QWindowCapture window;
  QVideoSink cameraSink, shareSink;
  QElapsedTimer cameraClock, shareClock;
  QPointer<QScreen> selectedScreen;
  std::unique_ptr<QWidget> border;
  QRect physicalBounds;
  bool previewOnly = false, stopping = false, shareRequested = false,
       windowRequested = false;
  quint64 cameraGeneration = 0;
};
} // namespace pairwise
