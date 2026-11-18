#include "MainWindow.h"
#include "Platform.h"
#include <QApplication>
#include <QCameraDevice>
#include <QCloseEvent>
#include <QComboBox>
#include <QDateTime>
#include <QDesktopServices>
#include <QDialog>
#include <QDialogButtonBox>
#include <QFile>
#include <QFileDialog>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QInputDialog>
#include <QJsonDocument>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMediaDevices>
#include <QMenu>
#include <QMessageBox>
#include <QProgressBar>
#include <QPushButton>
#include <QScreen>
#include <QStackedWidget>
#include <QStyle>
#include <QSysInfo>
#include <QTabWidget>
#include <QVBoxLayout>
#ifdef Q_OS_WIN
#include <windows.h>
#endif

namespace pairwise {
static QPushButton *button(const QString &text, QLayout *layout,
                           QObject *context, std::function<void()> action) {
  auto b = new QPushButton(text);
  layout->addWidget(b);
  QObject::connect(b, &QPushButton::clicked, context, action);
  return b;
}
static void fill(QListWidget *list,
                 const QList<QPair<QString, QJsonObject>> &rows) {
  QString id = list->currentItem() ? list->currentItem()
                                         ->data(Qt::UserRole)
                                         .toJsonObject()["id"]
                                         .toString()
                                   : QString{};
  list->clear();
  for (const auto &row : rows) {
    auto item = new QListWidgetItem(row.first, list);
    item->setData(Qt::UserRole, row.second);
    if (row.second["id"] == id)
      list->setCurrentItem(item);
  }
}
MainWindow::MainWindow()
    : collaboration(&media), preferences("Pairwise", "Windows") {
  setWindowTitle("Pairwise · Windows preview");
  resize(1120, 760);
  setMinimumSize(800, 600);
  auto root = new QWidget;
  auto layout = new QVBoxLayout(root);
  layout->setContentsMargins(20, 16, 20, 16);
  setCentralWidget(root);
  auto header = new QHBoxLayout;
  auto brand = new QLabel("Pairwise");
  brand->setStyleSheet("font-size:26px;font-weight:600;");
  header->addWidget(brand);
  header->addStretch();
  button("Settings", header, this, [this] { settings(); });
  auto signOut = button("Sign out", header, this, [this] { session.logout(); });
  signOut->hide();
  connect(&session, &CallSession::changed, signOut,
          [this, signOut] { signOut->setVisible(session.signedIn); });
  layout->addLayout(header);
  notice = new QLabel;
  notice->setWordWrap(true);
  notice->setTextFormat(Qt::PlainText);
  notice->setStyleSheet("color:#a52d38;");
  layout->addWidget(notice);
  pages = new QStackedWidget;
  layout->addWidget(pages);
  auto login = new QWidget;
  auto loginLayout = new QVBoxLayout(login);
  loginLayout->addStretch();
  auto loginRow = new QHBoxLayout;
  loginRow->addStretch();
  auto loginPanel = new QWidget;
  loginPanel->setMaximumWidth(480);
  loginPanel->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
  auto loginForm = new QVBoxLayout(loginPanel);
  auto loginTitle = new QLabel("Sign in to your team");
  loginTitle->setStyleSheet("font-size:20px;font-weight:600;");
  loginForm->addWidget(loginTitle);
  auto loginHelp = new QLabel("Use an account from your team administrator.");
  loginHelp->setWordWrap(true);
  loginForm->addWidget(loginHelp);
  loginForm->addSpacing(12);
  auto form = new QFormLayout;
  server = new QLineEdit(preferences.value("server").toString());
  server->setPlaceholderText("https://your-team-server");
  server->setAccessibleName("Team server");
  email = new QLineEdit;
  email->setPlaceholderText("you@your-team.com");
  email->setAccessibleName("Email");
  password = new QLineEdit;
  password->setEchoMode(QLineEdit::Password);
  password->setAccessibleName("Password");
  form->addRow("Team server", server);
  form->addRow("Email", email);
  form->addRow("Password", password);
  loginForm->addLayout(form);
  signIn = button("Sign in", loginForm, this, [this] {
    notice->clear();
    auto secret = password->text();
    password->clear();
    session.login(server->text(), email->text(), secret);
  });
  connect(password, &QLineEdit::returnPressed, signIn, &QPushButton::click);
  loginRow->addWidget(loginPanel, 1);
  loginRow->addStretch();
  loginLayout->addLayout(loginRow);
  loginLayout->addStretch();
  pages->addWidget(login);
  auto home = new QWidget;
  auto homeLayout = new QVBoxLayout(home);
  status = new QLabel("Ready");
  status->setTextFormat(Qt::PlainText);
  homeLayout->addWidget(status);
  auto tabs = new QTabWidget;
  team = new QListWidget;
  history = new QListWidget;
  requests = new QListWidget;
  active = new QListWidget;
  auto addTab = [&](const QString &title, QListWidget *list,
                    std::function<void(QHBoxLayout *)> actions) {
    auto page = new QWidget;
    auto column = new QVBoxLayout(page);
    column->addWidget(list);
    auto bar = new QHBoxLayout;
    actions(bar);
    column->addLayout(bar);
    tabs->addTab(page, title);
  };
  addTab("Teammates", team, [&](QHBoxLayout *bar) {
    button("Call / invite", bar, this, [this] {
      auto person = selected(team);
      if (!person.isEmpty())
        session.call(person["id"].toString());
    });
  });
  addTab("Calls", history, [&](QHBoxLayout *bar) {
    button("Accept / retry joining", bar, this, [this] {
      auto c = selected(history);
      if (c["status"] == "pending" &&
          c["target"].toObject()["id"] == session.user["id"])
        session.answer(c["id"].toString(), true);
      else if (c["status"] == "accepted")
        session.joinRoom(c["room"].toObject()["id"].toString());
    });
    button("Decline / cancel", bar, this, [this] {
      auto c = selected(history);
      if (c["status"] == "pending") {
        if (c["caller"].toObject()["id"] == session.user["id"])
          session.cancelCall(c["id"].toString());
        else
          session.answer(c["id"].toString(), false);
      }
    });
    button("Call back", bar, this, [this] {
      auto c = selected(history);
      if (c.isEmpty())
        return;
      auto person =
          c[c["caller"].toObject()["id"] == session.user["id"] ? "target"
                                                               : "caller"]
              .toObject();
      session.call(person["id"].toString());
    });
  });
  addTab("Active calls", active, [&](QHBoxLayout *bar) {
    button("Request to join", bar, this, [this] {
      auto room = selected(active);
      if (!room.isEmpty())
        session.requestJoin(room["id"].toString());
    });
  });
  addTab("Join requests", requests, [&](QHBoxLayout *bar) {
    button("Add to call", bar, this, [this] {
      auto r = selected(requests);
      if (!r.isEmpty() && r["requester"].toObject()["id"] != session.user["id"])
        session.resolveJoin(r["id"].toString(), true);
    });
    button("Decline", bar, this, [this] {
      auto r = selected(requests);
      if (!r.isEmpty())
        session.resolveJoin(r["id"].toString(), false);
    });
    button("Cancel / leave request", bar, this, [this] {
      auto r = selected(requests);
      if (!r.isEmpty())
        session.cancelRequest(r["id"].toString());
    });
    button("Retry approved join", bar, this, [this] {
      auto r = selected(requests);
      if (r["status"] == "accepted" &&
          r["requester"].toObject()["id"] == session.user["id"])
        session.joinRoom(r["room"].toObject()["id"].toString());
    });
  });
  tabs->setMaximumHeight(240);
  homeLayout->addWidget(tabs);
  auto callBar = new QHBoxLayout;
  mic = button("Turn microphone on", callBar, this,
               [this] { media.microphone(!micEnabled); });
  camera = button("Turn camera on", callBar, this, [this] {
    if (capture.cameraActive()) {
      capture.stopCamera();
      media.stopVideo(false);
    } else {
      auto devices = QMediaDevices::videoInputs();
      auto id = preferences.value("camera").toByteArray();
      QCameraDevice chosen = QMediaDevices::defaultVideoInput();
      for (const auto &d : devices)
        if (d.id() == id)
          chosen = d;
      capture.startCamera(chosen);
    }
  });
  sharing = button("Share screen / window", callBar, this, [this] { share(); });
  control = button("Request control", callBar, this, [this] {
    if (collaboration.controlling())
      collaboration.releaseControl();
    else
      collaboration.requestControl();
  });
  button("Stop all remote control", callBar, this, [this] {
    collaboration.revoke();
    collaboration.releaseControl();
  });
  button("Leave call", callBar, this, [this] { session.leave(); });
  homeLayout->addLayout(callBar);
  controlStatus = new QLabel("Remote control is off. Escape releases control. "
                             "Ctrl+Alt+Escape stops all remote input.");
  controlStatus->setWordWrap(true);
  controlStatus->setTextFormat(Qt::PlainText);
  homeLayout->addWidget(controlStatus);
  cameraRow = new QWidget;
  cameraRow->setLayout(new QHBoxLayout);
  cameraRow->setMaximumHeight(150);
  homeLayout->addWidget(cameraRow);
  canvas = new VideoCanvas;
  homeLayout->addWidget(canvas, 1);
  pages->addWidget(home);
  tray.setIcon(style()->standardIcon(QStyle::SP_ComputerIcon));
  tray.setToolTip("Pairwise");
  auto menu = new QMenu(this);
  auto reveal = [this] {
    showNormal();
    raise();
    activateWindow();
  };
  menu->addAction("Open Pairwise", this, reveal);
  menu->addAction("Stop remote control", this, [this] {
    collaboration.revoke();
    collaboration.releaseControl();
  });
  menu->addAction("Quit", this, [this] {
    shuttingDown = true;
    close();
  });
  tray.setContextMenu(menu);
  tray.show();
  connect(&tray, &QSystemTrayIcon::messageClicked, this, reveal);
  connect(&tray, &QSystemTrayIcon::activated, this,
          [reveal](QSystemTrayIcon::ActivationReason reason) {
            if (reason == QSystemTrayIcon::Trigger ||
                reason == QSystemTrayIcon::DoubleClick)
              reveal();
          });
  connect(&session, &CallSession::changed, this, &MainWindow::refresh);
  connect(&session, &CallSession::error, this, &MainWindow::showError);
  connect(&session, &CallSession::authenticated, this,
          [this](const QString &url, const QString &token) {
            preferences.setValue("server", url);
            if (!saveToken(url, token))
              showError("Signed in for this session. Windows could not "
                        "securely save sign-in.");
          });
  connect(&session, &CallSession::signedOut, this, [this] {
    deleteToken(preferences.value("server").toString());
    notified.clear();
  });
  connect(&session, &CallSession::connectMedia, this,
          [this](const QString &url, const QString &token) {
            collaboration.begin(session.user["id"].toString());
            media.join(url, token);
          });
  connect(&session, &CallSession::disconnectMedia, this,
          &MainWindow::resetMedia);
  connect(&session, &CallSession::missedCall, this,
          [this](const QString &person) {
            tray.showMessage("Missed call", person + " tried to call you.");
          });
  connect(&media, &Media::connected, this, [this] {
    session.mediaConnected();
    media.refreshParticipants();
    media.devices(preferences.value("microphone").toString(),
                  preferences.value("speaker").toString());
  });
  connect(&media, &Media::disconnected, this, [this] {
    if (!session.roomId.isEmpty()) {
      session.leave();
      showError("Media disconnected. Use Calls to retry joining if admission "
                "is still available.");
    }
  });
  connect(&media, &Media::reconnecting, this, [this] {
    capture.stopShare();
    collaboration.end();
    status->setText("Reconnecting · remote control stopped");
  });
  connect(&media, &Media::reconnected, this, [this] {
    collaboration.begin(session.user["id"].toString());
    media.refreshParticipants();
    session.mediaConnected();
  });
  connect(&media, &Media::error, this, &MainWindow::showError);
  connect(&media, &Media::microphoneChanged, this, [this](bool enabled) {
    micEnabled = enabled;
    refresh();
  });
  connect(&capture, &Capture::frame, &media, &Media::video);
  connect(&capture, &Capture::error, this, &MainWindow::showError);
  connect(&capture, &Capture::changed, this, &MainWindow::refresh);
  connect(&capture, &Capture::stoppedSharing, this, [this] {
    media.stopVideo(true);
    collaboration.sharing(false);
    session.share(false, [](bool) {});
  });
  connect(&media, &Media::trackGone, this,
          [this](const QString &id, const QString &track, bool screen) {
            if (id.isEmpty()) {
              if (screen)
                capture.stopShare();
              else
                capture.stopCamera();
              return;
            }
            if (screen && id == sharer) {
              sharer.clear();
              canvas->clear();
              collaboration.view({});
            }
            auto key = id + "/" + track;
            if (cameraTiles.contains(key)) {
              delete cameraTiles.take(key);
            }
            refresh();
          });
  connect(&media, &Media::frame, this,
          [this](const QString &id, const QString &track, bool screen,
                 const QImage &image) {
            if (screen) {
              sharer = id;
              collaboration.view(id);
              canvas->setFrame(image);
            } else {
              auto key = id + "/" + track;
              auto tile = cameraTiles.value(key);
              if (!tile) {
                tile = new QLabel;
                tile->setMinimumSize(100, 100);
                tile->setAccessibleName(name(id) + " camera");
                cameraTiles[key] = tile;
                cameraRow->layout()->addWidget(tile);
              }
              tile->setPixmap(QPixmap::fromImage(image).scaled(
                  180, 130, Qt::KeepAspectRatio, Qt::FastTransformation));
            }
          });
  connect(&collaboration, &Collaboration::changed, this, [this] {
    canvas->setControlling(collaboration.controlling());
    refresh();
  });
  connect(&collaboration, &Collaboration::error, this, &MainWindow::showError);
  connect(&collaboration, &Collaboration::pointer, this,
          [this](const QString &id, const QPointF &p, bool visible) {
            canvas->setPointer(id, p, visible, name(id));
          });
  connect(canvas, &VideoCanvas::input, &collaboration, &Collaboration::input);
  connect(canvas, &VideoCanvas::cursor, &collaboration, &Collaboration::cursor);
  connect(canvas, &VideoCanvas::unfocused, &collaboration,
          &Collaboration::releaseControl);
  connect(
      &collaboration, &Collaboration::controlRequested, this,
      [this](const QString &id) {
        if (!stopShortcutAvailable) {
          collaboration.deny(id);
          showError("Windows could not reserve Ctrl+Alt+Escape. Remote input "
                    "hosting is disabled until the shortcut is available and "
                    "Pairwise is restarted.");
          return;
        }
        auto prompt = new QMessageBox(
            QMessageBox::Question, "Remote control request",
            name(id) + " wants to control your shared display. Allow mouse, "
                       "keyboard, and plain-text copy/paste for this call?",
            QMessageBox::Yes | QMessageBox::No, this);
        prompt->setTextFormat(Qt::PlainText);
        prompt->setDefaultButton(QMessageBox::No);
        prompt->setAttribute(Qt::WA_DeleteOnClose);
        connect(&collaboration, &Collaboration::changed, prompt,
                [this, id, prompt] {
                  if (!collaboration.awaitingConsent(id))
                    prompt->reject();
                });
        connect(prompt, &QMessageBox::finished, this,
                [this, id, prompt](int result) {
                  // A grant revokes other pending requests and emits changed.
                  // Detach first so closing this dialog cannot reenter its
                  // finished handler.
                  disconnect(&collaboration, nullptr, prompt, nullptr);
                  if (result == QMessageBox::Yes)
                    collaboration.grant(id);
                  else
                    collaboration.deny(id);
                });
        prompt->open();
      });
  qApp->installNativeEventFilter(this);
#ifdef Q_OS_WIN
  stopShortcutAvailable =
      RegisterHotKey(reinterpret_cast<HWND>(winId()), 0x5041,
                     MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, VK_ESCAPE);
#endif
  refresh();
  const auto savedServer = preferences.value("server").toString();
  const auto token = loadToken(savedServer);
  if (!token.isEmpty())
    session.restore(savedServer, token);
}
MainWindow::~MainWindow() {
  // Member destructors stop capture and emit state changes after later members
  // (including the prompt map) have already been destroyed.
  disconnect(&session, nullptr, this, nullptr);
  disconnect(&media, nullptr, this, nullptr);
  disconnect(&capture, nullptr, this, nullptr);
  disconnect(&collaboration, nullptr, this, nullptr);
  qApp->removeNativeEventFilter(this);
#ifdef Q_OS_WIN
  if (stopShortcutAvailable)
    UnregisterHotKey(reinterpret_cast<HWND>(winId()), 0x5041);
#endif
  resetMedia();
}
bool MainWindow::nativeEventFilter(const QByteArray &, void *event, qintptr *) {
#ifdef Q_OS_WIN
  auto msg = static_cast<MSG *>(event);
  if (msg->message == WM_HOTKEY && msg->wParam == 0x5041) {
    collaboration.revoke();
    collaboration.releaseControl();
    return true;
  }
#else
  Q_UNUSED(event);
#endif
  return false;
}
void MainWindow::closeEvent(QCloseEvent *event) {
  // Closing always stops capture and input, even if the user keeps presence in
  // the tray.
  session.leave();
  if (!shuttingDown && tray.isSystemTrayAvailable()) {
    hide();
    event->ignore();
  } else
    event->accept();
}
QString MainWindow::name(const QString &id) const {
  for (const auto &v : session.users) {
    auto u = v.toObject();
    if (u["id"] == id)
      return u["name"].toString();
  }
  return "Teammate";
}
QJsonObject MainWindow::selected(QListWidget *list) const {
  return list->currentItem()
             ? list->currentItem()->data(Qt::UserRole).toJsonObject()
             : QJsonObject{};
}
void MainWindow::showError(const QString &text) { notice->setText(text); }
void MainWindow::resetMedia() {
  capture.stopCamera();
  capture.stopShare();
  collaboration.end();
  media.leave();
  micEnabled = false;
  sharer.clear();
  if (canvas)
    canvas->clear();
  for (auto tile : cameraTiles)
    delete tile;
  cameraTiles.clear();
}
void MainWindow::refresh() {
  pages->setCurrentIndex(session.signedIn ? 1 : 0);
  signIn->setEnabled(!session.busy);
  status->setText(session.connected
                      ? "In call · " + session.user["name"].toString()
                  : !session.connectingRoom.isEmpty()
                      ? "Joining call…"
                      : "Available · " + session.user["name"].toString());
  mic->setEnabled(session.connected);
  camera->setEnabled(session.connected);
  sharing->setEnabled(session.connected);
  control->setEnabled(session.connected && !sharer.isEmpty());
  mic->setText(micEnabled ? "Turn microphone off" : "Turn microphone on");
  camera->setText(capture.cameraActive() ? "Turn camera off"
                                         : "Turn camera on");
  sharing->setText(capture.sharing() ? "Stop sharing"
                                     : "Share screen / window");
  control->setText(collaboration.controlling() ? "Release control"
                                               : "Request control");
  controlStatus->setText(
      collaboration.hosting()
          ? name(collaboration.driver()) +
                " is controlling your shared display. Stop all remote control "
                "or press Ctrl+Alt+Escape to revoke immediately."
      : collaboration.controlling()
          ? "You control the shared display. Click it to type. Escape releases "
            "control."
      : stopShortcutAvailable
          ? "Remote control is off. Ctrl+Alt+Escape stops all remote input."
          : "Global control-stop shortcut unavailable. Hosting remote input "
            "is disabled. Escape releases viewer control.");
  QList<QPair<QString, QJsonObject>> rows;
  for (const auto &v : session.users) {
    auto u = v.toObject();
    if (u["id"] == session.user["id"])
      continue;
    rows.append({u["name"].toString() + " · " +
                     (u["busy"].toBool()     ? "In a call"
                      : u["online"].toBool() ? "Online"
                                             : "Offline"),
                 u});
  }
  fill(team, rows);
  rows.clear();
  QSet<QString> pending;
  for (qsizetype i = 0; i < session.calls.size(); ++i) {
    auto c = session.calls[i].toObject();
    bool incoming = c["target"].toObject()["id"] == session.user["id"];
    auto other = c[incoming ? "caller" : "target"].toObject();
    QString label = other["name"].toString() + " · " + c["status"].toString();
    if (auto seconds = callDuration(c))
      label += " · " + QString::number(*seconds / 60) + ":" +
               QString::number(*seconds % 60).rightJustified(2, '0');
    rows.append({label, c});
    if (c["status"] == "pending" && incoming) {
      auto id = c["id"].toString();
      pending.insert(id);
      if (!notified.contains(id)) {
        notified.insert(id);
        tray.showMessage("Incoming call",
                         other["name"].toString() + " is calling.");
        auto p = new QMessageBox(QMessageBox::Question, "Incoming call",
                                 other["name"].toString() + " is calling.",
                                 QMessageBox::Yes | QMessageBox::No, this);
        p->setTextFormat(Qt::PlainText);
        p->button(QMessageBox::Yes)->setText("Accept");
        p->button(QMessageBox::No)->setText("Decline");
        p->setAttribute(Qt::WA_DeleteOnClose);
        prompts[id] = p;
        connect(p, &QMessageBox::finished, this, [this, id](int result) {
          if (prompts.remove(id))
            session.answer(id, result == QMessageBox::Yes);
        });
        p->open();
      }
    }
  }
  fill(history, rows);
  rows.clear();
  for (auto i = prompts.begin(); i != prompts.end();)
    if (!pending.contains(i.key())) {
      auto dialog = i.value();
      i = prompts.erase(i);
      if (dialog)
        dialog->close();
    } else
      ++i;
  for (const auto &v : session.activeCalls) {
    auto r = v.toObject();
    rows.append({r["name"].toString() + " · " +
                     QString::number(r["participantCount"].toInt()) +
                     " participants",
                 r});
  }
  fill(active, rows);
  rows.clear();
  for (const auto &v : session.joinRequests) {
    auto r = v.toObject();
    rows.append({r["requester"].toObject()["name"].toString() + " · " +
                     r["status"].toString(),
                 r});
  }
  fill(requests, rows);
}
void MainWindow::share() {
  if (capture.sharing()) {
    capture.stopShare();
    return;
  }
  QList<QPointer<QScreen>> screens;
  for (auto screen : QGuiApplication::screens())
    screens.append(screen);
  const auto windows = QWindowCapture::capturableWindows();
  QStringList choices;
  for (auto screen : screens)
    choices << QString("Display %1: %2")
                   .arg(choices.size() + 1)
                   .arg(screen->name());
  for (const auto &window : windows)
    choices << QString("Window %1: %2")
                   .arg(choices.size() + 1 - screens.size())
                   .arg(window.description());
  bool ok = false;
  auto choice =
      QInputDialog::getItem(this, "Choose what to share",
                            "Only the selected display or window will be "
                            "shared. Windows may include notifications.",
                            choices, 0, false, &ok);
  if (!ok)
    return;
  int index = choices.indexOf(choice);
  if (index < 0)
    return;
  QPointer<QScreen> selectedDisplay;
  if (index < screens.size())
    selectedDisplay = screens[index];
  session.share(
      true, [this, selectedDisplay, screens, windows, index](bool allowed) {
        if (!allowed)
          return;
        media.screenSource(index >= screens.size());
        if (index < screens.size()) {
          // The display may have been unplugged while the API request was in
          // flight.
          if (!selectedDisplay || !capture.shareScreen(selectedDisplay)) {
            session.share(false, [](bool) {});
            return;
          }
        } else {
          auto window = windows[index - screens.size()];
          if (!window.isValid()) {
            session.share(false, [](bool) {});
            return;
          }
          if (!capture.shareWindow(window)) {
            session.share(false, [](bool) {});
            return;
          }
        }
        collaboration.sharing(true, capture.windowSharing(),
                              capture.controlBounds());
      });
}
void MainWindow::settings() {
  QDialog dialog(this);
  dialog.setWindowTitle("Settings");
  dialog.resize(560, 480);
  auto layout = new QVBoxLayout(&dialog);
  auto form = new QFormLayout;
  layout->addLayout(form);
  auto input = new QComboBox, output = new QComboBox, cameras = new QComboBox;
  input->setPlaceholderText("Loading microphones…");
  output->setPlaceholderText("Loading speakers…");
  input->setEnabled(false);
  output->setEnabled(false);
  cameras->setPlaceholderText("No cameras detected");
  form->addRow("Microphone", input);
  form->addRow("Speaker", output);
  form->addRow("Camera", cameras);
  for (const auto &device : QMediaDevices::videoInputs())
    cameras->addItem(device.description(), device.id());
  cameras->setEnabled(cameras->count() > 0);
  auto index = cameras->findData(preferences.value("camera").toByteArray());
  cameras->setCurrentIndex(index >= 0 ? index : cameras->count() > 0 ? 0 : -1);
  connect(cameras, &QComboBox::activated, &dialog, [this, cameras] {
    preferences.setValue("camera", cameras->currentData());
  });
  connect(&media, &Media::audioDevices, &dialog,
          [this, input, output](const QJsonArray &ins, const QJsonArray &outs) {
            auto populate = [&](QComboBox *box, const QJsonArray &devices,
                                const QString &key) {
              auto chosen = preferences.value(key).toString();
              box->clear();
              for (const auto &v : devices) {
                auto d = v.toObject();
                auto name = d["name"].toString().trimmed();
                box->addItem(name.isEmpty() ? "System default" : name,
                             d["id"].toString());
              }
              box->setPlaceholderText(key == "microphone"
                                          ? "No microphones detected"
                                          : "No speakers detected");
              box->setEnabled(!devices.isEmpty());
              int i = box->findData(chosen);
              box->setCurrentIndex(i >= 0 ? i : devices.isEmpty() ? -1 : 0);
            };
            populate(input, ins, "microphone");
            populate(output, outs, "speaker");
          });
  connect(input, &QComboBox::activated, &dialog, [this, input] {
    media.stopMicrophoneTest();
    preferences.setValue("microphone", input->currentData());
    media.devices(input->currentData().toString(), {});
  });
  connect(output, &QComboBox::activated, &dialog, [this, output] {
    preferences.setValue("speaker", output->currentData());
    media.devices({}, output->currentData().toString());
  });
  button("Refresh audio devices", layout, &dialog, [this] { media.devices(); });
  media.devices();
  Capture previewCapture;
  auto preview = new QLabel("Camera preview is off");
  preview->setMinimumHeight(130);
  preview->setAlignment(Qt::AlignCenter);
  layout->addWidget(preview);
  connect(&previewCapture, &Capture::preview, &dialog,
          [preview](const QImage &image) {
            preview->setPixmap(QPixmap::fromImage(image).scaled(
                240, 130, Qt::KeepAspectRatio));
          });
  connect(&previewCapture, &Capture::error, &dialog,
          [preview](const QString &text) { preview->setText(text); });
  auto testCamera = button(
      "Start / stop camera test", layout, &dialog, [&previewCapture, cameras] {
        if (previewCapture.cameraActive())
          previewCapture.stopCamera();
        else
          for (const auto &d : QMediaDevices::videoInputs())
            if (d.id() == cameras->currentData().toByteArray())
              previewCapture.startCamera(d, true);
      });
  auto localTestsAvailable = [this] {
    return !session.connected && session.roomId.isEmpty() &&
           session.connectingRoom.isEmpty();
  };
  testCamera->setEnabled(localTestsAvailable() && cameras->count() > 0);
  auto meter = new QProgressBar;
  meter->setRange(0, 100);
  meter->setAccessibleName("Local microphone level");
  layout->addWidget(meter);
  bool testingMicrophone = false, startingMicrophone = false;
  auto testDescription = new QLabel(
      "Test the selected microphone locally. No test audio is sent to a call. "
      "Tests stop when Settings closes or a call starts.");
  testDescription->setWordWrap(true);
  testDescription->setTextFormat(Qt::PlainText);
  QTimer meterTimer;
  meterTimer.setInterval(100);
  connect(&meterTimer, &QTimer::timeout, &dialog,
          [this, meter] { meter->setValue(media.microphoneTestLevel()); });
  auto testMic =
      button("Start selected microphone test", layout, &dialog,
             [this, input, &testingMicrophone, &startingMicrophone] {
               if (testingMicrophone || startingMicrophone) {
                 media.stopMicrophoneTest();
                 return;
               }
               startingMicrophone = true;
               media.startMicrophoneTest(input->currentData().toString());
             });
  testMic->setEnabled(false);
  connect(&media, &Media::audioDevices, &dialog,
          [localTestsAvailable, testMic](const QJsonArray &inputs,
                                         const QJsonArray &) {
            testMic->setEnabled(localTestsAvailable() && !inputs.isEmpty());
          });
  connect(&media, &Media::microphoneTestState, &dialog,
          [localTestsAvailable, &testingMicrophone, &startingMicrophone,
           &meterTimer, testMic, testDescription, meter,
           input](bool running, const QString &error) {
            testingMicrophone = running;
            startingMicrophone = false;
            testMic->setText(running ? "Stop microphone test"
                                     : "Start selected microphone test");
            testMic->setEnabled(running ||
                                (localTestsAvailable() && input->count() > 0));
            if (running) {
              testDescription->setText(
                  "Testing the selected microphone locally. "
                  "No audio is sent to a call.");
              meterTimer.start();
            } else {
              meterTimer.stop();
              meter->setValue(0);
              testDescription->setText(
                  error.isEmpty() ? "Microphone test is off. Tests stop "
                                    "when Settings closes or a call starts."
                                  : error);
            }
          });
  bool testsWereAvailable = localTestsAvailable();
  connect(&session, &CallSession::changed, &dialog,
          [this, localTestsAvailable, &testsWereAvailable, &previewCapture,
           testCamera, testMic, cameras, input, &testingMicrophone,
           &startingMicrophone] {
            const bool available = localTestsAvailable();
            if (testsWereAvailable && !available) {
              previewCapture.stopCamera();
              media.stopMicrophoneTest();
            }
            testsWereAvailable = available;
            testCamera->setEnabled(available && cameras->count() > 0);
            testMic->setEnabled(available &&
                                (testingMicrophone || startingMicrophone ||
                                 input->count() > 0));
          });
  layout->addWidget(testDescription);
  button("Export diagnostics", layout, &dialog, [this] { diagnostic(); });
#ifdef Q_OS_WIN
  button("Open Windows microphone privacy", layout, &dialog, [] {
    QDesktopServices::openUrl(QUrl("ms-settings:privacy-microphone"));
  });
  button("Open Windows camera privacy", layout, &dialog,
         [] { QDesktopServices::openUrl(QUrl("ms-settings:privacy-webcam")); });
#endif
  auto close = new QDialogButtonBox(QDialogButtonBox::Close);
  layout->addWidget(close);
  connect(close, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
  dialog.exec();
  media.stopMicrophoneTest();
  previewCapture.stopCamera();
}
void MainWindow::diagnostic() {
  auto path = QFileDialog::getSaveFileName(
      this, "Save diagnostics", "pairwise-diagnostics.json", "JSON (*.json)");
  if (path.isEmpty())
    return;
  QJsonObject report{
      {"version", PAIRWISE_VERSION},
      {"qtVersion", qVersion()},
      {"os", QSysInfo::productVersion()},
      {"architecture", QSysInfo::currentCpuArchitecture()},
      {"connected", session.connected},
      {"cameraOn", capture.cameraActive()},
      {"screenSharing", capture.sharing()},
      {"generatedAt", QDateTime::currentDateTimeUtc().toString(Qt::ISODate)}};
  QFile file(path);
  if (!file.open(QIODevice::WriteOnly) ||
      file.write(QJsonDocument(report).toJson()) < 0)
    showError("Diagnostics could not be saved.");
}
} // namespace pairwise
