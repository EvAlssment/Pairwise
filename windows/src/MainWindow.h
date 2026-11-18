#pragma once
#include "CallSession.h"
#include "Capture.h"
#include "Collaboration.h"
#include "Media.h"
#include "VideoCanvas.h"
#include <QAbstractNativeEventFilter>
#include <QMainWindow>
#include <QSettings>
#include <QSystemTrayIcon>
class QLabel;
class QLineEdit;
class QListWidget;
class QPushButton;
class QStackedWidget;
class QDialog;
namespace pairwise {
class MainWindow : public QMainWindow, public QAbstractNativeEventFilter {
  Q_OBJECT
public:
  MainWindow();
  ~MainWindow() override;
  bool nativeEventFilter(const QByteArray &, void *, qintptr *) override;

protected:
  void closeEvent(QCloseEvent *) override;

private:
  void refresh();
  void settings();
  void share();
  void diagnostic();
  void showError(const QString &text);
  void resetMedia();
  QString name(const QString &identity) const;
  QJsonObject selected(QListWidget *list) const;
  CallSession session;
  Media media;
  Capture capture;
  Collaboration collaboration;
  QSettings preferences;
  QSystemTrayIcon tray;
  QStackedWidget *pages;
  QLineEdit *server, *email, *password;
  QPushButton *signIn, *mic, *camera, *sharing, *control;
  QLabel *status, *notice, *controlStatus;
  QListWidget *team, *history, *requests, *active;
  VideoCanvas *canvas;
  QMap<QString, QLabel *> cameraTiles;
  QWidget *cameraRow;
  QString sharer;
  bool micEnabled = false, shuttingDown = false, stopShortcutAvailable = false;
  QSet<QString> notified;
  QMap<QString, QPointer<QDialog>> prompts;
};
} // namespace pairwise
