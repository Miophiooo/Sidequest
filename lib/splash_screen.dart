import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, this.brandAsset = brandAssetPath});

  static const String brandAssetPath = 'assets/splash_brand.png';
  // Pure black matches the SQ logo PNG's baked-in background so the image
  // edges blend invisibly into the splash canvas.
  static const Color backgroundColor = Color(0xFF000000);
  static const Color navigationBarColor = Color(0xFF000000);
  static final SystemUiOverlayStyle overlayStyle = SystemUiOverlayStyle.light
      .copyWith(
        statusBarColor: backgroundColor,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: navigationBarColor,
        systemNavigationBarDividerColor: navigationBarColor,
        systemNavigationBarIconBrightness: Brightness.light,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarContrastEnforced: false,
      );

  final String brandAsset;

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(SplashScreen.overlayStyle);

    final shortestSide = MediaQuery.sizeOf(context).shortestSide;
    // 130% pushes the logo to fill nearly edge-to-edge; clamp keeps it
    // sane on tiny phones and tablets.
    final brandWidth = (shortestSide * 1.30).clamp(440.0, 760.0).toDouble();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SplashScreen.overlayStyle,
      child: ColoredBox(
        color: SplashScreen.backgroundColor,
        child: Center(
          child: RepaintBoundary(
            child: Image.asset(
              brandAsset,
              width: brandWidth,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ),
    );
  }
}
