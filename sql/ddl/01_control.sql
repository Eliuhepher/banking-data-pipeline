CREATE SCHEMA IF NOT EXISTS control;

CREATE TABLE IF NOT EXISTS control.pipeline_run (
    run_id                 BIGINT        IDENTITY(1,1) NOT NULL,
    job_name               VARCHAR(100)  NOT NULL,
    source_name            VARCHAR(100)  NOT NULL,
    ts_inicio              TIMESTAMP     NOT NULL DEFAULT SYSDATE,
    ts_fin                 TIMESTAMP,
    watermark_inicio       TIMESTAMP,
    watermark_fin          TIMESTAMP,
    registros_leidos       INTEGER       DEFAULT 0,
    registros_validos      INTEGER       DEFAULT 0,
    registros_rechazados   INTEGER       DEFAULT 0,
    registros_insertados   INTEGER       DEFAULT 0,
    registros_actualizados INTEGER       DEFAULT 0,
    status                 VARCHAR(20)   NOT NULL DEFAULT 'RUNNING',
    error_msg              VARCHAR(2000),
    PRIMARY KEY (run_id)
)
DISTSTYLE ALL
SORTKEY (ts_inicio);

CREATE TABLE IF NOT EXISTS control.watermark (
    source_name        VARCHAR(100)  NOT NULL,
    last_processed_ts  TIMESTAMP     NOT NULL,
    updated_at         TIMESTAMP     NOT NULL DEFAULT SYSDATE,
    PRIMARY KEY (source_name)
);

-- seed inicial; ON CONFLICT garantiza idempotencia
INSERT INTO control.watermark (source_name, last_processed_ts)
VALUES ('transacciones', '2000-01-01 00:00:00')
ON CONFLICT (source_name) DO NOTHING;
