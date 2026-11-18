#pragma once
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QObject>
#include <functional>

namespace pairwise {
struct ApiResult {
  int status = 0;
  QJsonObject body;
  QString error;
  explicit operator bool() const {
    return error.isEmpty() && status >= 200 && status < 300;
  }
};
class Api : public QObject {
  Q_OBJECT
public:
  explicit Api(QObject *parent = nullptr);
  void configure(const QUrl &server, const QString &token = {});
  void request(const QString &path, const QString &method,
               const QJsonObject &body, QObject *context,
               std::function<void(ApiResult)> done);
  QUrl server() const { return base; }

private:
  QNetworkAccessManager network;
  QUrl base;
  QString token;
  quint64 generation = 0;
};
} // namespace pairwise
