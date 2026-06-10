"""
Technique 3 — Path-based [[rules.allowlists]]

The database-connection-string rule in .gitleaks.toml has:

    [[rules.allowlists]]
    description = "Exclude test files from database URL rule"
    paths = ['(^|\/)tests\/.*\.py$']

This means any postgres:// (or mysql://, mongodb://, mssql://) URL inside
tests/*.py is never flagged, even when the URL contains a password that would
fire the rule elsewhere.

The URL below is identical to a real-looking production connection string.
In a .env file it would be detected and reported. Here it is silently
suppressed because this file matches the path pattern tests/fixtures/*.py.
"""

import unittest


SUPPRESSED_DB_URL = "postgres://admin:hunter2_supersecret@db.internal:5432/myapp"


class TestDatabaseConnectionString(unittest.TestCase):

    def test_url_format_validation(self):
        url = SUPPRESSED_DB_URL
        self.assertTrue(url.startswith("postgres://"))
        self.assertIn("@db.internal", url)

    def test_mysql_url_also_suppressed(self):
        url = "mysql://user:realPassword_abc123@prod.db.company.com:3306/orders"
        self.assertIn("mysql://", url)


if __name__ == "__main__":
    unittest.main()
