import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../app/studio_icon_asset.dart';

class StudioIcon extends StatelessWidget {
  const StudioIcon(this.asset, {super.key, this.size, this.color});

  final StudioIconAsset asset;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    return SvgPicture.asset(
      asset.path,
      width: size ?? theme.size ?? 20,
      height: size ?? theme.size ?? 20,
      colorFilter: ColorFilter.mode(
        color ?? theme.color ?? Theme.of(context).colorScheme.onSurface,
        BlendMode.srcIn,
      ),
      // The enclosing navigation control or status provides the accessible name.
      excludeFromSemantics: true,
    );
  }
}
