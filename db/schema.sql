-- schema.sql: Modelo relacional para RDS (PostgreSQL)
-- Lomax SA - Etapa 2

DROP TABLE IF EXISTS productos CASCADE;
DROP TABLE IF EXISTS categorias CASCADE;

-- Tabla de Categorías
CREATE TABLE categorias (
    categoria_id SERIAL PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL UNIQUE,
    descripcion TEXT
);

-- Tabla de Productos (RDS)
CREATE TABLE productos (
    producto_id VARCHAR(36) PRIMARY KEY, -- UUID compartido con DynamoDB
    codigo VARCHAR(50) NOT NULL UNIQUE,
    nombre VARCHAR(150) NOT NULL,
    descripcion TEXT,
    precio DECIMAL(10, 2) NOT NULL CHECK (precio >= 0),
    categoria_id INT NOT NULL,
    fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    estado VARCHAR(20) NOT NULL DEFAULT 'PENDIENTE' CHECK (estado IN ('PENDIENTE', 'PUBLICADO')),
    FOREIGN KEY (categoria_id) REFERENCES categorias(categoria_id) ON DELETE RESTRICT
);

-- Índices para mejorar la búsqueda en consultas del catálogo
CREATE INDEX idx_productos_categoria ON productos(categoria_id);
CREATE INDEX idx_productos_estado ON productos(estado);