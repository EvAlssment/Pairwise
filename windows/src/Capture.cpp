#include "Capture.h"
#include "Platform.h"
#include <QCameraDevice>
#include <QScreen>
#include <QVideoFrame>

namespace pairwise {
Capture::Capture(QObject *parent) : QObject(parent) {
  cameraSession.setVideoSink(&cameraSink);
  shareSession.setVideoSink(&shareSink);
  connect(&cameraSink, &QVideoSink::videoFrameChanged, this,
          [this](const QVideoFrame &f) { receive(false, f); });
  connect(&shareSink, &QVideoSink::videoFrameChanged, this,
          [this](const QVideoFrame &f) { receive(true, f); });
  auto failed = [this](auto, const QString &text) {
    stopShare();
    emit error("Capture stopped: " + text);
  };
  connect(&screen, &QScreenCapture::errorOccurred, this, failed);
  connect(&window, &QWindowCapture::errorOccurred, this, failed);
  connect(&screen, &QScreenCapture::activeChanged, this, [this](bool active) {
    if (!active && !stopping && selectedScreen)
      stopShare();
    emit changed();
  });
  connect(&window, &QWindowCapture::activeChanged, this, [this](bool active) {
    if (!active && !stopping)
      stopShare();
    emit changed();
  });
  cameraClock.start();
  shareClock.start();
}
Capture::~Capture() {
  stopCamera();
  stopShare();
}
void Capture::startCamera(const QCameraDevice &device, bool preview) {
  stopCamera();
  if (device.isNull()) {
    emit error("No camera is available.");
    return;
  }
  previewOnly = preview;
  camera = std::make_unique<QCamera>(device);
  const auto current = cameraGeneration;
  connect(
      camera.get(), &QCamera::errorOccurred, this,
      [this, current](auto, const QString &text) {
        if (current != cameraGeneration)
          return;
        stopCamera();
        emit error("Camera stopped: " + text);
      },
      Qt::QueuedConnection);
  connect(camera.get(), &QCamera::activeChanged, this,
          [this] { emit changed(); });
  cameraSession.setCamera(camera.get());
  camera->start();
  emit changed();
}
void Capture::stopCamera() {
  ++cameraGeneration;
  if (camera) {
    camera->stop();
    cameraSession.setCamera(nullptr);
    camera.reset();
  }
  emit changed();
}
bool Capture::shareScreen(QScreen *target) {
  stopShare();
  if (!target)
    return false;
  auto bounds = physicalDisplayRect(target->name());
  if (!bounds) {
    emit error("This display cannot be mapped safely for Windows sharing. "
               "Choose a window instead.");
    return false;
  }
  physicalBounds = *bounds;
  selectedScreen = target;
  border = std::make_unique<QWidget>(
      nullptr, Qt::Tool | Qt::FramelessWindowHint | Qt::WindowStaysOnTopHint |
                   Qt::WindowTransparentForInput |
                   Qt::WindowDoesNotAcceptFocus);
  border->setAttribute(Qt::WA_TranslucentBackground);
  border->setAttribute(Qt::WA_StyledBackground);
  border->setAttribute(Qt::WA_ShowWithoutActivating);
  border->setStyleSheet("background: transparent; border: 3px solid #4e8cff;");
  border->setGeometry(target->geometry());
  border->show();
  if (!excludeFromCapture(border.get())) {
    stopShare();
    emit error("Windows could not exclude the sharing indicator from capture.");
    return false;
  }
  connect(
      target, &QScreen::geometryChanged, this,
      [this] {
        stopShare();
        emit error("Display layout changed. Choose the display again.");
      },
      Qt::SingleShotConnection);
  connect(
      target, &QObject::destroyed, this, [this] { stopShare(); },
      Qt::SingleShotConnection);
  shareSession.setWindowCapture(nullptr);
  shareSession.setScreenCapture(&screen);
  screen.setScreen(target);
  shareRequested = true;
  windowRequested = false;
  screen.start();
  emit changed();
  return shareRequested;
}
bool Capture::shareWindow(const QCapturableWindow &target) {
  stopShare();
  if (!target.isValid()) {
    emit error("The selected window is no longer available. Choose it again.");
    return false;
  }
  shareSession.setScreenCapture(nullptr);
  shareSession.setWindowCapture(&window);
  window.setWindow(target);
  shareRequested = true;
  windowRequested = true;
  window.start();
  emit changed();
  return shareRequested;
}
void Capture::stopShare() {
  if (stopping)
    return;
  stopping = true;
  bool was = shareRequested || screen.isActive() || window.isActive() ||
             selectedScreen;
  shareRequested = false;
  windowRequested = false;
  if (selectedScreen)
    disconnect(selectedScreen, nullptr, this, nullptr);
  screen.stop();
  window.stop();
  selectedScreen = nullptr;
  physicalBounds = {};
  border.reset();
  stopping = false;
  if (was)
    emit stoppedSharing();
  emit changed();
}
void Capture::receive(bool share, const QVideoFrame &f) {
  auto &clock = share ? shareClock : cameraClock;
  if (clock.elapsed() < 33)
    return;
  clock.restart();
  if (share && !sharing())
    return;
  if (!share && !cameraActive())
    return;
  auto image = f.toImage();
  if (image.isNull())
    return;
  const QSize max = share ? QSize(1920, 1080) : QSize(1280, 720);
  if (image.width() > max.width() || image.height() > max.height())
    image = image.scaled(max, Qt::KeepAspectRatio, Qt::FastTransformation);
  if (!share)
    emit preview(image);
  if (share || !previewOnly)
    emit frame(share, image);
}
} // namespace pairwise
