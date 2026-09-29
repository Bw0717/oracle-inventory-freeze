-- =============================================================
-- GTT_FREEZE_LOT
-- 解除凍結時暫存「待解凍 LOT」的暫存表，交易提交後自動清空
-- =============================================================
CREATE GLOBAL TEMPORARY TABLE GTT_FREEZE_LOT (
    sap_wo        VARCHAR2(30),
    lot           VARCHAR2(30),
    dept_id       VARCHAR2(50),
    factory_name  VARCHAR2(100)
)
ON COMMIT DELETE ROWS;
