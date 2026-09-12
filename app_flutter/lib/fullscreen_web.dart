import 'dart:js_interop';

@JS('document.exitFullscreen')
external JSPromise _exitFullscreen();

@JS('document.documentElement.requestFullscreen')
external JSPromise _requestFullscreen();

@JS('document.fullscreenElement')
external JSAny? _fullscreenElement();

Future<bool> toggleBrowserFullscreen() async {
  if (_fullscreenElement() == null) {
    try {
      await _requestFullscreen().toDart;
    } catch (_) {}
    return _fullscreenElement() != null;
  }
  try {
    await _exitFullscreen().toDart;
  } catch (_) {}
  return false;
}