#include "Api.h"
#include "Protocol.h"
#include <QCoreApplication>
#include <QEventLoop>
#include <QJsonDocument>
#include <QTimer>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <livekit/livekit.h>
#include <thread>

using namespace std::chrono_literals;
class Receiver : public livekit::RoomDelegate {
public:
  std::string expectedSender = "sender";
  std::atomic<int> audioFrames = 0, cameraFrames = 0, screenFrames = 0,
                   dataPackets = 0;
  void onTrackSubscribed(livekit::Room &room,
                         const livekit::TrackSubscribedEvent &event) override {
    const auto id = event.participant->identity(), name = event.track->name();
    if (event.track->kind() == livekit::TrackKind::KIND_AUDIO) {
      room.setOnAudioFrameCallback(id, name,
                                   [this](const livekit::AudioFrame &f) {
                                     for (auto sample : f.data())
                                       if (std::abs(int(sample)) > 100) {
                                         ++audioFrames;
                                         break;
                                       }
                                   });
    } else {
      const bool screen = event.publication->source() ==
                          livekit::TrackSource::SOURCE_SCREENSHARE;
      room.setOnVideoFrameCallback(
          id, name, [this, screen](const livekit::VideoFrame &f, std::int64_t) {
            if (f.width() == 320 && f.height() == 180) {
              if (screen)
                ++screenFrames;
              else
                ++cameraFrames;
            }
          });
    }
  }
  void onUserPacketReceived(livekit::Room &,
                            const livekit::UserDataPacketEvent &e) override {
    // Identity must come from the authenticated SDK participant, never payload
    // JSON.
    if (!e.participant || e.participant->identity() != expectedSender ||
        e.topic != pairwise::ControlTopic)
      return;
    auto p = QJsonDocument::fromJson(
                 QByteArray(reinterpret_cast<const char *>(e.data.data()),
                            qsizetype(e.data.size())))
                 .object();
    if (pairwise::validControl(p) && p["kind"] == "key" && p["code"] == 8 &&
        p["epoch"] == "integration")
      ++dataPackets;
  }
};
static void sharePermission(bool enabled) {
  const auto base = std::getenv("PAIRWISE_API_URL");
  if (!base)
    return;
  const auto token = std::getenv("PAIRWISE_API_SENDER_TOKEN"),
             room = std::getenv("PAIRWISE_API_ROOM_ID");
  if (!token || !room)
    throw std::runtime_error("missing API test admission");
  pairwise::Api api;
  api.configure(QUrl(QString::fromUtf8(base)), QString::fromUtf8(token));
  QEventLoop loop;
  bool ok = false;
  api.request("/v1/rooms/" + QString::fromUtf8(room) + "/share", "POST",
              {{"enabled", enabled}}, &loop, [&](pairwise::ApiResult result) {
                ok = bool(result);
                loop.quit();
              });
  QTimer::singleShot(20000, &loop, &QEventLoop::quit);
  loop.exec();
  if (!ok)
    throw std::runtime_error("API screen-share permission failed");
}
int main(int argc, char **argv) {
  QCoreApplication app(argc, argv);
  const auto url = std::getenv("PAIRWISE_MEDIA_TEST_URL"),
             senderToken = std::getenv("PAIRWISE_MEDIA_SENDER_TOKEN"),
             receiverToken = std::getenv("PAIRWISE_MEDIA_RECEIVER_TOKEN");
  if (!url || !senderToken || !receiverToken) {
    std::cerr << "Run through run-media-test.py; no production credentials are "
                 "used.\n";
    return 77;
  }
  livekit::initialize(livekit::LogLevel::Error);
  livekit::setLogCallback(
      [](livekit::LogLevel, const std::string &, const std::string &) {});
  int result = 1;
  try {
    Receiver delegate;
    if (const auto id = std::getenv("PAIRWISE_MEDIA_SENDER_ID"))
      delegate.expectedSender = id;
    const auto receiverID = std::getenv("PAIRWISE_MEDIA_RECEIVER_ID");
    livekit::Room receiver, sender;
    receiver.setDelegate(&delegate);
    livekit::RoomOptions options;
    options.single_peer_connection = false;
    if (!receiver.connect(url, receiverToken, options) ||
        !sender.connect(url, senderToken, options))
      throw std::runtime_error("native room connection failed");
    auto local = sender.localParticipant().lock();
    if (!local)
      throw std::runtime_error("missing local participant");
    auto mic = std::make_shared<livekit::AudioSource>(48000, 1);
    auto audio = local->publishAudioTrack(
        "test-audio", mic, livekit::TrackSource::SOURCE_MICROPHONE);
    auto camera = std::make_shared<livekit::VideoSource>(320, 180),
         screen = std::make_shared<livekit::VideoSource>(320, 180);
    auto cameraTrack = local->publishVideoTrack(
        "camera", camera, livekit::TrackSource::SOURCE_CAMERA);
    sharePermission(true);
    auto screenTrack =
        local->publishVideoTrack("pairdesk.screen.display", screen,
                                 livekit::TrackSource::SOURCE_SCREENSHARE);
    std::this_thread::sleep_for(1s);
    auto packet = pairwise::message("key", "integration", 1);
    packet["code"] = 8;
    packet["down"] = true;
    packet["modifiers"] = 1 << 20;
    auto bytes = QJsonDocument(packet).toJson(QJsonDocument::Compact);
    auto video =
        livekit::VideoFrame::create(320, 180, livekit::VideoBufferType::RGBA);
    for (std::size_t i = 0; i < video.dataSize(); ++i)
      video.data()[i] = std::uint8_t((i / 4) % 256);
    auto start = std::chrono::steady_clock::now();
    for (int tick = 0; tick < 1000; ++tick) {
      auto frame = livekit::AudioFrame::create(48000, 1, 480);
      for (int i = 0; i < 480; ++i)
        frame.data()[i] =
            std::int16_t(10000 * std::sin((tick * 480 + i) * 2 *
                                          3.141592653589793 * 440 / 48000));
      mic->captureFrame(frame, 1000);
      if (tick % 4 == 0) {
        camera->captureFrame(video);
        screen->captureFrame(video);
      }
      if (tick % 50 == 0)
        local->publishData(
            std::vector<std::uint8_t>(bytes.begin(), bytes.end()), true,
            {receiverID ? receiverID : "receiver"}, pairwise::ControlTopic);
      if (delegate.audioFrames > 10 && delegate.cameraFrames > 3 &&
          delegate.screenFrames > 3 && delegate.dataPackets > 0) {
        result = 0;
        break;
      }
      std::this_thread::sleep_until(start + (tick + 1) * 10ms);
    }
    std::cout << "Decoded synthetic audio=" << delegate.audioFrames
              << " camera=" << delegate.cameraFrames
              << " screen=" << delegate.screenFrames
              << " authenticated control=" << delegate.dataPackets << "\n";
    local->unpublishTrack(audio->sid());
    local->unpublishTrack(cameraTrack->sid());
    local->unpublishTrack(screenTrack->sid());
    sharePermission(false);
    sender.disconnect();
    receiver.disconnect();
    receiver.setDelegate(nullptr);
  } catch (const std::exception &e) {
    result = 1;
    std::cerr << "Synthetic media integration failed: " << e.what() << "\n";
  }
  livekit::shutdown();
  return result;
}
