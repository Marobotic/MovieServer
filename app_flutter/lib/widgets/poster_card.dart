import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';

class PosterCard extends StatelessWidget {
  final double width;
  final double aspect;
  final String? url;
  final String title;
  final VoidCallback? onTap;

  const PosterCard({
    super.key,
    required this.url,
    required this.title,
    this.width = 122,
    this.aspect = 2 / 3,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final src = context.read<Api>().assetUrl(url ?? '');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: width,
          child: AspectRatio(
            aspectRatio: aspect,
            child: src.isEmpty
                ? _placeholder()
                : Image.network(
                    src,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _placeholder(),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: const Color(0xFF262626),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(6),
      child: Text(
        title,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.grey, fontSize: 12),
      ),
    );
  }
}

class BackdropImage extends StatelessWidget {
  final String? url;
  final String title;
  final double height;

  const BackdropImage({
    super.key,
    required this.url,
    required this.title,
    this.height = 280,
  });

  @override
  Widget build(BuildContext context) {
    final src = context.read<Api>().assetUrl(url ?? '');
    if (src.isEmpty) {
      return Container(
        height: height,
        color: const Color(0xFF1F1F1F),
        alignment: Alignment.center,
        child: Text(title,
            style: const TextStyle(color: Colors.white70, fontSize: 26)),
      );
    }
    return Container(
      height: height,
      width: double.infinity,
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.network(src,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xFF141414)],
                stops: [0.4, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }
}