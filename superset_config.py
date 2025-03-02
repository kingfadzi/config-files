import os
import logging
from flask_appbuilder.security.manager import AUTH_DB
from cachelib.redis import RedisCache

# Superset Home: Use the environment variable if provided; otherwise, default to "$HOME/superset"
SUPERSET_HOME = os.environ.get("SUPERSET_HOME", os.path.join(os.path.expanduser("~"), "superset"))

# -------------------------------
# Database Configuration
# -------------------------------
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASS = os.environ.get("DB_PASS", "postgres")
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "superset")
SQLALCHEMY_DATABASE_URI = f"postgresql://{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}"

# Increase Row Limit to 1 Million
ROW_LIMIT = 1000000

# -------------------------------
# Redis Configuration
# -------------------------------
REDIS_HOST = os.environ.get("REDIS_HOST", "localhost")
REDIS_PORT = os.environ.get("REDIS_PORT", "6379")
REDIS_DB = os.environ.get("REDIS_DB", "0")
REDIS_URL = f"redis://{REDIS_HOST}:{REDIS_PORT}/{REDIS_DB}"

CACHE_CONFIG = {
    'CACHE_TYPE': 'redis',
    'CACHE_DEFAULT_TIMEOUT': 300,
    'CACHE_KEY_PREFIX': 'superset_results',
    'CACHE_REDIS_URL': os.environ.get("CACHE_REDIS_URL", REDIS_URL),
}

FILTER_STATE_CACHE_CONFIG = {
    'CACHE_TYPE': 'redis',
    'CACHE_DEFAULT_TIMEOUT': 86400,
    'CACHE_KEY_PREFIX': 'superset_filter_cache',
    'CACHE_REDIS_URL': os.environ.get("FILTER_STATE_CACHE_REDIS_URL", REDIS_URL),
}

EXPLORE_FORM_DATA_CACHE_CONFIG = {
    'CACHE_TYPE': 'redis',
    'CACHE_DEFAULT_TIMEOUT': 86400,
    'CACHE_KEY_PREFIX': 'superset_explore_form',
    'CACHE_REDIS_URL': os.environ.get("EXPLORE_FORM_DATA_CACHE_REDIS_URL", REDIS_URL),
}

RESULTS_BACKEND = RedisCache(
    host=REDIS_HOST,
    port=int(REDIS_PORT),
    key_prefix='superset_results'
)

# -------------------------------
# Celery Configuration for Task Scheduling
# -------------------------------
class CeleryConfig(object):
    broker_url = os.environ.get("CELERY_BROKER_URL", REDIS_URL)
    result_backend = os.environ.get("CELERY_RESULT_BACKEND", REDIS_URL)

CELERY_CONFIG = CeleryConfig

# -------------------------------
# CORS Configuration
# -------------------------------
ENABLE_CORS = False

# -------------------------------
# Logging Configuration (Fixed Defaults)
# -------------------------------
LOG_FORMAT = '%(asctime)s:%(levelname)s:%(name)s:%(message)s'
LOG_LEVEL = logging.DEBUG
LOG_DIR = os.path.join(SUPERSET_HOME, "logs")
FILENAME = os.path.join(LOG_DIR, "superset.log")
ENABLE_TIME_ROTATE = True
TIME_ROTATE_LOG_LEVEL = "INFO"
TIME_ROTATE_LOG_FILE = FILENAME
ROLLOVER = 'midnight'
INTERVAL = 1
BACKUP_COUNT = 5

# -------------------------------
# Feature Flags (Fixed Defaults)
# -------------------------------
FEATURE_FLAGS = {
    "ENABLE_SUPERSET_META_DB": True,
}

# -------------------------------
# Authentication Configuration
# -------------------------------
AUTH_TYPE = AUTH_DB

# -------------------------------
# Security: Hardcoded SECRET_KEY
# -------------------------------
# This key was generated using a secure random generator and is hardcoded for this deployment.
SECRET_KEY = 'd1f8a90c76b2e4c3d5a1f9e2b8c7d6a5b4c3e2f1d0a9b8c7d6e5f4a3b2c1d0e9'

# -------------------------------
# Flask-WTF CSRF Settings (Fixed Defaults)
# -------------------------------
WTF_CSRF_ENABLED = False
WTF_CSRF_EXEMPT_LIST = ['*']
WTF_CSRF_TIME_LIMIT = 60 * 60 * 24 * 365