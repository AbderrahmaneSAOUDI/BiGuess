import 'studio_icon_asset.dart';

// Public navigation metadata only. These routes confer no authorization.
enum StudioRoute {
  dashboard('/dashboard', 'Dashboard', StudioIconAsset.dashboard),
  topics('/topics', 'Topics', StudioIconAsset.topics),
  myPacks('/my-packs', 'My Packs', StudioIconAsset.packs),
  cards('/cards', 'Cards', StudioIconAsset.cards),
  profile('/profile', 'Profile', StudioIconAsset.profile),
  login('/login', 'Sign in', StudioIconAsset.signIn),
  notFound('/not-found', 'Page not found', StudioIconAsset.error);

  const StudioRoute(this.path, this.label, this.icon);
  final String path;
  final String label;
  final StudioIconAsset icon;

  static const destinations = [dashboard, topics, myPacks, cards, profile];

  static StudioRoute fromUri(Uri uri) {
    if (uri.path == '/' || uri.path.isEmpty) return dashboard;
    return values.firstWhere(
      (route) => route.path == uri.path,
      orElse: () => notFound,
    );
  }
}
