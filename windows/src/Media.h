#pragma once
#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QThread>
#include <atomic>

namespace pairwise {
class MediaWorker;
class Media : public QObject {
  Q_OBJECT
public:
  explicit Media(QObject *parent = nullptr);
  ~Media() override;
  void join(const QString &url, const QString &token);
  void leave();
  void microphone(bool enabled);
  void devices(const QString &input = {}, const QString &output = {});
  void startMicrophoneTest(const QString &deviceId);
  void stopMicrophoneTest();
  int microphoneTestLevel() const;
  void refreshParticipants();
  void video(bool screen, const QImage &image);
  void stopVideo(bool screen);
  void screenSource(bool window);
  void send(const QString &topic, const QJsonObject &packet,
            const QString &recipient, bool reliable = true);
signals:
  void connected();
  void reconnecting();
  void reconnected();
  void disconnected();
  void error(const QString &text);
  void microphoneChanged(bool enabled);
  void audioDevices(const QJsonArray &inputs, const QJsonArray &outputs);
  void microphoneTestState(bool running, const QString &error);
  void packet(const QString &topic, const QJsonObject &message,
              const QString &sender);
  void frame(const QString &identity, const QString &name, bool screen,
             const QImage &image);
  void trackGone(const QString &identity, const QString &name, bool screen);
  void participantLeft(const QString &identity);
  void participantJoined(const QString &identity);

private:
  QThread thread;
  MediaWorker *worker;
  std::atomic<quint64> generation = 0;
  bool active = false;
  QSet<QString> remoteTracks;
  std::atomic<int> pendingSends = 0;
};
} // namespace pairwise
