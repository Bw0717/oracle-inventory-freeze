-- =============================================================
-- P_RELEASE_EXPIRED_FREEZE
-- 將凍結期間已結束的報工資料 DELIVER_SAP 由 'Z' 改回 'N'。
--
-- 解凍條件（同時成立）：
--   1. LOT 所屬部門有「已到期」且「解凍模式符合」的凍結設定
--   2. LOT 所屬部門沒有任何「生效中」的凍結設定
--
-- 模式：
--   自動（排程）：單一廠區失敗 → 發 Teams 後略過，繼續處理其他廠區
--   手動（UI）  ：任一廠區失敗 → 整批 ROLLBACK 並回傳錯誤碼
-- =============================================================
CREATE OR REPLACE PROCEDURE P_RELEASE_EXPIRED_FREEZE (
    IN_MODE         IN  VARCHAR2 DEFAULT NULL,   -- '自動' / '手動'，NULL 視為 '自動'
    IN_FACTORY      IN  VARCHAR2 DEFAULT NULL,   -- NULL = 全部廠區
    IN_DEPT         IN  VARCHAR2 DEFAULT NULL,   -- NULL = 全部部門
    OUT_MSG_CODE    OUT VARCHAR2,
    OUT_MSG_RESULT  OUT VARCHAR2
)
IS
    PRAGMA AUTONOMOUS_TRANSACTION;

    TYPE t_db_rec IS RECORD (
        factory_name  VARCHAR2(100),
        db_link       VARCHAR2(128)
    );
    TYPE t_db_tab IS TABLE OF t_db_rec;

    v_mode      VARCHAR2(20) := NVL(IN_MODE, '自動');
    v_db_list   t_db_tab;
    v_company   VARCHAR2(100);
    v_db        VARCHAR2(128);
    v_sql       VARCHAR2(4000);
    v_updated   PLS_INTEGER := 0;
    v_skipped   PLS_INTEGER := 0;
    v_code      NUMBER;
    v_errm      VARCHAR2(4000);
    v_stack     VARCHAR2(4000);

    PROCEDURE notify(p_msg IN VARCHAR2) IS
    BEGIN
        P_SEND_TEAMS_MSG(PKG_INV_FREEZE.c_teams_group_id, p_msg);
    END notify;

BEGIN
    -- UI 未選擇
    IF IN_FACTORY = '--xxx--' THEN
        OUT_MSG_CODE   := '18';
        OUT_MSG_RESULT := '廠區並未選擇';
        RETURN;
    END IF;

    IF IN_DEPT = '--xxx--' THEN
        OUT_MSG_CODE   := '19';
        OUT_MSG_RESULT := '部門並未選擇';
        RETURN;
    END IF;

    DELETE FROM GTT_FREEZE_LOT;   -- 避免暫存資料殘留

    -- 找出有凍結資料的廠區及其 DB LINK（每個廠區只處理一次）
    SELECT DISTINCT wt.company, ex.remark03
    BULK COLLECT INTO v_db_list
    FROM   ztpp_worktime wt,
           (SELECT remark02, remark03
              FROM extenditem_mapping
             WHERE class = 'FACTORY_MAP_DBLINK') ex
    WHERE  wt.deliver_sap = 'Z'
    AND    wt.company     = ex.remark02(+)
    AND    (IN_FACTORY IS NULL OR wt.company = IN_FACTORY);

    -- 逐廠區從遠端撈出可解凍的 LOT，放入 GTT
    FOR i IN 1 .. v_db_list.COUNT LOOP
        v_company := v_db_list(i).factory_name;
        v_db      := v_db_list(i).db_link;

        IF v_db IS NULL THEN
            IF v_mode = '手動' THEN
                ROLLBACK;
                OUT_MSG_CODE   := '21';
                OUT_MSG_RESULT := 'EXTENDITEM_MAPPING 未設定廠區 ' || v_company || ' 的 DB LINK';
                RETURN;
            END IF;
            notify('P_RELEASE_EXPIRED_FREEZE：COMPANY=' || v_company ||
                   ' 找不到對應 DB LINK，請確認 EXTENDITEM_MAPPING 設定');
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        BEGIN
            v_db := PKG_INV_FREEZE.check_dblink(v_db);

            v_sql :=
                'INSERT INTO GTT_FREEZE_LOT (sap_wo, lot, dept_id, factory_name)
                 SELECT DISTINCT lot.sap_wo, lot.lot, lot.dept_id, bf.factory_name
                   FROM wip_lot'     || v_db || ' lot,
                        bs_factory'  || v_db || ' bf
                  WHERE lot.factory_id  = bf.factory_id
                    AND bf.factory_name = :1
                    AND (:2 IS NULL OR lot.dept_id = :3)
                    -- 有已到期、且模式符合的凍結設定
                    AND EXISTS (
                        SELECT 1
                          FROM (SELECT remark01 AS dept_id,
                                       remark06 AS release_mode,
                                       CASE WHEN class = ''INVENTORY_FREEZE''
                                            THEN TO_DATE(remark04, ''FXYYYYMMDDHH24MISS'') END AS end_dt
                                  FROM bs_extenditem_mapping' || v_db || '
                                 WHERE class = ''INVENTORY_FREEZE'') ex
                         WHERE ex.dept_id      = lot.dept_id
                           AND ex.release_mode = :4
                           AND SYSDATE > ex.end_dt)
                    -- 且沒有仍在生效中的凍結設定
                    AND NOT EXISTS (
                        SELECT 1
                          FROM (SELECT remark01 AS dept_id,
                                       CASE WHEN class = ''INVENTORY_FREEZE'' AND remark02 = ''Y''
                                            THEN TO_DATE(remark03, ''FXYYYYMMDDHH24MISS'') END AS start_dt,
                                       CASE WHEN class = ''INVENTORY_FREEZE'' AND remark02 = ''Y''
                                            THEN TO_DATE(remark04, ''FXYYYYMMDDHH24MISS'') END AS end_dt
                                  FROM bs_extenditem_mapping' || v_db || '
                                 WHERE class    = ''INVENTORY_FREEZE''
                                   AND remark02 = ''Y'') ex2
                         WHERE ex2.dept_id = lot.dept_id
                           AND SYSDATE BETWEEN ex2.start_dt AND ex2.end_dt)';

            EXECUTE IMMEDIATE v_sql USING v_company, IN_DEPT, IN_DEPT, v_mode;
        EXCEPTION
            WHEN OTHERS THEN
                v_code := SQLCODE;
                v_errm := SQLERRM;

                IF v_mode = '手動' THEN
                    IF PKG_INV_FREEZE.is_date_error(v_code) THEN
                        ROLLBACK;
                        OUT_MSG_CODE   := '20';
                        OUT_MSG_RESULT := SUBSTR(
                            '資料格式錯誤：' || v_db ||
                            ' 系統的 [客製化分類設定] 開始/結束時間格式不正確，請確認設定。錯誤訊息: ' || v_errm,
                            1, 4000);
                        RETURN;
                    END IF;
                    RAISE;   -- 交給最外層處理（回傳 99）
                END IF;

                -- 自動模式：通知後略過此廠區
                notify(SUBSTR(
                    'P_RELEASE_EXPIRED_FREEZE：COMPANY=' || v_company || '（' || v_db || '）' ||
                    CASE WHEN PKG_INV_FREEZE.is_date_error(v_code)
                         THEN ' [客製化分類設定] 時間格式不正確'
                         ELSE ' 處理失敗'
                    END || '，已略過。錯誤訊息: ' || v_errm,
                    1, 4000));
                v_skipped := v_skipped + 1;
        END;
    END LOOP;

    -- 解除凍結
    UPDATE ztpp_worktime wt
    SET    deliver_sap = 'N'
    WHERE  deliver_sap = 'Z'
    AND    EXISTS (
        SELECT 1
        FROM   GTT_FREEZE_LOT g
        WHERE  wt.runcard    = g.lot
        AND    wt.work_order = g.sap_wo
        AND    wt.company    = g.factory_name
    );
    v_updated := SQL%ROWCOUNT;

    COMMIT;

    OUT_MSG_CODE   := '00';
    OUT_MSG_RESULT := '解除凍結完成，共 ' || v_updated || ' 筆' ||
                      CASE WHEN v_skipped > 0
                           THEN '（' || v_skipped || ' 個廠區處理失敗已略過，詳見 Teams 通知）'
                      END;

EXCEPTION
    WHEN OTHERS THEN
        -- 先保存錯誤資訊，避免後續呼叫覆蓋
        v_code  := SQLCODE;
        v_errm  := SQLERRM;
        v_stack := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_BACKTRACE || DBMS_UTILITY.FORMAT_ERROR_STACK, 1, 3000);

        ROLLBACK;
        notify(SUBSTR('P_RELEASE_EXPIRED_FREEZE 執行失敗，COMPANY=' || v_company ||
                      '，DB LINK=' || v_db || '，錯誤訊息: ' || v_errm, 1, 4000));

        OUT_MSG_CODE   := '99';
        OUT_MSG_RESULT := SUBSTR('執行例外錯誤: ' || v_stack || ' | ' || v_code || ' -- ' || v_errm, 1, 4000);
END P_RELEASE_EXPIRED_FREEZE;
/
