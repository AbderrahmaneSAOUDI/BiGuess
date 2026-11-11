import 'dart:convert';
import 'dart:io';

import 'package:biguess/data/repositories/legacy_manifest_content_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'T38 preserves every live T06 bundled ID/name/parent and source reference',
    () {
      final manifest =
          jsonDecode(
                File(
                  'docs/migration/evidence/t38-legacy-import/manifest.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final records = (manifest['records'] as List)
          .cast<Map<String, dynamic>>();
      final byId = {for (final row in records) row['id']: row};
      expect(records.length, 1183);
      expect(byId.length, records.length);
      final repository = LegacyManifestContentRepository();
      var cards = 0;
      var packs = 0;
      for (final topic in repository.getTopics()) {
        expect(byId[topic.id]?['resourceType'], 'topic');
        expect(byId[topic.id]?['name'], topic.name);
        for (final pack in repository.getPacksForTopic(topic.id)) {
          packs++;
          expect(byId[pack.id]?['resourceType'], 'pack');
          expect(byId[pack.id]?['name'], pack.name);
          expect(byId[pack.id]?['parentId'], topic.id);
          for (final card in repository.getCardsForPack(pack.id)) {
            cards++;
            final mapped = byId[card.id];
            expect(mapped?['resourceType'], 'card');
            expect(mapped?['parentId'], pack.id);
            expect(mapped?['name'], card.name);
            expect(mapped?['sourcePath'], card.imageReference);
            expect(mapped?['difficulty'], 1);
            expect(mapped?['provenance']['permission_to_publish'], false);
            expect(mapped?['provenance']['public_test_publishable'], false);
          }
        }
      }
      expect(repository.getTopics().length, 2);
      expect(packs, 7);
      expect(cards, 1174);
    },
  );
}
