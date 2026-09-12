export 'keyboard_io.dart' if (dart.library.js_interop) 'keyboard_web.dart';

/// Installs a window-level keydown handler so key shortcuts still work on web
/// when browser/DOM focus does not sit on Flutter's view (e.g. the spacebar
/// gets swallowed by page scrolling). The callback receives the physical key
/// `code` ("Space", "KeyF", "ArrowRight", ...) and returns true when it was
/// consumed, which suppresses the browser default action. Returns an
/// uninstall function.