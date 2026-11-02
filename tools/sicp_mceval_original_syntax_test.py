import unittest
from unittest import mock

import sicp_mceval_original_syntax as probe


class OriginalMetacircularSourceTest(unittest.TestCase):
    def test_original_sections_have_expected_boundaries(self):
        syntax = probe.source_forms('4.1.2')
        environment = probe.source_forms('4.1.3')
        full = probe.source_forms('full')
        self.assertEqual((len(syntax), len(environment), len(full)), (40, 19, 79))
        self.assertTrue(environment[0].startswith('(define (tagged-list?'))
        self.assertTrue(all(form in full for form in syntax + environment))

    def test_split_ignores_parentheses_in_comments_and_strings(self):
        self.assertEqual(probe.split_forms('(define x "(") ; )\n(define y 2)'),
                         ['(define x "(")', '(define y 2)'])
        with self.assertRaises(ValueError):
            probe.split_forms('(define x 2')

    def test_modified_archive_is_rejected(self):
        with mock.patch.object(probe.official, 'SHA256', '0' * 64):
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                probe.source_forms()


if __name__ == '__main__':
    unittest.main()
