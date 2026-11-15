-- ============================================================================
-- Proyecto Integrador · Bases de Datos II · VetCare DB
-- Equipo: Grupo 5
-- Archivo 01 de 04: tablas, llaves y restricciones
-- Motor: PostgreSQL 14 o superior (probado en PostgreSQL 18)
-- ----------------------------------------------------------------------------
-- Ejecutar conectado a la base del proyecto, en orden: 01, 02, 03, 04.
--   createdb vetcare_db
--   psql -U postgres -d vetcare_db -f 01_ddl.sql
--
-- Convenciones del curso:
--   * Identificadores en minuscula, singular y sin tildes.
--   * Claves sustitutas con el patron id_<entidad>.
--   * Dinero DECIMAL(12,2), fechas TIMESTAMP, telefonos VARCHAR(30).
--   * Nada se borra: toda tabla tiene la columna activa ('S'/'N').
-- ============================================================================

-- Si se necesita reinstalar desde cero, descomentar esta linea:
-- DROP TABLE IF EXISTS auditoria, detalle_factura, factura, consulta, cita, mascota, insumo, veterinario, dueno CASCADE;

-- Si se usa psql y la base aun no esta seleccionada, descomentar:
-- \c vetcare_db

-- ============================================================================
-- 1. dueno: persona a la que se le factura. Un dueno puede tener varias mascotas.
-- ============================================================================
CREATE TABLE dueno (
    id_dueno SERIAL PRIMARY KEY,
    nombre   VARCHAR(50)  NOT NULL,
    telefono VARCHAR(30)  NOT NULL,
    correo   VARCHAR(100),
    activa   CHAR(1)      NOT NULL DEFAULT 'S' CHECK (activa IN ('S','N')),
    -- El correo es opcional, pero si se registra debe tener forma de correo.
    CONSTRAINT ck_dueno_correo
        CHECK (correo IS NULL OR correo ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);

-- ============================================================================
-- 2. veterinario: quien atiende. Tiene especialidad y agenda propia.
-- ============================================================================
CREATE TABLE veterinario (
    id_veterinario SERIAL PRIMARY KEY,
    nombre         VARCHAR(50) NOT NULL,
    especialidad   VARCHAR(30) NOT NULL
        CHECK (especialidad IN ('General','Dermatologia','Cirugia')),
    activa         CHAR(1) NOT NULL DEFAULT 'S' CHECK (activa IN ('S','N'))
);

-- ============================================================================
-- 3. insumo: medicamentos y materiales. Se descuentan al facturar.
--    El CHECK (stock >= 0) es la ultima defensa de la regla
--    "el stock de un insumo nunca queda negativo".
-- ============================================================================
CREATE TABLE insumo (
    id_insumo SERIAL PRIMARY KEY,
    nombre    VARCHAR(50)   NOT NULL,
    precio    DECIMAL(12,2) NOT NULL CHECK (precio >= 0),
    stock     INT           NOT NULL DEFAULT 0 CHECK (stock >= 0),
    activa    CHAR(1)       NOT NULL DEFAULT 'S' CHECK (activa IN ('S','N'))
);

-- ============================================================================
-- 4. mascota: el paciente. Pertenece a un dueno y puede quedar inactiva
--    sin que se borre su historial.
-- ============================================================================
CREATE TABLE mascota (
    id_mascota SERIAL PRIMARY KEY,
    id_dueno   INT         NOT NULL REFERENCES dueno(id_dueno),
    nombre     VARCHAR(30) NOT NULL,
    especie    VARCHAR(30) NOT NULL
        CHECK (especie IN ('Perro','Gato','Ave','Conejo','Otro')),
    activa     CHAR(1) NOT NULL DEFAULT 'S' CHECK (activa IN ('S','N'))
);

-- ============================================================================
-- 5. cita: espacio reservado (mascota + veterinario + fecha/hora + estado).
--    estado: P = Pendiente, A = Atendida, C = Cancelada.
--    Cancelar nunca borra la fila: solo cambia el estado a 'C'.
-- ============================================================================
CREATE TABLE cita (
    id_cita       SERIAL PRIMARY KEY,
    id_mascota    INT       NOT NULL REFERENCES mascota(id_mascota),
    id_veterinario INT      NOT NULL REFERENCES veterinario(id_veterinario),
    fecha_hora    TIMESTAMP NOT NULL,
    servicio      VARCHAR(50) NOT NULL
        CHECK (servicio IN ('Revision','Desparasitacion')),
    estado        CHAR(1)   NOT NULL DEFAULT 'P' CHECK (estado IN ('P','A','C')),
    activa        CHAR(1)   NOT NULL DEFAULT 'S' CHECK (activa IN ('S','N'))
);

-- Un veterinario no puede tener dos citas vigentes a la misma hora.
-- Es un indice unico PARCIAL: las citas canceladas liberan la franja.
-- Ademas de la validacion del procedimiento, protege ante dos
-- recepcionistas agendando al mismo tiempo (Clase 10).
CREATE UNIQUE INDEX ux_cita_agenda_vigente
    ON cita (id_veterinario, fecha_hora)
    WHERE estado IN ('P','A') AND activa = 'S';

-- ============================================================================
-- 6. consulta: lo que ocurrio en una cita atendida. No existe sin su cita.
-- ============================================================================
CREATE TABLE consulta (
    id_consulta SERIAL PRIMARY KEY,
    id_cita     INT NOT NULL UNIQUE REFERENCES cita(id_cita),
    motivo      TEXT NOT NULL,
    diagnostico VARCHAR(200),
    tratamiento VARCHAR(200),
    activa      CHAR(1) NOT NULL DEFAULT 'S' CHECK (activa IN ('S','N'))
);

-- ============================================================================
-- 7. factura: cobro de una consulta. El total se mantiene con la suma de
--    sus lineas activas (lo recalcula el disparador del archivo 03).
-- ============================================================================
CREATE TABLE factura (
    id_factura  SERIAL PRIMARY KEY,
    id_consulta INT           NOT NULL REFERENCES consulta(id_consulta),
    fecha       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    total       DECIMAL(12,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
    activa      CHAR(1)       NOT NULL DEFAULT 'S' CHECK (activa IN ('S','N'))
);

-- ============================================================================
-- 8. detalle_factura: cada linea de la factura.
--    Guarda el precio_unitario del dia de la venta (precio historico).
-- ============================================================================
CREATE TABLE detalle_factura (
    id_detalle_factura SERIAL PRIMARY KEY,
    id_factura    INT           NOT NULL REFERENCES factura(id_factura),
    id_insumo     INT           NOT NULL REFERENCES insumo(id_insumo),
    cantidad      INT           NOT NULL CHECK (cantidad > 0),
    precio_unitario DECIMAL(12,2) NOT NULL CHECK (precio_unitario >= 0),
    activa        CHAR(1)       NOT NULL DEFAULT 'S' CHECK (activa IN ('S','N')),
    -- Un insumo aparece una sola vez por factura; si hay mas unidades,
    -- se aumenta la cantidad de esa linea.
    CONSTRAINT uq_detalle_factura_insumo UNIQUE (id_factura, id_insumo)
);

-- ============================================================================
-- 9. auditoria: tabla de apoyo (no es una de las 8 entidades del caso).
--    Guarda quien cambio que, cuando y con que valores. Es la evidencia de
--    la regla "todo cambio sensible queda auditado" (precios y cancelaciones).
--    No se otorgan privilegios de escritura a ningun rol: solo escriben los
--    disparadores, que corren con privilegios del dueno de la tabla.
-- ============================================================================
CREATE TABLE auditoria (
    id_auditoria      BIGSERIAL PRIMARY KEY,
    tabla             VARCHAR(50) NOT NULL,
    operacion         VARCHAR(10) NOT NULL
        CHECK (operacion IN ('INSERT','UPDATE','DELETE')),
    id_registro       INT,
    usuario           VARCHAR(100) NOT NULL DEFAULT CURRENT_USER,
    fecha_hora        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    motivo            VARCHAR(200),
    descripcion       TEXT,
    datos_anteriores  JSONB,
    datos_nuevos      JSONB,
    activa            CHAR(1) NOT NULL DEFAULT 'S' CHECK (activa IN ('S','N'))
);

-- ============================================================================
-- 10. Indices para llaves foraneas y consultas frecuentes.
--     (PostgreSQL no crea indices automaticos para las FK.)
-- ============================================================================
CREATE INDEX ix_mascota_dueno          ON mascota (id_dueno);
CREATE INDEX ix_cita_mascota_fecha     ON cita (id_mascota, fecha_hora);
CREATE INDEX ix_factura_consulta       ON factura (id_consulta);
CREATE INDEX ix_detalle_factura_insumo ON detalle_factura (id_insumo);
CREATE INDEX ix_auditoria_tabla_fecha  ON auditoria (tabla, fecha_hora DESC);

-- ============================================================================
-- 11. Documentacion de las tablas (visible en pgAdmin / \d+).
-- ============================================================================
COMMENT ON TABLE dueno        IS 'Persona a la que se le factura; puede tener varias mascotas.';
COMMENT ON TABLE mascota      IS 'Paciente de la clinica; se inactiva, nunca se borra.';
COMMENT ON TABLE veterinario  IS 'Profesional que atiende; tiene especialidad y agenda.';
COMMENT ON TABLE cita         IS 'Espacio reservado. estado: P pendiente, A atendida, C cancelada.';
COMMENT ON TABLE consulta     IS 'Resultado de una cita atendida; una sola consulta por cita.';
COMMENT ON TABLE insumo       IS 'Medicamentos y materiales con precio y stock.';
COMMENT ON TABLE factura      IS 'Cobro de una consulta; total = suma de sus lineas activas.';
COMMENT ON TABLE detalle_factura IS 'Linea de factura con el precio unitario del dia de la venta.';
COMMENT ON TABLE auditoria    IS 'Rastro de cambios sensibles: precios y cancelaciones de citas.';

COMMENT ON COLUMN cita.estado      IS 'P = pendiente, A = atendida, C = cancelada.';
COMMENT ON COLUMN factura.total    IS 'Se recalcula desde detalle_factura mediante disparador.';
COMMENT ON COLUMN auditoria.usuario IS 'Usuario de base de datos que provoco el cambio.';

-- ============================================================================
-- 12. Datos de prueba con el elenco fijo del anexo del caso.
--     6 duenos, 8 mascotas (2 inactivas), 4 veterinarios y 10 citas.
--     Se usa una transaccion: o se cargan todos los datos o ninguno.
-- ============================================================================
BEGIN;

INSERT INTO dueno (id_dueno, nombre, telefono, correo, activa) VALUES
    (1, 'Ana Gomez',      '+57 300 123 4567', 'ana.gomez@correo.com',      'S'),
    (2, 'Carlos Ruiz',    '+57 301 234 5678', 'carlos.ruiz@correo.com',    'S'),
    (3, 'Laura Restrepo', '+57 302 345 6789', 'laura.restrepo@correo.com', 'S'),
    (4, 'Luisa Cardona',  '+57 303 456 7890', 'luisa.cardona@correo.com',  'S'),
    (5, 'Marcela Diaz',   '+57 304 567 8901', 'marcela.diaz@correo.com',   'S'),
    (6, 'Paula Salazar',  '+57 305 678 9012', 'paula.salazar@correo.com',  'S');

INSERT INTO mascota (id_mascota, id_dueno, nombre, especie, activa) VALUES
    (1, 1, 'Luna',    'Perro', 'S'),
    (2, 2, 'Firulais','Perro', 'S'),
    (3, 3, 'Rocky',   'Perro', 'N'),   -- inactiva: no admite citas nuevas
    (4, 4, 'Toby',    'Perro', 'S'),
    (5, 5, 'Mishi',   'Gato',  'S'),
    (6, 6, 'Nube',    'Gato',  'S'),
    (7, 1, 'Bobby',   'Perro', 'S'),   -- Ana tiene dos mascotas
    (8, 2, 'Kiara',   'Gato',  'N');   -- inactiva: no admite citas nuevas

INSERT INTO veterinario (id_veterinario, nombre, especialidad, activa) VALUES
    (1, 'Andres Vallejo', 'General',     'S'),
    (2, 'Diego Moreno',   'Dermatologia', 'S'),
    (3, 'Ivan Ortiz',     'Cirugia',      'S'),
    (4, 'Jorge Pineda',   'General',      'S');

-- Citas historicas (julio de 2026) y dos citas futuras pendientes,
-- calculadas desde la fecha de instalacion para que siempre sean futuras.
INSERT INTO cita (id_cita, id_mascota, id_veterinario, fecha_hora, servicio, estado, activa) VALUES
    (1, 1, 1, '2026-07-02 09:00:00', 'Revision',        'A', 'S'),
    (2, 2, 2, '2026-07-02 10:00:00', 'Desparasitacion', 'A', 'S'),
    (3, 4, 3, '2026-07-03 11:00:00', 'Revision',        'A', 'S'),
    (4, 5, 4, '2026-07-03 14:00:00', 'Revision',        'A', 'S'),
    (5, 6, 1, '2026-07-06 08:30:00', 'Desparasitacion', 'A', 'S'),
    (6, 7, 2, '2026-07-06 10:30:00', 'Revision',        'A', 'S'),
    (7, 1, 3, '2026-07-10 09:30:00', 'Revision',        'C', 'S'),
    (8, 4, 4, '2026-07-10 15:00:00', 'Desparasitacion', 'A', 'S'),
    (9, 1, 1, (CURRENT_DATE + 3) + TIME '09:00', 'Revision',        'P', 'S'),
    (10, 2, 2, (CURRENT_DATE + 4) + TIME '10:00', 'Desparasitacion', 'P', 'S');

-- Consultas de las citas atendidas (una por cita).
INSERT INTO consulta (id_consulta, id_cita, motivo, diagnostico, tratamiento, activa) VALUES
    (1, 1, 'Revision de rutina',        'Paciente sana',              'Vacuna antirrabica',      'S'),
    (2, 2, 'Picazon en la piel',        'Dermatitis leve',            'Shampoo medicado',        'S'),
    (3, 3, 'Cojera de la pata derecha','Esguince leve',              'Reposo por 7 dias',       'S'),
    (4, 4, 'Control anual',             'Paciente sana',              'Ninguno',                 'S'),
    (5, 5, 'Desparasitacion',           'Presencia de parasitos',     'Desparasitante canino',   'S'),
    (6, 6, 'Tos seca',                  'Bronquitis leve',            'Jarabe pediatrico',       'S'),
    (7, 8, 'Vacunacion',                'Paciente sana',              'Vacuna antirrabica',      'S');

INSERT INTO insumo (id_insumo, nombre, precio, stock, activa) VALUES
    (1, 'Vacuna antirrabica',     45000.00, 28, 'S'),
    (2, 'Desparasitante canino',  28000.00, 38, 'S'),
    (3, 'Alimento premium 3 kg',  65000.00, 12, 'S'),
    (4, 'Jeringa 5 ml',            1500.00, 198, 'S'),
    (5, 'Shampoo medicado',       32000.00, 7,  'S');
-- Nota: el stock sembrado YA descuenta las lineas de las facturas de ejemplo
-- (2 vacunas, 2 desparasitantes, 2 jeringas y 1 shampoo). Asi los datos
-- quedan consistentes aunque los disparadores se creen despues, en el 03.

-- Facturas de ejemplo; su total coincide con la suma de sus lineas.
INSERT INTO factura (id_factura, id_consulta, fecha, total, activa) VALUES
    (1, 1, '2026-07-02 10:00:00', 121000.00, 'S'),
    (2, 5, '2026-07-06 09:30:00',  60000.00, 'S');

INSERT INTO detalle_factura (id_detalle_factura, id_factura, id_insumo, cantidad, precio_unitario, activa) VALUES
    (1, 1, 1, 2, 45000.00, 'S'),
    (2, 1, 2, 1, 28000.00, 'S'),
    (3, 1, 4, 2,  1500.00, 'S'),
    (4, 2, 2, 1, 28000.00, 'S'),
    (5, 2, 5, 1, 32000.00, 'S');

-- Ajustar las secuencias a los identificadores sembrados; si no, el primer
-- INSERT sin id explicito intentaria reutilizar el id 1 y fallaria.
SELECT setval(pg_get_serial_sequence('dueno',           'id_dueno'),           (SELECT MAX(id_dueno)           FROM dueno));
SELECT setval(pg_get_serial_sequence('mascota',         'id_mascota'),         (SELECT MAX(id_mascota)         FROM mascota));
SELECT setval(pg_get_serial_sequence('veterinario',     'id_veterinario'),     (SELECT MAX(id_veterinario)     FROM veterinario));
SELECT setval(pg_get_serial_sequence('cita',            'id_cita'),            (SELECT MAX(id_cita)            FROM cita));
SELECT setval(pg_get_serial_sequence('consulta',        'id_consulta'),        (SELECT MAX(id_consulta)        FROM consulta));
SELECT setval(pg_get_serial_sequence('insumo',          'id_insumo'),          (SELECT MAX(id_insumo)          FROM insumo));
SELECT setval(pg_get_serial_sequence('factura',         'id_factura'),         (SELECT MAX(id_factura)         FROM factura));
SELECT setval(pg_get_serial_sequence('detalle_factura', 'id_detalle_factura'), (SELECT MAX(id_detalle_factura) FROM detalle_factura));

COMMIT;
