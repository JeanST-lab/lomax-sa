import os

AWS_ENDPOINT = os.environ.get("AWS_ENDPOINT_URL") or None
REGION = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

DB_HOST = os.environ.get("DB_HOST", "lomax-rds-local")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "lomax")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "postgres")

# URL compuesta para psycopg2 o SQLAlchemy, generada automáticamente a partir de tus variables
DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    f"postgresql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
)

ORIGINALES_BUCKET = os.environ.get("ORIGINALES_BUCKET", "lomax-imagenes-originales")
MINIATURAS_BUCKET = os.environ.get("MINIATURAS_BUCKET", "lomax-imagenes-miniaturas")
DYNAMO_TABLE = os.environ.get("TABLE_NAME", "lomax-productos-attr")
LAMBDA_NAME = os.environ.get("LAMBDA_NAME", "lomax-procesar-imagen")

MAX_BYTES = 5 * 1024 * 1024
TIPOS_PERMITIDOS = {"image/jpeg", "image/png"}