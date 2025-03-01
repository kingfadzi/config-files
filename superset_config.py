import os
import logging
from flask_appbuilder.security.manager import AUTH_DB
from cachelib import RedisCache

SUPERSET_HOME = os.environ.get("SUPERSET_HOME", "/root/tools/superset")

# Database Configuration
SQLALCHEMY_DATABASE_URI = 'postgresql://postgres:postgres@localhost/superset'

# Increase Row Limit to 1 Million
ROW_LIMIT = 1000000

# Redis cache configuration
CACHE_CONFIG = {
    'CACHE_TYPE': 'redis',
    'CACHE_DEFAULT_TIMEOUT': 300,
    'CACHE_KEY_PREFIX': 'superset_results',
    'CACHE_REDIS_URL': 'redis://localhost:6379/0'
}

# Filter state cache configuration
FILTER_STATE_CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_DEFAULT_TIMEOUT': 86400,
    'CACHE_KEY_PREFIX': 'superset_filter_cache',
    'CACHE_REDIS_URL': 'redis://localhost:6379/0'
}

# Explore form data cache configuration
EXPLORE_FORM_DATA_CACHE_CONFIG = {
    'CACHE_TYPE': 'RedisCache',
    'CACHE_DEFAULT_TIMEOUT': 86400,
    'CACHE_KEY_PREFIX': 'superset_explore_form',
    'CACHE_REDIS_URL': 'redis://localhost:6379/0'
}

# Results backend configuration
RESULTS_BACKEND = RedisCache(
    host='localhost',
    port=6379,
    key_prefix='superset_results'
)

# Celery configuration for task scheduling
class CeleryConfig(object):
    broker_url = 'redis://localhost:6379/0'
    result_backend = 'redis://localhost:6379/0'

CELERY_CONFIG = CeleryConfig


# Disable CORS
ENABLE_CORS = False

# Logging Configuration

LOG_FORMAT = '%(asctime)s:%(levelname)s:%(name)s:%(message)s'
LOG_LEVEL = logging.DEBUG

# Enable time-based log rotation
LOG_DIR = os.path.join(SUPERSET_HOME, "logs")
FILENAME = os.path.join(LOG_DIR, "superset.log")
ENABLE_TIME_ROTATE = True
TIME_ROTATE_LOG_LEVEL = "INFO"
TIME_ROTATE_LOG_FILE = FILENAME
ROLLOVER = 'midnight'
INTERVAL = 1
BACKUP_COUNT = 5

# Feature Flags (optional, but recommended for better performance)
FEATURE_FLAGS = {
    "ENABLE_SUPERSET_META_DB": True,
}

# Authentication Configuration (using database auth in this example)
AUTH_TYPE = AUTH_DB

# Set a strong SECRET_KEY for security
SECRET_KEY = 'YOUR_SECURE_SECRET_KEY_HERE'

# Flask-WTF flag for CSRF
WTF_CSRF_ENABLED = False
WTF_CSRF_EXEMPT_LIST = ['*']
WTF_CSRF_TIME_LIMIT = 60 * 60 * 24 * 365

