// Only icons used by the current public preview are registered and bundled.
enum StudioIconAsset {
  dashboard('dashboard.svg'),
  topics('topic.svg'),
  packs('pack.svg'),
  cards('card.svg'),
  profile('profile.svg'),
  signIn('signin.svg'),
  menu('menu.svg'),
  error('error.svg'),
  offline('offline.svg');

  const StudioIconAsset(this.filename);
  final String filename;

  String get path => 'assets/icons/$filename';
}
