-- -------------------------------------------------------------------------
-- fact_transacciones
-- DISTKEY(sk_cliente): coloca fact junto a dim_cliente en el mismo nodo
-- SORTKEY(sk_tiempo, fecha_hora): optimiza filtros temporales y ordenamiento
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.fact_transacciones (
    sk_transaccion    BIGINT         IDENTITY(1,1) NOT NULL,
    sk_cliente        BIGINT         NOT NULL,
    sk_producto       INTEGER        NOT NULL,
    sk_tiempo         INTEGER        NOT NULL,
    numero_de_cuenta  VARCHAR(50)    NOT NULL,
    tipo_transaccion  VARCHAR(30)    NOT NULL,
    monto_transaccion DECIMAL(18,2)  NOT NULL,
    fecha_hora        TIMESTAMP      NOT NULL,
    PRIMARY KEY (sk_transaccion),
    FOREIGN KEY (sk_cliente)  REFERENCES dw.dim_cliente(sk_cliente),
    FOREIGN KEY (sk_producto) REFERENCES dw.dim_producto(sk_producto),
    FOREIGN KEY (sk_tiempo)   REFERENCES dw.dim_tiempo(sk_tiempo)
)
DISTKEY (sk_cliente)
SORTKEY (sk_tiempo, fecha_hora);

-- -------------------------------------------------------------------------
-- stg_fact_transacciones
-- Contiene claves naturales; el INSERT final resuelve las SKs via JOIN
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.stg_fact_transacciones (
    tipo_de_identificacion    VARCHAR(10)    NOT NULL,
    numero_de_identificacion  BIGINT         NOT NULL,
    tipo_de_producto          VARCHAR(50)    NOT NULL,
    numero_de_cuenta          VARCHAR(50)    NOT NULL,
    tipo_transaccion          VARCHAR(30)    NOT NULL,
    monto_transaccion         DECIMAL(18,2)  NOT NULL,
    fecha_hora                TIMESTAMP      NOT NULL
)
DISTSTYLE ALL;

-- -------------------------------------------------------------------------
-- Merge SCD2 dim_cliente (ejecutado por silver_to_gold vía Redshift Data API)
-- Se invoca después de COPY dw.stg_dim_cliente FROM S3
-- -------------------------------------------------------------------------

-- 1. Cerrar registros activos cuyo hash cambió
-- UPDATE dw.dim_cliente dc
-- SET
--     fecha_fin = stg.fecha_inicio - INTERVAL '1 second',
--     es_activo = FALSE
-- FROM dw.stg_dim_cliente stg
-- WHERE dc.numero_de_identificacion = stg.numero_de_identificacion
--   AND dc.tipo_de_identificacion   = stg.tipo_de_identificacion
--   AND dc.es_activo = TRUE
--   AND dc.row_hash != stg.row_hash;

-- 2. Insertar registros nuevos o cambiados
-- INSERT INTO dw.dim_cliente (
--     tipo_de_identificacion, numero_de_identificacion, nombres, ciudad,
--     direccion_cliente, telefono_cliente, correo_cliente, fecha_de_nacimiento,
--     reporte_centrales_riesgo, monto_reporte_riesgo, tiempo_mora_dias,
--     row_hash, fecha_inicio, fecha_fin, es_activo
-- )
-- SELECT
--     stg.tipo_de_identificacion, stg.numero_de_identificacion, stg.nombres, stg.ciudad,
--     stg.direccion_cliente, stg.telefono_cliente, stg.correo_cliente, stg.fecha_de_nacimiento,
--     stg.reporte_centrales_riesgo, stg.monto_reporte_riesgo, stg.tiempo_mora_dias,
--     stg.row_hash, stg.fecha_inicio, NULL, TRUE
-- FROM dw.stg_dim_cliente stg
-- WHERE NOT EXISTS (
--     SELECT 1 FROM dw.dim_cliente dc
--     WHERE dc.numero_de_identificacion = stg.numero_de_identificacion
--       AND dc.tipo_de_identificacion   = stg.tipo_de_identificacion
--       AND dc.es_activo = TRUE
--       AND dc.row_hash  = stg.row_hash
-- );

-- 3. Insertar fact resolviendo SKs desde dimensiones
-- INSERT INTO dw.fact_transacciones (sk_cliente, sk_producto, sk_tiempo, numero_de_cuenta, tipo_transaccion, monto_transaccion, fecha_hora)
-- SELECT
--     c.sk_cliente,
--     p.sk_producto,
--     CAST(TO_CHAR(f.fecha_hora, 'YYYYMMDD') AS INTEGER) AS sk_tiempo,
--     f.numero_de_cuenta,
--     f.tipo_transaccion,
--     f.monto_transaccion,
--     f.fecha_hora
-- FROM dw.stg_fact_transacciones f
-- JOIN dw.dim_cliente c
--     ON  c.numero_de_identificacion = f.numero_de_identificacion
--     AND c.tipo_de_identificacion   = f.tipo_de_identificacion
--     AND c.es_activo = TRUE
-- JOIN dw.dim_producto p
--     ON p.tipo_de_producto = f.tipo_de_producto;
