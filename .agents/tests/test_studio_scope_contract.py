"""T27A target-vector integrity; does not exercise or certify Worker enforcement."""
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONTRACT = ROOT / 'contracts/studio/v1'


class StudioScopeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads((CONTRACT / 'fixtures.json').read_text())
        cls.cases = {case['id']: case for case in cls.fixture['cases']}
        cls.entities = {row['id']: row for row in cls.fixture['entities']}

    def test_vectors_are_unique_and_authenticity_is_not_claimed(self):
        self.assertEqual(self.fixture['status'], 'approved-contract-not-worker-proof')
        self.assertEqual(len(self.cases), len(self.fixture['cases']))
        for case in self.cases.values():
            with self.subTest(case=case['id']):
                if 'request' not in case:
                    self.assertIn(case['stage'], ('client', 'lifecycle'))
                    self.assertTrue(case['expected']['invariant'])
                    continue
                self.assertIn(case['actor'], {*self.fixture['actors'], 'anonymous'})
                self.assertTrue(case['request']['path'].startswith(
                    ('/studio/v1/', '/content/v1/studio/')))
                status = case['expected']['status']
                if status >= 400:
                    self.assertFalse(case['expected']['writes'])
                    self.assertTrue(case['expected']['code'])
                    self.assertFalse(case['expected'].get('visibleIds'))

    def test_successful_collector_projections_never_include_foreign_rows(self):
        for case in self.cases.values():
            if case.get('actor') not in ('a', 'b'):
                continue
            uid = self.fixture['actors'][case['actor']]['uid']
            for entity_id in case['expected'].get('visibleIds', []):
                with self.subTest(case=case['id'], entity=entity_id):
                    row = self.entities[entity_id]
                    if row['resourceType'] == 'topic':
                        continue
                    pack = self.entities[row['packId']] if row['resourceType'] == 'card' else row
                    self.assertEqual(pack['createdByUid'], uid)
        # An Owner-created Card remains visible through its Collector-owned Pack.
        self.assertNotEqual(self.entities['card-a']['createdByUid'], 'uid-a')
        self.assertEqual(self.cases['inherited-card-owner-differs']['expected']['status'], 200)

    def test_t24_operation_matrix_has_positive_and_negative_vectors(self):
        for kind in ('pack', 'card'):
            for action in ('create', 'update', 'hide') + (('activate',) if kind == 'card' else ()):
                for scope, status in (('own', 200), ('foreign', 404), ('owner', 200)):
                    case = self.cases[f'{kind}-{action}-{scope}']
                    self.assertEqual(case['expected']['status'], status)
                    body = case['request']['body']
                    self.assertEqual(body['protocolVersion'], 1)
                    self.assertEqual(body['operations'][0]['action'], action)
                    self.assertIn('Idempotency-Key', case['request']['headers'])
        for kind in ('topic', 'pack', 'card'):
            for action in ('softDelete', 'restore', 'permanentDelete'):
                self.assertEqual(self.cases[f'{kind}-{action}-a']['expected']['status'], 403)
                self.assertEqual(self.cases[f'{kind}-{action}-owner']['expected']['status'], 200)

    def test_regression_boundaries_have_explicit_vectors(self):
        required = {
            'identical-retry', 'changed-key', 'stale-owned', 'stale-foreign',
            'downgraded-replay', 'revoked-replay', 'replay-after-purge', 'mixed-batch',
            'spoof-creator', 'legacy-edit', 'missing-attribution', 'foreign-image-attachment',
            'cross-pack-move', 'generation-race', 'item-alias', 'alias-replay',
            'cross-uid-cursor', 'role-cursor', 'tampered-cursor', 'filter-cursor',
            'initial-concurrent-write', 'expired-page', 'history-unavailable',
            'wrong-endpoint-cursor', 'owned-removal', 'foreign-removal',
            'switch-cache', 'downgrade-cache', 'offline-first-login',
            'restore-owner-edited-pack', 'wrong-origin', 'revoked-valid-jwt',
            'private-image-foreign', 'private-image-own-disabled', 'audit-owner',
            'foreign-write-page-stable', 'own-write-page-expired',
        }
        self.assertFalse(required - self.cases.keys())
        for case_id in ('identical-retry', 'replay-after-purge'):
            self.assertFalse(self.cases[case_id]['expected']['writes'])


if __name__ == '__main__':
    unittest.main()
