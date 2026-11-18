#include "VideoCanvas.h"
#include "Protocol.h"
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QTimer>
#include <QWheelEvent>
namespace pairwise {
VideoCanvas::VideoCanvas(QWidget *parent) : QWidget(parent) {
  setFocusPolicy(Qt::StrongFocus);
  setMouseTracking(true);
  setMinimumSize(320, 200);
  setAccessibleName("Shared screen");
  clock.start();
  auto timer = new QTimer(this);
  connect(timer, &QTimer::timeout, this, [this] { update(); });
  timer->start(500);
}
void VideoCanvas::setFrame(const QImage &value) {
  image = value;
  update();
}
void VideoCanvas::setControlling(bool value) {
  controlling = value;
  update();
}
void VideoCanvas::setPointer(const QString &id, const QPointF &point,
                             bool visible, const QString &label) {
  if (visible)
    pointers[id] = {point, clock.elapsed(), label.isEmpty() ? id : label};
  else
    pointers.remove(id);
  update();
}
void VideoCanvas::clear() {
  image = {};
  pointers.clear();
  controlling = false;
  update();
}
void VideoCanvas::paintEvent(QPaintEvent *) {
  QPainter painter(this);
  painter.fillRect(rect(), QColor("#131722"));
  auto video = fittedRect(image.size(), size());
  if (image.isNull()) {
    painter.setPen(Qt::white);
    painter.drawText(rect(), Qt::AlignCenter, "Shared screens appear here");
    return;
  }
  painter.drawImage(video, image);
  for (auto i = pointers.begin(); i != pointers.end();) {
    if (clock.elapsed() - i->at > 3000) {
      i = pointers.erase(i);
      continue;
    }
    QPointF pos(video.x() + i->position.x() * video.width(),
                video.y() + i->position.y() * video.height());
    painter.setPen(Qt::white);
    painter.setBrush(QColor("#6495ff"));
    painter.drawEllipse(pos, 5, 5);
    painter.drawText(pos + QPointF(8, -6), i->label);
    ++i;
  }
  if (controlling) {
    painter.setPen(QPen(QColor("#65c991"), 3));
    painter.drawRect(rect().adjusted(2, 2, -2, -2));
  }
}
void VideoCanvas::mouseMoveEvent(QMouseEvent *e) {
  if (auto p = normalizedPoint(e->position(), image.size(), size())) {
    emit cursor(*p, true);
    if (controlling && e->buttons() != Qt::NoButton)
      emit input({{"kind", "pointer"}, {"x", p->x()}, {"y", p->y()}});
  }
}
void VideoCanvas::button(QMouseEvent *e, bool down) {
  if (!controlling)
    return;
  auto point = normalizedPoint(e->position(), image.size(), size());
  if (!point) {
    if (!down)
      emit input({{"kind", "releaseAll"}});
    return;
  }
  int code = e->button() == Qt::LeftButton     ? 0
             : e->button() == Qt::RightButton  ? 1
             : e->button() == Qt::MiddleButton ? 2
                                               : -1;
  if (code < 0)
    return;
  emit input({{"kind", "button"},
              {"code", code},
              {"down", down},
              {"x", point->x()},
              {"y", point->y()}});
}
void VideoCanvas::mousePressEvent(QMouseEvent *e) {
  setFocus(Qt::MouseFocusReason);
  button(e, true);
}
void VideoCanvas::mouseReleaseEvent(QMouseEvent *e) { button(e, false); }
void VideoCanvas::wheelEvent(QWheelEvent *e) {
  if (!controlling)
    return;
  auto p = normalizedPoint(e->position(), image.size(), size());
  if (!p)
    return;
  emit input({{"kind", "scroll"},
              {"x", p->x()},
              {"y", p->y()},
              {"deltaX", qBound(-200.0, e->angleDelta().x() / 120.0, 200.0)},
              {"deltaY", qBound(-200.0, e->angleDelta().y() / 120.0, 200.0)}});
  e->accept();
}
void VideoCanvas::key(QKeyEvent *e, bool down) {
  if (!controlling) {
    if (down)
      QWidget::keyPressEvent(e);
    else
      QWidget::keyReleaseEvent(e);
    return;
  }
  // Qt synthesizes release/press pairs while a physical key remains down.
  // Forward repeated presses, but keep the remote key held until real release.
  if (e->isAutoRepeat() && (!down || e->key() == Qt::Key_Escape)) {
    e->accept();
    return;
  }
  if (e->key() == Qt::Key_Escape && down) {
    emit unfocused();
    return;
  }
  if (e->modifiers() == Qt::ControlModifier &&
      (e->key() == Qt::Key_C || e->key() == Qt::Key_V)) {
    if (down && !e->isAutoRepeat())
      emit input({{"kind", e->key() == Qt::Key_C ? "clipboardCopy"
                                                 : "clipboardPaste"}});
    e->accept();
    return;
  }
  int key = e->key() == Qt::Key_Backtab ? Qt::Key_Tab : e->key();
  const QMap<int, int> unshift = {{Qt::Key_Exclam, Qt::Key_1},
                                  {Qt::Key_At, Qt::Key_2},
                                  {Qt::Key_NumberSign, Qt::Key_3},
                                  {Qt::Key_Dollar, Qt::Key_4},
                                  {Qt::Key_Percent, Qt::Key_5},
                                  {Qt::Key_AsciiCircum, Qt::Key_6},
                                  {Qt::Key_Ampersand, Qt::Key_7},
                                  {Qt::Key_Asterisk, Qt::Key_8},
                                  {Qt::Key_ParenLeft, Qt::Key_9},
                                  {Qt::Key_ParenRight, Qt::Key_0},
                                  {Qt::Key_Plus, Qt::Key_Equal},
                                  {Qt::Key_Underscore, Qt::Key_Minus},
                                  {Qt::Key_BraceLeft, Qt::Key_BracketLeft},
                                  {Qt::Key_BraceRight, Qt::Key_BracketRight},
                                  {Qt::Key_Bar, Qt::Key_Backslash},
                                  {Qt::Key_Colon, Qt::Key_Semicolon},
                                  {Qt::Key_QuoteDbl, Qt::Key_Apostrophe},
                                  {Qt::Key_Less, Qt::Key_Comma},
                                  {Qt::Key_Greater, Qt::Key_Period},
                                  {Qt::Key_Question, Qt::Key_Slash},
                                  {Qt::Key_AsciiTilde, Qt::Key_QuoteLeft}};
  key = unshift.value(key, key);
  auto code = macKey(key);
  const QMap<int, int> modifiers = {{Qt::Key_Control, 55},
                                    {Qt::Key_Shift, 56},
                                    {Qt::Key_Alt, 58},
                                    {Qt::Key_Meta, 59}};
  if (modifiers.contains(key))
    code = modifiers[key];
  if (code)
    emit input({{"kind", "key"},
                {"code", *code},
                {"down", down},
                {"modifiers", qint64(macModifiers(e->modifiers()))}});
  e->accept();
}
bool VideoCanvas::focusNextPrevChild(bool next) {
  // QWidget handles Tab before keyPressEvent. While controlling, let it reach
  // the wire encoder instead of moving focus and releasing the control lease.
  return controlling ? false : QWidget::focusNextPrevChild(next);
}
void VideoCanvas::keyPressEvent(QKeyEvent *e) { key(e, true); }
void VideoCanvas::keyReleaseEvent(QKeyEvent *e) { key(e, false); }
void VideoCanvas::focusOutEvent(QFocusEvent *e) {
  emit unfocused();
  QWidget::focusOutEvent(e);
}
void VideoCanvas::leaveEvent(QEvent *e) {
  emit cursor({}, false);
  QWidget::leaveEvent(e);
}
} // namespace pairwise
