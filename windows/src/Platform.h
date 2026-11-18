#pragma once
#include <QJsonObject>
#include <QRect>
#include <QSet>
#include <QString>
#include <optional>
class QWidget;
namespace pairwise {
bool saveToken(const QString &server, const QString &token);
QString loadToken(const QString &server);
void deleteToken(const QString &server);
bool excludeFromCapture(QWidget *window);
std::optional<QRect> physicalDisplayRect(const QString &name);
class InputInjector {
public:
  bool inject(const QJsonObject &packet, const QRect &physicalBounds);
  bool shortcut(bool paste);
  void releaseAll();
  bool desktopAvailable() const;
  bool dragging() const { return !heldButtons.isEmpty(); }

private:
  bool key(int virtualKey, bool down);
  bool move(double x, double y, const QRect &bounds);
  bool button(int code, bool down);
  bool modifiers(quint64 flags);
  QSet<int> heldKeys, heldButtons;
};
} // namespace pairwise
