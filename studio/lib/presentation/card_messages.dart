import '../data/dataset_store.dart';

String cardFailureMessage(
  Object error,
) => switch (error is DatasetStorageFailure ? error.code : '') {
  'forbidden' || 'storage-closed' => 'This workspace no longer permits that action. Check access before retrying.',
  'card-pending-change' => 'This Card already has a different pending operation. Discard it before another action.',
  'pack-not-eligible' || 'topic-not-eligible' || 'invalid-card-state' => 'The Card or its Pack is no longer eligible. Refresh and review the dataset.',
  'card-pack-immutable' => 'A Card must stay in its original Pack.',
  'draft-conflict' || 'storage-conflict' => 'This change conflicts with newer data. Refresh and review before queueing it.',
  'invalid-draft' || 'invalid-card' =>
    'Enter a valid Card name, choose an image and a difficulty from 1 to 3.',
  'quota' || 'quota-exceeded' => 'Browser storage is full. Your inputs and last saved data are retained; free storage and retry.',
  'image-not-prepared' =>
    'Select the image again to prepare it before uploading.',
  'image-upload-unavailable' || 'image-upload-interrupted' => 'Private image upload did not complete. Your local image is retained; reconnect and retry.',
  'image-pack-unavailable' => 'This Pack is no longer available for image upload. Refresh and check access.',
  'image-quota' => 'The private image quota has been reached. Keep this local draft and contact the Owner.',
  'image-upload-busy' => 'Other private image uploads are in progress. Your local image is retained; retry shortly.',
  'image-too-large' || 'image-rejected' || 'invalid-image-receipt' => 'The server could not validate this prepared image. Your local image is retained; select it again or contact the Owner.',
  'cancelled' => 'Image upload cancelled. Your local draft is retained.',
  _ => 'Could not save locally. Your inputs and last saved data are retained; check browser storage and retry.',
};
