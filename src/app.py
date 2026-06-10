import os


def get_db_url() -> str:
    """Build database URL from environment variables only — never hardcode credentials."""
    host = os.environ["DB_HOST"]
    port = os.environ.get("DB_PORT", "5432")
    name = os.environ["DB_NAME"]
    return f"postgres://{host}:{port}/{name}"


def get_api_key() -> str:
    """Read API key from environment — never store in source code."""
    key = os.environ.get("API_KEY")
    if not key:
        raise ValueError("API_KEY environment variable is not set")
    return key


def main():
    print("Application started")
    print(f"DB: {get_db_url()}")


if __name__ == "__main__":
    main()
