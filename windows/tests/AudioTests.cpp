#include "Media.h"
#include <QSignalSpy>
#include <QUuid>
#include <QtTest>
#include <algorithm>
#include <atomic>
#include <livekit/livekit.h>
#include <thread>

using namespace pairwise;
class AudioTests : public QObject {
  Q_OBJECT
  QString missingDevice() const {
    return "pairwise-unavailable-" + QUuid::createUuid().toString();
  }
private slots:
  void initTestCase() {
    livekit::initialize(livekit::LogLevel::Error);
    livekit::setLogCallback([](auto, const auto &, const auto &) {});
  }
  void cleanupTestCase() { livekit::shutdown(); }
  void unavailableSelectedDeviceFailsWithoutCapture() {
    Media media;
    QSignalSpy states(&media, &Media::microphoneTestState);
    media.startMicrophoneTest(missingDevice());
    QTRY_VERIFY_WITH_TIMEOUT(!states.isEmpty(), 10000);
    for (const auto &state : states)
      QVERIFY(!state[0].toBool());
    QVERIFY(!states.last()[1].toString().isEmpty());
    QCOMPARE(media.microphoneTestLevel(), 0);
  }
  void cancelledQueuedStartsDoNotLeakIntoNextTest() {
    Media media;
    QSignalSpy states(&media, &Media::microphoneTestState);
    for (int i = 0; i < 20; ++i)
      media.startMicrophoneTest(missingDevice());
    media.stopMicrophoneTest();
    QTRY_VERIFY_WITH_TIMEOUT(!states.isEmpty(), 10000);
    for (const auto &state : states) {
      QVERIFY(!state[0].toBool());
      QVERIFY(state[1].toString().isEmpty());
    }
    states.clear();
    media.startMicrophoneTest(missingDevice());
    QTRY_VERIFY_WITH_TIMEOUT(!states.isEmpty(), 10000);
    QVERIFY(!states.last()[0].toBool());
    QVERIFY(!states.last()[1].toString().isEmpty());
  }
  void destructionCancelsQueuedCapture() {
    auto media = std::make_unique<Media>();
    media->startMicrophoneTest(missingDevice());
    media.reset();
    QCoreApplication::processEvents();
  }
  void unpublishedLocalTrackDeliversPCMAndReaderStops() {
    // Exercise the meter's SDK path without opening a physical microphone or
    // room.
    auto source = std::make_shared<livekit::AudioSource>(48000, 1);
    auto track =
        livekit::LocalAudioTrack::createLocalAudioTrack("local-only", source);
    livekit::AudioStream::Options options;
    options.capacity = 4;
    auto stream = livekit::AudioStream::fromTrack(track, options);
    std::atomic<int> frames = 0;
    std::thread reader([&] {
      livekit::AudioFrameEvent event;
      while (stream->read(event))
        for (auto sample : event.frame.data())
          if (std::abs(int(sample)) > 100) {
            ++frames;
            break;
          }
    });
    // RAII ensures a failing assertion cannot leave a joinable reader behind.
    struct Cleanup {
      std::shared_ptr<livekit::AudioStream> stream;
      std::thread &reader;
      ~Cleanup() {
        stream->close();
        if (reader.joinable())
          reader.join();
      }
    } cleanup{stream, reader};
    for (int i = 0; i < 20 && frames == 0; ++i) {
      auto frame = livekit::AudioFrame::create(48000, 1, 480);
      std::fill(frame.data().begin(), frame.data().end(), std::int16_t(10000));
      source->captureFrame(frame, 1000);
      QTest::qWait(10);
    }
    QVERIFY(frames > 0);
    stream->close();
    reader.join();
  }
};
QTEST_GUILESS_MAIN(AudioTests)
#include "AudioTests.moc"
