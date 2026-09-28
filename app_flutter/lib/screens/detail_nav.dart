import 'package:flutter/material.dart';

import '../theme/breakpoints.dart';
import '../theme/tokens.dart';
import 'movie_detail.dart';
import 'show_detail.dart';

/// Opens a title's details the way the current layout expects: a Netflix-style
/// modal floating over the browse page on desktop, a pushed page on phones.
Future<void> openMovieDetail(BuildContext context, int id) {
  return _open(
    context,
    (modal) => MovieDetailScreen(movieId: id, modal: modal),
  );
}

Future<void> openShowDetail(BuildContext context, int id) {
  return _open(
    context,
    (modal) => ShowDetailScreen(showId: id, modal: modal),
  );
}

Future<void> _open(
    BuildContext context, Widget Function(bool modal) builder) {
  if (Breakpoints.of(context).isDesktop) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Details',
      barrierColor: AppColors.black.withOpacity(0.75),
      transitionDuration: AppMotion.medium,
      pageBuilder: (_, __, ___) => builder(true),
      transitionBuilder: (context, anim, _, child) {
        final curved =
            CurvedAnimation(parent: anim, curve: AppMotion.emphasized);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
  return Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => builder(false)));
}
