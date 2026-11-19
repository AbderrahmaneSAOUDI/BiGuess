{{flutter_js}}
{{flutter_build_config}}

const studioConfig = {fontFallbackBaseUrl: '/font-fallbacks/'};
_flutter.loader.load({
  config: studioConfig,
  onEntrypointLoaded: async function(engineInitializer) {
    try {
      const appRunner = await engineInitializer.initializeEngine(studioConfig);
      await appRunner.runApp();
      document.getElementById('startup')?.remove();
    } catch (_) {
      document.getElementById('startup').textContent =
        'Studio could not start. Check that the site has finished loading, then reload the page.';
    }
  }
}).catch(() => {
  document.getElementById('startup').textContent =
    'Studio could not load. If you are offline, reconnect and reload the page.';
});
