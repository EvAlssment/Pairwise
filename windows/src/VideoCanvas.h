#pragma once
#include <QElapsedTimer>
#include <QImage>
#include <QJsonObject>
#include <QMap>
#include <QWidget>
namespace pairwise {
class VideoCanvas : public QWidget {
  Q_OBJECT
public:
  explicit VideoCanvas(QWidget *parent = nullptr);
  void setFrame(const QImage &image);
  void setControlling(bool value);
  void setPointer(const QString &identity, const QPointF &position,
                  bool visible, const QString &label = {});
  void clear();
signals:
  void input(QJsonObject event);
  void cursor(QPointF point, bool visible);
  void unfocused();

protected:
  void paintEvent(QPaintEvent *) override;
  void mouseMoveEvent(QMouseEvent *) override;
  void mousePressEvent(QMouseEvent *) override;
  void mouseReleaseEvent(QMouseEvent *) override;
  void wheelEvent(QWheelEvent *) override;
  bool focusNextPrevChild(bool next) override;
  void keyPressEvent(QKeyEvent *) override;
  void keyReleaseEvent(QKeyEvent *) override;
  void focusOutEvent(QFocusEvent *) override;
  void leaveEvent(QEvent *) override;

private:
  void button(QMouseEvent *event, bool down);
  void key(QKeyEvent *event, bool down);
  QImage image;
  bool controlling = false;
  struct Pointer {
    QPointF position;
    qint64 at;
    QString label;
  };
  QMap<QString, Pointer> pointers;
  QElapsedTimer clock;
};
} // namespace pairwise
