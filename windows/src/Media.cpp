#include "Media.h"
#include "Protocol.h"
#include <QJsonDocument>
#include <QMutex>
#include <QTimer>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <livekit/livekit.h>
#include <thread>

namespace pairwise {
class MediaWorker : public QObject, public livekit::RoomDelegate {
  Q_OBJECT
public:
  std::unique_ptr<livekit::Room> room;
  std::unique_ptr<livekit::PlatformAudio> audio;
  std::shared_ptr<livekit::PlatformAudioSource> microphoneSource;
  std::shared_ptr<livekit::LocalAudioTrack> microphoneTrack;
  std::shared_ptr<livekit::VideoSource> sources[2];
  std::shared_ptr<livekit::LocalVideoTrack> videos[2];
  std::atomic<quint64> generation = 0;
  struct Frame {
    QString identity, name;
    bool screen;
    QImage image;
    quint64 generation;
  };
  QMutex frameLock;
  QMap<QString, Frame> received;
  bool frameDeliveryQueued = false;
  std::string screenName = "pairdesk.screen.display";
  QImage outgoing[2];
  quint64 outgoingGeneration[2] = {0, 0};
  bool suspended = false;
  std::atomic<quint64> testRequest = 0;
  std::atomic<int> testPeak = 0;
  std::unique_ptr<livekit::PlatformAudio> testAudio;
  std::shared_ptr<livekit::PlatformAudioSource> testSource;
  std::shared_ptr<livekit::LocalAudioTrack> testTrack;
  std::shared_ptr<livekit::AudioStream> testStream;
  std::thread testReader;
  void stopTest(bool notify = true) {
    if (testStream)
      testStream
          ->close(); // Wakes a reader even when the device is silent/gone.
    if (testReader.joinable())
      testReader.join();
    testStream.reset();
    testTrack.reset();
    testSource.reset();
    testAudio.reset();
    testPeak = 0;
    if (notify)
      emit testState(testRequest.load(), false, {});
  }
  void startTest(quint64 request, const QString &deviceId) {
    stopTest(false);
    if (request != testRequest.load())
      return;
    try {
      if (room)
        throw std::runtime_error("call is active");
      testAudio = std::make_unique<livekit::PlatformAudio>();
      if (!deviceId.isEmpty()) {
        const auto devices = testAudio->recordingDevices();
        if (std::none_of(devices.begin(), devices.end(),
                         [&](const auto &device) {
                           return device.id == deviceId.toStdString();
                         }))
          throw std::runtime_error("selected device is unavailable");
        testAudio->setRecordingDevice(deviceId.toStdString());
      }
      if (request != testRequest.load()) {
        stopTest();
        return;
      }
      testSource = testAudio->createAudioSource();
      testTrack = livekit::LocalAudioTrack::createLocalAudioTrack(
          "local-microphone-test", testSource);
      livekit::AudioStream::Options options;
      options.capacity = 4;
      testStream = livekit::AudioStream::fromTrack(testTrack, options);
      if (request != testRequest.load()) {
        stopTest();
        return;
      }
      // This local track is never published or attached to a room.
      testReader = std::thread([this, stream = testStream, request] {
        try {
          livekit::AudioFrameEvent event;
          while (stream->read(event)) {
            if (request != testRequest.load())
              break;
            int peak = 0;
            for (auto sample : event.frame.data())
              peak = std::max(peak, std::abs(int(sample)));
            peak = std::min(100, peak * 100 / 32768);
            int previous = testPeak.load();
            while (peak > previous &&
                   !testPeak.compare_exchange_weak(previous, peak)) {
            }
          }
        } catch (const std::exception &) {
          // Device removal/errors must stop capture rather than terminate the
          // app.
        }
        QMetaObject::invokeMethod(this, [this, request] {
          if (request != testRequest.load())
            return;
          stopTest(false);
          emit testState(
              request, false,
              "Microphone test stopped. Refresh devices and try again.");
        });
      });
      emit testState(request, true, {});
    } catch (const std::exception &) {
      stopTest(false);
      emit testState(request, false,
                     "The selected microphone could not be tested. Refresh "
                     "devices and check Windows microphone privacy settings.");
    }
  }
  void close() {
    stopTest();
    suspended = true;
    if (room) {
      room->setDelegate(nullptr);
      room->disconnect();
      room.reset();
    }
    microphoneTrack.reset();
    microphoneSource.reset();
    for (int i = 0; i < 2; ++i) {
      videos[i].reset();
      sources[i].reset();
    }
    audio.reset();
    QMutexLocker lock(&frameLock);
    received.clear();
    outgoing[0] = {};
    outgoing[1] = {};
  }
  void join(quint64 value, const QString &url, const QString &token) {
    close();
    generation = value;
    suspended = false;
    try {
      audio = std::make_unique<livekit::PlatformAudio>();
      room = std::make_unique<livekit::Room>();
      room->setDelegate(this);
      livekit::RoomOptions options;
      options.auto_subscribe = true;
      options.dynacast = true;
      options.single_peer_connection = false;
      options.connect_timeout = std::chrono::seconds(12);
      options.join_retries = 1;
      if (!room->connect(url.toStdString(), token.toStdString(), options))
        throw std::runtime_error("connect");
      emit connected(generation);
    } catch (const std::exception &) {
      close();
      emit failed(value,
                  "Unable to connect media. Check your server, firewall, and "
                  "audio devices.",
                  true);
    }
  }
  void participants() {
    if (room)
      for (auto weak : room->remoteParticipants())
        if (auto person = weak.lock())
          emit arrived(generation, QString::fromStdString(person->identity()));
  }
  void mic(bool enabled) {
    if (!room || suspended)
      return;
    try {
      auto local = room->localParticipant().lock();
      if (!local)
        return;
      if (!enabled) {
        if (microphoneTrack)
          local->unpublishTrack(microphoneTrack->sid());
        microphoneTrack.reset();
        microphoneSource.reset();
      } else if (!microphoneTrack) {
        microphoneSource = audio->createAudioSource();
        microphoneTrack = livekit::LocalAudioTrack::createLocalAudioTrack(
            "microphone", microphoneSource);
        livekit::TrackPublishOptions options;
        options.source = livekit::TrackSource::SOURCE_MICROPHONE;
        options.dtx = true;
        local->publishTrack(microphoneTrack, options);
      }
      emit micState(generation, enabled);
    } catch (const std::exception &) {
      microphoneTrack.reset();
      microphoneSource.reset();
      emit micState(generation, false);
      emit failed(generation,
                  "Microphone unavailable. Check Windows privacy settings and "
                  "the selected device.",
                  false);
    }
  }
  void enumerate(const QString &input, const QString &output) {
    try {
      // Device enumeration does not create a microphone source or start
      // recording.
      if (!audio)
        audio = std::make_unique<livekit::PlatformAudio>();
      if (!input.isEmpty())
        audio->setRecordingDevice(input.toStdString());
      if (!output.isEmpty())
        audio->setPlayoutDevice(output.toStdString());
      QJsonArray inputs, outputs;
      for (const auto &d : audio->recordingDevices())
        inputs.append(QJsonObject{{"id", QString::fromStdString(d.id)},
                                  {"name", QString::fromStdString(d.name)}});
      for (const auto &d : audio->playoutDevices())
        outputs.append(QJsonObject{{"id", QString::fromStdString(d.id)},
                                   {"name", QString::fromStdString(d.name)}});
      emit deviceList(inputs, outputs);
    } catch (const std::exception &) {
      emit deviceList({}, {});
      emit failed(
          generation,
          "Audio device selection failed. Refresh devices and try again.",
          false);
    }
  }
  void unpublish(bool screen) {
    int i = screen ? 1 : 0;
    if (room && videos[i]) {
      if (auto local = room->localParticipant().lock())
        local->unpublishTrack(videos[i]->sid());
    }
    videos[i].reset();
    sources[i].reset();
    QMutexLocker lock(&frameLock);
    outgoing[i] = {};
  }
  void pump() {
    for (int i = 0; i < 2; ++i) {
      QImage image;
      quint64 current;
      {
        QMutexLocker lock(&frameLock);
        image = std::move(outgoing[i]);
        current = outgoingGeneration[i];
      }
      if (image.isNull() || current != generation || !room || suspended)
        continue;
      try {
        auto local = room->localParticipant().lock();
        if (!local)
          continue;
        if (!sources[i]) {
          sources[i] = std::make_shared<livekit::VideoSource>(image.width(),
                                                              image.height());
          videos[i] = livekit::LocalVideoTrack::createLocalVideoTrack(
              i ? screenName : "camera", sources[i]);
          livekit::TrackPublishOptions o;
          o.source = i ? livekit::TrackSource::SOURCE_SCREENSHARE
                       : livekit::TrackSource::SOURCE_CAMERA;
          o.video_encoding =
              livekit::VideoEncodingOptions{i ? 8000000ULL : 1500000ULL, 30};
          o.simulcast = !i;
          o.degradation_preference =
              i ? livekit::DegradationPreference::MaintainResolution
                : livekit::DegradationPreference::Balanced;
          local->publishTrack(videos[i], o);
        }
        image = image.convertToFormat(QImage::Format_RGBA8888);
        auto frame = livekit::VideoFrame::create(
            image.width(), image.height(), livekit::VideoBufferType::RGBA);
        for (int row = 0; row < image.height(); ++row)
          std::memcpy(frame.data() + row * image.width() * 4,
                      image.constScanLine(row), image.width() * 4);
        sources[i]->captureFrame(frame);
      } catch (const std::exception &) {
        try {
          unpublish(i == 1);
        } catch (...) {
        }
        emit failed(generation,
                    i ? "Screen publishing failed. Sharing has stopped."
                      : "Camera publishing failed. Camera has stopped.",
                    false);
        emit videoFailed(generation, i == 1);
      }
    }
    QMutexLocker lock(&frameLock);
    if (!received.isEmpty() && !frameDeliveryQueued) {
      frameDeliveryQueued = true;
      emit framesAvailable();
    }
  }
  void onTrackSubscribed(livekit::Room &r,
                         const livekit::TrackSubscribedEvent &event) override {
    if (!event.participant || !event.track ||
        event.track->kind() != livekit::TrackKind::KIND_VIDEO)
      return;
    const QString id = QString::fromStdString(event.participant->identity());
    const QString name = QString::fromStdString(event.track->name());
    const bool screen =
        event.publication->source() == livekit::TrackSource::SOURCE_SCREENSHARE;
    const auto current = generation.load();
    emit subscribed(current, id, name);
    r.setOnVideoFrameCallback(
        id.toStdString(), name.toStdString(),
        [this, id, name, screen, current](const livekit::VideoFrame &frame,
                                          std::int64_t) {
          try {
            auto rgba = frame.convert(livekit::VideoBufferType::RGBA);
            QImage image(rgba.data(), rgba.width(), rgba.height(),
                         rgba.width() * 4, QImage::Format_RGBA8888);
            QMutexLocker lock(&frameLock);
            if (received.size() < 16 || received.contains(id + "/" + name))
              received[id + "/" + name] = {id, name, screen, image.copy(),
                                           current};
          } catch (const std::exception &) {
          }
        });
  }
  void onTrackUnsubscribed(livekit::Room &r,
                           const livekit::TrackUnsubscribedEvent &e) override {
    if (!e.participant || !e.track)
      return;
    const auto id = e.participant->identity(), name = e.track->name();
    if (e.track->kind() == livekit::TrackKind::KIND_VIDEO)
      r.clearOnVideoFrameCallback(id, name);
    {
      QMutexLocker lock(&frameLock);
      received.remove(QString::fromStdString(id + "/" + name));
    }
    emit gone(
        generation, QString::fromStdString(id), QString::fromStdString(name),
        e.publication->source() == livekit::TrackSource::SOURCE_SCREENSHARE);
  }
  void onParticipantDisconnected(
      livekit::Room &,
      const livekit::ParticipantDisconnectedEvent &e) override {
    if (e.participant)
      emit departed(generation,
                    QString::fromStdString(e.participant->identity()));
  }
  void
  onParticipantConnected(livekit::Room &,
                         const livekit::ParticipantConnectedEvent &e) override {
    if (e.participant)
      emit arrived(generation,
                   QString::fromStdString(e.participant->identity()));
  }
  void onUserPacketReceived(livekit::Room &,
                            const livekit::UserDataPacketEvent &e) override {
    if (!e.participant || e.data.size() > MaximumWireBytes)
      return;
    auto doc = QJsonDocument::fromJson(
        QByteArray(reinterpret_cast<const char *>(e.data.data()),
                   qsizetype(e.data.size())));
    if (doc.isObject())
      emit data(generation, QString::fromStdString(e.topic), doc.object(),
                QString::fromStdString(e.participant->identity()));
  }
  void onReconnecting(livekit::Room &,
                      const livekit::ReconnectingEvent &) override {
    emit state(generation, 1);
  }
  void onReconnected(livekit::Room &,
                     const livekit::ReconnectedEvent &) override {
    emit state(generation, 2);
  }
  void onDisconnected(livekit::Room &,
                      const livekit::DisconnectedEvent &) override {
    emit state(generation, 0);
  }
signals:
  void connected(quint64 generation);
  void state(quint64 generation, int state);
  void failed(quint64 generation, const QString &text, bool fatal);
  void micState(quint64 generation, bool enabled);
  void deviceList(QJsonArray inputs, QJsonArray outputs);
  void testState(quint64 request, bool running, QString error);
  void framesAvailable();
  void gone(quint64 generation, QString id, QString name, bool screen);
  void departed(quint64 generation, QString id);
  void arrived(quint64 generation, QString id);
  void data(quint64 generation, QString topic, QJsonObject packet,
            QString sender);
  void videoFailed(quint64 generation, bool screen);
  void subscribed(quint64 generation, QString id, QString name);
};
Media::Media(QObject *parent) : QObject(parent), worker(new MediaWorker) {
  worker->moveToThread(&thread);
  connect(&thread, &QThread::finished, worker, &QObject::deleteLater);
  connect(worker, &MediaWorker::connected, this, [this](quint64 n) {
    if (n == generation && active)
      emit connected();
  });
  connect(worker, &MediaWorker::state, this, [this](quint64 n, int s) {
    if (n != generation || !active)
      return;
    if (s == 1)
      emit reconnecting();
    else if (s == 2)
      emit reconnected();
    else
      emit disconnected();
  });
  connect(worker, &MediaWorker::failed, this,
          [this](quint64 n, const QString &text, bool fatal) {
            if (n != generation)
              return;
            emit error(text);
            if (fatal)
              emit disconnected();
          });
  connect(worker, &MediaWorker::micState, this, [this](quint64 n, bool on) {
    if (n == generation)
      emit microphoneChanged(on);
  });
  connect(worker, &MediaWorker::deviceList, this, &Media::audioDevices);
  connect(worker, &MediaWorker::testState, this,
          [this](quint64 request, bool running, const QString &error) {
            if (request == worker->testRequest.load())
              emit microphoneTestState(running, error);
          });
  connect(worker, &MediaWorker::subscribed, this,
          [this](quint64 n, QString id, QString name) {
            if (n == generation && active)
              remoteTracks.insert(id + "/" + name);
          });
  connect(worker, &MediaWorker::framesAvailable, this, [this] {
    QMap<QString, MediaWorker::Frame> batch;
    {
      QMutexLocker lock(&worker->frameLock);
      batch.swap(worker->received);
      worker->frameDeliveryQueued = false;
    }
    for (const auto &f : batch)
      if (f.generation == generation && active &&
          remoteTracks.contains(f.identity + "/" + f.name))
        emit frame(f.identity, f.name, f.screen, f.image);
  });
  connect(worker, &MediaWorker::gone, this,
          [this](quint64 n, QString id, QString name, bool screen) {
            if (n == generation && active) {
              remoteTracks.remove(id + "/" + name);
              emit trackGone(id, name, screen);
            }
          });
  connect(worker, &MediaWorker::departed, this, [this](quint64 n, QString id) {
    if (n == generation && active)
      emit participantLeft(id);
  });
  connect(worker, &MediaWorker::arrived, this, [this](quint64 n, QString id) {
    if (n == generation && active)
      emit participantJoined(id);
  });
  connect(worker, &MediaWorker::data, this,
          [this](quint64 n, QString topic, QJsonObject p, QString sender) {
            if (n == generation && active)
              emit packet(topic, p, sender);
          });
  connect(worker, &MediaWorker::videoFailed, this,
          [this](quint64 n, bool screen) {
            if (n == generation)
              emit trackGone({}, {}, screen);
          });
  thread.start();
  QMetaObject::invokeMethod(worker, [this] {
    auto timer = new QTimer(worker);
    timer->setInterval(33);
    connect(timer, &QTimer::timeout, worker, &MediaWorker::pump);
    timer->start();
  });
}
Media::~Media() {
  ++worker->testRequest;
  QMetaObject::invokeMethod(
      worker, [this] { worker->close(); }, Qt::BlockingQueuedConnection);
  thread.quit();
  thread.wait();
}
void Media::join(const QString &url, const QString &token) {
  stopMicrophoneTest();
  active = true;
  auto n = ++generation;
  QMetaObject::invokeMethod(worker, [=, this] { worker->join(n, url, token); });
}
void Media::refreshParticipants() {
  if (active)
    QMetaObject::invokeMethod(worker, [this] { worker->participants(); });
}
void Media::leave() {
  stopMicrophoneTest();
  active = false;
  ++generation;
  remoteTracks.clear();
  QMetaObject::invokeMethod(worker, [this] { worker->close(); });
  emit microphoneChanged(false);
}
void Media::microphone(bool enabled) {
  if (active)
    QMetaObject::invokeMethod(worker,
                              [this, enabled] { worker->mic(enabled); });
}
void Media::devices(const QString &input, const QString &output) {
  QMetaObject::invokeMethod(worker,
                            [=, this] { worker->enumerate(input, output); });
}
void Media::startMicrophoneTest(const QString &deviceId) {
  if (active) {
    emit microphoneTestState(false,
                             "Leave the call before testing a microphone.");
    return;
  }
  const auto request = ++worker->testRequest;
  QMetaObject::invokeMethod(worker, [this, request, deviceId] {
    worker->startTest(request, deviceId);
  });
}
void Media::stopMicrophoneTest() {
  ++worker->testRequest;
  QMetaObject::invokeMethod(worker, [this] { worker->stopTest(); });
}
int Media::microphoneTestLevel() const { return worker->testPeak.exchange(0); }
void Media::video(bool screen, const QImage &image) {
  if (!active)
    return;
  QMutexLocker lock(&worker->frameLock);
  worker->outgoing[screen ? 1 : 0] = image;
  worker->outgoingGeneration[screen ? 1 : 0] = generation;
}
void Media::screenSource(bool window) {
  QMetaObject::invokeMethod(worker, [this, window] {
    worker->screenName =
        window ? "pairdesk.screen.window" : "pairdesk.screen.display";
  });
}
void Media::stopVideo(bool screen) {
  QMetaObject::invokeMethod(worker, [this, screen] {
    try {
      worker->unpublish(screen);
    } catch (const std::exception &) {
      emit worker->failed(
          worker->generation,
          "Unable to stop the media track. Leave the call to finish cleanup.",
          true);
    }
  });
}
void Media::send(const QString &topic, const QJsonObject &packet,
                 const QString &recipient, bool reliable) {
  if (!active || recipient.isEmpty())
    return;
  auto bytes = QJsonDocument(packet).toJson(QJsonDocument::Compact);
  if (bytes.size() > MaximumWireBytes)
    return;
  if (pendingSends.fetch_add(1) >= 128) {
    pendingSends.fetch_sub(1);
    // Invalidate sends before notifying listeners: cleanup itself sends release
    // packets, which must not recursively overflow the same full queue.
    leave();
    emit error("Collaboration queue is full. Remote control has stopped.");
    emit disconnected();
    return;
  }
  const auto n = generation.load();
  QMetaObject::invokeMethod(worker, [=, this] {
    pendingSends.fetch_sub(1);
    if (n != generation.load() || n != worker->generation || !worker->room)
      return;
    try {
      if (auto local = worker->room->localParticipant().lock())
        local->publishData(
            std::vector<std::uint8_t>(bytes.begin(), bytes.end()), reliable,
            {recipient.toStdString()}, topic.toStdString());
    } catch (const std::exception &) {
      emit worker->failed(
          n,
          "Collaboration transport failed. Rejoin the call to resume control.",
          true);
    }
  });
}
} // namespace pairwise
#include "Media.moc"
