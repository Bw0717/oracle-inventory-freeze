-- =============================================================
-- ITRIGGER_INV_FREEZE
-- 報工資料寫入時，若該 LOT 所屬部門處於凍結期間，
-- 將 DELIVER_SAP 設為 'Z'（暫不拋轉 SAP）。
-- 任何錯誤都只發 Teams 通知，不阻擋 INSERT。
-- =============================================================
CREATE OR REPLACE TRIGGER ITRIGGER_INV_FREEZE
BEFORE INSERT ON ZTPP_WORKTIME
FOR EACH ROW
DECLARE
    v_db    VARCHAR2(128);
    v_sql   VARCHAR2(4000);
    v_cnt   PLS_INTEGER;
    v_code  NUMBER;
    v_errm  VARCHAR2(4000);
BEGIN
    -- 1. 依 COMPANY 找 DB LINK；未設定則不處理
    BEGIN
        SELECT remark03
        INTO   v_db
        FROM   extenditem_mapping
        WHERE  class    = 'FACTORY_MAP_DBLINK'
        AND    remark02 = :NEW.COMPANY;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN;
    END;

    IF v_db IS NULL THEN
        RETURN;
    END IF;

    -- 2. 查此 LOT 所屬部門是否在生效中的凍結期間
    --    TO_DATE 包在 CASE 內，避免優化器對其他 class 的資料做日期轉換
    BEGIN
        v_db := PKG_INV_FREEZE.check_dblink(v_db);

        v_sql := 'SELECT COUNT(*)
                    FROM wip_lot' || v_db || ' lot
                   WHERE lot.lot = :1
                     AND ROWNUM  = 1
                     AND EXISTS (
                         SELECT 1
                           FROM (SELECT remark01 AS dept_id,
                                        CASE WHEN class = ''INVENTORY_FREEZE'' AND remark02 = ''Y''
                                             THEN TO_DATE(remark03, ''FXYYYYMMDDHH24MISS'') END AS start_dt,
                                        CASE WHEN class = ''INVENTORY_FREEZE'' AND remark02 = ''Y''
                                             THEN TO_DATE(remark04, ''FXYYYYMMDDHH24MISS'') END AS end_dt
                                   FROM bs_extenditem_mapping' || v_db || '
                                  WHERE class    = ''INVENTORY_FREEZE''
                                    AND remark02 = ''Y'') ex
                          WHERE ex.dept_id = lot.dept_id
                            AND SYSDATE BETWEEN ex.start_dt AND ex.end_dt)';

        EXECUTE IMMEDIATE v_sql INTO v_cnt USING :NEW.RUNCARD;
    EXCEPTION
        WHEN OTHERS THEN
            v_code := SQLCODE;
            v_errm := SQLERRM;
            P_SEND_TEAMS_MSG(
                p_group_id => PKG_INV_FREEZE.c_teams_group_id,
                p_msg      => 'ITRIGGER_INV_FREEZE 執行時，' ||
                              CASE WHEN PKG_INV_FREEZE.is_date_error(v_code)
                                   THEN v_db || ' [客製化分類設定] 開始/結束時間格式不正確'
                                   ELSE '查詢凍結設定失敗（' || v_db || '）'
                              END ||
                              '，RUNCARD=' || :NEW.RUNCARD ||
                              '，COMPANY=' || :NEW.COMPANY ||
                              '，錯誤訊息: ' || v_errm
            );
            RETURN;   -- 不擋 INSERT
    END;

    -- 3. 有凍結設定 → 標記為凍結
    IF v_cnt > 0 THEN
        :NEW.DELIVER_SAP := 'Z';
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        v_errm := SQLERRM;
        P_SEND_TEAMS_MSG(
            p_group_id => PKG_INV_FREEZE.c_teams_group_id,
            p_msg      => 'ITRIGGER_INV_FREEZE 執行時發生錯誤，RUNCARD=' || :NEW.RUNCARD ||
                          '，COMPANY=' || :NEW.COMPANY || '，錯誤訊息: ' || v_errm
        );
        -- 不擋 INSERT
END ITRIGGER_INV_FREEZE;
/
