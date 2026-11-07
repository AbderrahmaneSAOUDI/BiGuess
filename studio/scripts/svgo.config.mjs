// Conservative optimization: preserve paths, colors, IDs, titles and credits.
export default {
  multipass: true,
  plugins: [
    'removeDoctype',
    'removeXMLProcInst',
    'removeMetadata',
    'cleanupAttrs',
    { name: 'inlineStyles', params: { onlyMatchedOnce: false } },
    'convertStyleToAttrs',
    'removeEmptyAttrs',
    'removeUnusedNS',
    'removeEmptyContainers',
    'removeDimensions',
    'sortAttrs',
  ],
};
