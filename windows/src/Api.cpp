#include "Api.h"
#include <QJsonDocument>
#include <QNetworkReply>
#include <QPointer>

namespace pairwise {
Api::Api(QObject *parent) : QObject(parent) {}
void Api::configure(const QUrl &server, const QString &value) {
  base = server;
  token = value;
  ++generation;
}
void Api::request(const QString &path, const QString &method,
                  const QJsonObject &body, QObject *context,
                  std::function<void(ApiResult)> done) {
  QUrl url = base;
  url.setPath(path);
  QNetworkRequest req(url);
  req.setTransferTimeout(15000);
  req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                   QNetworkRequest::ManualRedirectPolicy);
  req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
  if (!token.isEmpty())
    req.setRawHeader("Authorization", ("Bearer " + token).toUtf8());
  auto *reply = method == "GET"
                    ? network.get(req)
                    : network.sendCustomRequest(
                          req, method.toUtf8(),
                          QJsonDocument(body).toJson(QJsonDocument::Compact));
  reply->setReadBufferSize(1024 * 1024 + 1);
  // Bound response storage and abort even if a hostile server streams forever.
  auto data = std::make_shared<QByteArray>();
  auto oversized = std::make_shared<bool>(false);
  connect(reply, &QIODevice::readyRead, reply, [reply, data, oversized] {
    data->append(reply->readAll());
    if (data->size() > 1024 * 1024) {
      *oversized = true;
      reply->abort();
    }
  });
  const auto current = generation;
  QPointer<QObject> guard(context);
  connect(reply, &QNetworkReply::finished, this, [=, this] {
    reply->deleteLater();
    if (!guard || current != generation)
      return;
    data->append(reply->readAll());
    ApiResult result;
    result.status =
        reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    QJsonParseError parse;
    const auto doc = QJsonDocument::fromJson(*data, &parse);
    if (*oversized || data->size() > 1024 * 1024)
      result.error = "The server response was too large.";
    else if (result.status < 200 || result.status >= 300)
      result.error = doc.object().value("error").toString(
          "Request failed. Check the server and your connection.");
    else if (result.status != 204 &&
             (!doc.isObject() || parse.error != QJsonParseError::NoError))
      result.error = "The server returned an incompatible response.";
    else
      result.body = doc.object();
    done(result);
  });
}
} // namespace pairwise
