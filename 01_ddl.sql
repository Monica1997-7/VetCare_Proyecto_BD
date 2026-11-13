-- Proyecto Integrador · Bases de Datos II · VetCare DB
-- Equipo: Grupo 5
-- Archivo 01 de 04: tablas, llaves y restricciones
-- Corre en PostgreSQL tal cual, en orden: 01, 02, 03, 04.

-- Una sección por tabla, en el orden en que se pueden crear
-- (primero las que no tienen llaves foráneas).

-- Tabla: <nombre>
-- CREATE TABLE ...

-- Conectar a la base de datos del proyecto (si ya la creaste en postgres)
\c vetcare_db;

--Tabla: dueno
CREATE TABLE dueno (
    id_dueno SERIAL PRIMARY KEY,
    NOMBRE VARCHAR (50) NOT NULL,
    telefono VARCHAR (30) NOT NULL,
    correo VARCHAR (100),
    activa CHAR(1) DEFAULT 'S' CHECK (activa IN ('S','N'))
);

--Tabla: veterinario
CREATE TABLE veterinario(
    id_veterinario SERIAL PRIMARY KEY,
    nombre VARCHAR (50) NOT NULL,
    especialidad VARCHAR (30) CHECK (especialidad IN ('General','Dermatología','Cirugia')),
    activa CHAR(1) DEFAULT 'S' CHECK (activa IN ('S','N'));
);

--Tabla: insumo
CREATE TABLE insumo (
    id_insumo SERIAL PRIMARY KEY,
    nombre VARCHAR (50) NOT NULL,
    precio DECIMAL (12,2) NOT NULL CHECK (precio >= 0),
    stock INT NOT NULL DEFAULT 0 CHECK (stock >= 0),
    activa CHAR(1) DEFAULT 'S' CHECK (activa IN ('S','N'));

);

--Tabla: mascota
CREATE TABLE mascota (
    id_mascota SERIAL PRIMARY KEY,
    id_dueno INT NOT NULL REFERENCES dueno(id_dueno),
    nombre VARCHAR(30) NOT NULL,
    especie VARCHAR(30) NOT NULL,
    activa CHAR(1) DEFAULT 'S' CHECK (activa IN ('S','N'))
);

--Tabla: cita
CREATE TABLE cita (
    id_cita SERIAL PRIMARY KEY,
    id_mascota INT NOT NULL REFERENCES mascota(id_mascota),
    id_veterinario INT NOT NULL REFERENCES veterinario(id_veterinario),
    fecha_hora TIMESTAMP NOT NULL,
    servicio VARCHAR(50),
    estado CHAR(1) NOT NULL DEFAULT 'P' CHECK (estado IN ('P','A','C')),
    activa CHAR(1) DEFAULT 'S' CHECK (activa IN ('S','N'))
);

--Tabla: consulta
CREATE TABLE consulta (
    id_consulta SERIAL PRIMARY KEY,
    id_cita INT NOT NULL UNIQUE REFERENCES cita(id_cita),
    motivo TEXT NOT NULL,
    diagnostico VARCHAR(100),
    tratamiento VARCHAR(30),
    activa CHAR(1) DEFAULT 'S' CHECK (activa IN ('S','N'))
);

--Tabla: factura
CREATE TABLE factura (
    id_factura SERIAL PRIMARY KEY,
    id_consulta INT NOT NULL REFERENCES consulta(id_consulta),
    fecha TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    total DECIMAL(12,2) NOT NULL CHECK (total >= 0),
    activa CHAR(1) DEFAULT 'S' CHECK (activa IN ('S','N'))
);

--Tabla: detalle_factura
CREATE TABLE detalle_factura (
    id_detalle_factura SERIAL PRIMARY KEY,
    id_factura INT NOT NULL REFERENCES factura(id_factura),
    id_insumo INT NOT NULL REFERENCES insumo(id_insumo),
    cantidad INT NOT NULL CHECK (cantidad > 0),
    precio_unitario DECIMAL(12,2) NOT NULL CHECK (precio_unitario >= 0),
    activa CHAR(1) DEFAULT 'S' CHECK (activa IN ('S','N'))
);