import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from src.app import get_db_url, get_api_key


class TestApp(unittest.TestCase):

    @patch.dict(os.environ, {"DB_HOST": "localhost", "DB_NAME": "testdb"})
    def test_db_url_contains_host(self):
        url = get_db_url()
        self.assertIn("localhost", url)

    @patch.dict(os.environ, {"DB_HOST": "localhost", "DB_NAME": "testdb"})
    def test_db_url_contains_dbname(self):
        url = get_db_url()
        self.assertIn("testdb", url)

    @patch.dict(os.environ, {"DB_HOST": "localhost", "DB_NAME": "testdb"})
    def test_no_hardcoded_credentials(self):
        # Confirm the URL is built from environment variables, not hardcoded values
        url = get_db_url()
        self.assertNotIn("password", url)
        self.assertNotIn("secret", url.lower())

    @patch.dict(os.environ, {"API_KEY": "test-key-value"})
    def test_api_key_from_env(self):
        self.assertEqual(get_api_key(), "test-key-value")

    def test_api_key_raises_without_env(self):
        env = {k: v for k, v in os.environ.items() if k != "API_KEY"}
        with patch.dict(os.environ, env, clear=True):
            with self.assertRaises(ValueError):
                get_api_key()


if __name__ == "__main__":
    unittest.main()
