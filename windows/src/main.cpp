#include "MainWindow.h"
#include <QApplication>
#include <QDir>
#include <QLockFile>
#include <QMessageBox>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTimer>
#include <livekit/livekit.h>
int main(int argc, char **argv) {
  QApplication app(argc, argv);
  QApplication::setApplicationName("Pairwise");
  QApplication::setOrganizationName("Pairwise");
  QApplication::setApplicationVersion(PAIRWISE_VERSION);
  bool smoke = app.arguments().contains("--smoke-test");
  QTemporaryDir scratch;
  if (smoke) {
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope,
                       scratch.path());
  }
  const auto data = smoke ? scratch.path()
                          : QStandardPaths::writableLocation(
                                QStandardPaths::AppLocalDataLocation);
  QDir().mkpath(data);
  QLockFile lock(data + "/instance.lock");
  if (!lock.tryLock(0)) {
    QMessageBox::information(
        nullptr, "Pairwise",
        "Pairwise is already running. Open it from the system tray.");
    return 0;
  }
  // SDK debug output may contain connection details. No SDK logs are retained
  // or uploaded.
  livekit::initialize(livekit::LogLevel::Error);
  livekit::setLogCallback(
      [](livekit::LogLevel, const std::string &, const std::string &) {});
  int result;
  {
    pairwise::MainWindow window;
    window.show();
    if (smoke)
      QTimer::singleShot(1000, &app, &QApplication::quit);
    result = app.exec();
  }
  livekit::shutdown();
  return result;
}
