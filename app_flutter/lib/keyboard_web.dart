import 'dart:js_interop';

extension _KeyboardEvent on JSObject {
  @JS('code')
  external String? get code;

  @JS('repeat')
  external bool get repeat;

  @JS('preventDefault')
  external void preventDefault();
}

void Function() installWebKeyHandler(bool Function(String code) handler) {
  final listener = ((JSAny event) {
    final ev = event as JSObject;
    final code = ev.code;
    if (code == null || ev.repeat) return;
    if (!handler(code)) return;
    ev.preventDefault();
  }).toJS;
  _windowAddEventListener('keydown', listener);
  return () => _windowRemoveEventListener('keydown', listener);
}

@JS('window.addEventListener')
external void _windowAddEventListener(String type, JSFunction listener);

@JS('window.removeEventListener')
external void _windowRemoveEventListener(String type, JSFunction listener);