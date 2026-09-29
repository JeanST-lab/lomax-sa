import psycopg2
import psycopg2.errors
from psycopg2.extras import RealDictCursor

from . import config
from .errores import ErrorPaso


class CodigoDuplicado(Exception):
    pass


def _ejecutar(sql, params=(), fetch=None):
    try:
        conn = psycopg2.connect(
            host=config.DB_HOST, port=config.DB_PORT, dbname=config.DB_NAME,
            user=config.DB_USER, password=config.DB_PASSWORD, connect_timeout=5,
        )
    except psycopg2.Error as e:
        raise ErrorPaso(503, "rds", f"No se pudo conectar a RDS: {str(e).strip()}")
    try:
        with conn:  # commit al salir bien, rollback si hay excepcion
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(sql, params)
                if fetch == "all":
                    return cur.fetchall()
                if fetch == "one":
                    return cur.fetchone()
                return cur.rowcount
    except psycopg2.errors.UniqueViolation as e:
        raise CodigoDuplicado(str(e))
    except psycopg2.OperationalError as e:
        raise ErrorPaso(503, "rds", str(e).strip())
    except psycopg2.Error as e:
        raise ErrorPaso(502, "rds", str(e).strip())
    finally:
        conn.close()


def listar_categorias():
    filas = _ejecutar(
        "SELECT categoria_id, nombre, descripcion FROM categorias ORDER BY categoria_id",
        fetch="all",
    )
    return [dict(f) for f in filas]


def categoria_existe(categoria_id):
    return _ejecutar(
        "SELECT 1 AS x FROM categorias WHERE categoria_id = %s", (categoria_id,), "one"
    ) is not None


def insertar_producto(producto_id, p):
    _ejecutar(
        """INSERT INTO productos
           (producto_id, codigo, nombre, descripcion, precio, categoria_id, estado)
           VALUES (%s, %s, %s, %s, %s, %s, 'PENDIENTE')""",
        (producto_id, p.codigo, p.nombre, p.descripcion, p.precio, p.categoria_id),
    )


def obtener_producto(producto_id):
    fila = _ejecutar("SELECT * FROM productos WHERE producto_id = %s", (producto_id,), "one")
    return dict(fila) if fila else None


def listar_publicados():
    filas = _ejecutar(
        "SELECT * FROM productos WHERE estado = 'PUBLICADO' ORDER BY fecha, codigo",
        fetch="all",
    )
    return [dict(f) for f in filas]


def marcar_publicado(producto_id):
    return _ejecutar(
        "UPDATE productos SET estado = 'PUBLICADO' WHERE producto_id = %s", (producto_id,)
    )
