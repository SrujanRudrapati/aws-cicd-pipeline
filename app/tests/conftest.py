import pytest
from webapp import create_app
from webapp.config import Config
from webapp.storage import InMemoryStore


@pytest.fixture
def config():
    return Config(version="test-sha", environment="test")


@pytest.fixture
def store():
    return InMemoryStore()


@pytest.fixture
def client(config, store):
    app = create_app(config=config, store=store)
    app.testing = True
    return app.test_client()
