-- pruebas.sql: Verificación de restricciones (E2)
-- Lomax SA

\echo '--- PRUEBA 1: Inserción Válida ---'
INSERT INTO productos (producto_id, codigo, nombre, descripcion, precio, categoria_id, estado)
VALUES ('test-uuid-0001', 'TEST-VAL-01', 'Producto Prueba', 'Descripción válida', 99.90, 1, 'PENDIENTE');

SELECT * FROM productos WHERE codigo = 'TEST-VAL-01';

\echo '--- PRUEBA 2: Código Duplicado (Debe fallar) ---'
-- Esta sentencia debe arrojar un error de violación de restricción Unique
INSERT INTO productos (producto_id, codigo, nombre, descripcion, precio, categoria_id, estado)
VALUES ('test-uuid-0002', 'TEST-VAL-01', 'Producto Duplicado', 'Falla por código', 50.00, 1, 'PENDIENTE');

\echo '--- PRUEBA 3: Precio Negativo (Debe fallar) ---'
-- Esta sentencia debe arrojar un error por la restricción CHECK (precio >= 0)
INSERT INTO productos (producto_id, codigo, nombre, descripcion, precio, categoria_id, estado)
VALUES ('test-uuid-0003', 'TEST-NEG-01', 'Producto Negativo', 'Falla por precio negativo', -10.00, 1, 'PENDIENTE');

\echo '--- PRUEBA 4: Categoría Inexistente (Debe fallar) ---'
-- Esta sentencia debe arrojar un error de Llave Foránea (Foreign Key Violation)
INSERT INTO productos (producto_id, codigo, nombre, descripcion, precio, categoria_id, estado)
VALUES ('test-uuid-0004', 'TEST-CAT-01', 'Producto Sin Categoria', 'Falla por categoria', 100.00, 999, 'PENDIENTE');

-- Limpieza de prueba unitaria exitosa
DELETE FROM productos WHERE codigo = 'TEST-VAL-01';