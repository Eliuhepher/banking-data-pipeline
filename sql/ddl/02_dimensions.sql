CREATE SCHEMA IF NOT EXISTS dw;

-- -------------------------------------------------------------------------
-- dim_tiempo  (sk = YYYYMMDD como entero)
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.dim_tiempo (
    sk_tiempo        INTEGER      NOT NULL,
    fecha            DATE         NOT NULL,
    anio             SMALLINT     NOT NULL,
    mes              SMALLINT     NOT NULL,
    dia              SMALLINT     NOT NULL,
    trimestre        SMALLINT     NOT NULL,
    nombre_mes       VARCHAR(20)  NOT NULL,
    dia_semana       VARCHAR(20)  NOT NULL,
    es_fin_de_semana BOOLEAN      NOT NULL DEFAULT FALSE,
    PRIMARY KEY (sk_tiempo)
)
DISTSTYLE ALL
SORTKEY (fecha);

-- -------------------------------------------------------------------------
-- dim_producto
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.dim_producto (
    sk_producto      INTEGER      IDENTITY(1,1) NOT NULL,
    tipo_de_producto VARCHAR(50)  NOT NULL,
    PRIMARY KEY (sk_producto)
)
DISTSTYLE ALL;

-- -------------------------------------------------------------------------
-- dim_cliente  (SCD Tipo 2)
-- row_hash: SHA-256 de atributos rastreados; detecta cambios sin comparar
-- campo por campo
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.dim_cliente (
    sk_cliente                   BIGINT        IDENTITY(1,1) NOT NULL,
    tipo_de_identificacion       VARCHAR(10)   NOT NULL,
    numero_de_identificacion     BIGINT        NOT NULL,
    nombres                      VARCHAR(200)  NOT NULL,
    ciudad                       VARCHAR(100),
    direccion_cliente            VARCHAR(300),
    telefono_cliente             VARCHAR(20),
    correo_cliente               VARCHAR(200),
    fecha_de_nacimiento          DATE,
    reporte_centrales_riesgo     BOOLEAN       NOT NULL DEFAULT FALSE,
    monto_reporte_riesgo         DECIMAL(18,2),
    tiempo_mora_dias             INTEGER,
    row_hash                     VARCHAR(64)   NOT NULL,
    fecha_inicio                 TIMESTAMP     NOT NULL,
    fecha_fin                    TIMESTAMP,
    es_activo                    BOOLEAN       NOT NULL DEFAULT TRUE,
    PRIMARY KEY (sk_cliente)
)
DISTSTYLE ALL
SORTKEY (numero_de_identificacion, fecha_inicio);

-- -------------------------------------------------------------------------
-- stg_dim_cliente  (staging para el merge SCD2 en silver_to_gold)
-- se trunca en cada ejecución antes del COPY
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.stg_dim_cliente (
    tipo_de_identificacion       VARCHAR(10)   NOT NULL,
    numero_de_identificacion     BIGINT        NOT NULL,
    nombres                      VARCHAR(200)  NOT NULL,
    ciudad                       VARCHAR(100),
    direccion_cliente            VARCHAR(300),
    telefono_cliente             VARCHAR(20),
    correo_cliente               VARCHAR(200),
    fecha_de_nacimiento          DATE,
    reporte_centrales_riesgo     BOOLEAN       NOT NULL DEFAULT FALSE,
    monto_reporte_riesgo         DECIMAL(18,2),
    tiempo_mora_dias             INTEGER,
    row_hash                     VARCHAR(64)   NOT NULL,
    fecha_inicio                 TIMESTAMP     NOT NULL
)
DISTSTYLE ALL;

-- -------------------------------------------------------------------------
-- stg_dim_producto  (staging para nuevos tipos de producto)
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.stg_dim_producto (
    tipo_de_producto  VARCHAR(50)  NOT NULL
)
DISTSTYLE ALL;

-- -------------------------------------------------------------------------
-- stg_dim_tiempo  (staging para nuevas fechas)
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.stg_dim_tiempo (
    sk_tiempo        INTEGER      NOT NULL,
    fecha            DATE         NOT NULL,
    anio             SMALLINT     NOT NULL,
    mes              SMALLINT     NOT NULL,
    dia              SMALLINT     NOT NULL,
    trimestre        SMALLINT     NOT NULL,
    nombre_mes       VARCHAR(20)  NOT NULL,
    dia_semana       VARCHAR(20)  NOT NULL,
    es_fin_de_semana BOOLEAN      NOT NULL DEFAULT FALSE
)
DISTSTYLE ALL;
