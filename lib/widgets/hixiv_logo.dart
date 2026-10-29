import 'package:flutter/material.dart';

class HixivLogo extends StatelessWidget {
  const HixivLogo({super.key, this.size = 36});

  static const String asset = 'assets/branding/hixiv_logo.png';

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
        asset,
        width: size,
        height: size,
        filterQuality: FilterQuality.medium,
        semanticLabel: 'Hixiv',
      );
}
