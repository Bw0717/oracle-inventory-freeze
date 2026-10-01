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
    IN_ADACCOUNT    IN  VARCHAR2 DEFAULT NULL,
    IN_V_MODE         IN  VARCHAR2 DEFAULT NULL,
    IN_FACTORY      IN  VARCHAR2 DEFAULT NULL,
    IN_DEPT         IN  VARCHAR2 DEFAULT NULL,
    OUT_MSG_CODE    OUT VARCHAR2,
    OUT_MSG_RESULT  OUT VARCHAR2
)
IS
    PRAGMA AUTONOMOUS_TRANSACTION;

    v_mode          VARCHAR2(20) := IN_V_MODE;
    v_current_db    VARCHAR2(10);
    v_finish_date   DATE;
    v_freeze_mode   VARCHAR2(20);
    v_sql           VARCHAR2(2000);

    TYPE t_db_rec IS RECORD (
        factory_name  VARCHAR2(50),
        db_link       VARCHAR2(10)
    );
    TYPE t_db_tab IS TABLE OF t_db_rec;
    v_db_list       t_db_tab;

    c_group_id      CONSTANT VARCHAR2(40) := '75C4BE22E6BF45D39803E9BD6B430E71';
BEGIN
    --UI未選擇處理
    IF IN_FACTORY = '--xxx--' THEN
        OUT_MSG_CODE   := '17';
        OUT_MSG_RESULT := '廠區並未選擇';
        RETURN;
    END IF;

    IF IN_DEPT = '--xxx--' THEN
        OUT_MSG_CODE   := '18';
        OUT_MSG_RESULT := '部門並未選擇';
        RETURN;
    END IF;

    --傳進來的值如果是自動表示是手動觸發，但設定是自動
    IF v_mode = '自動' THEN
        OUT_MSG_CODE   := '19';
        OUT_MSG_RESULT := '目前設定為自動，不允許手動操作';
        RETURN;
    ELSIF v_mode = '查無設定' THEN
        OUT_MSG_CODE   := '19';
        OUT_MSG_RESULT := '客製化分類設定，未設定此部門';
        RETURN;      
    END IF;

    --JOB觸發為NULL/手動觸發為手動
    IF v_mode IS NULL THEN
        v_mode := '自動';
    END IF;

    DELETE FROM GTT_FREEZE_LOT;   -- 避免TEMP資料殘留

    --查連到哪個DB LINK
    SELECT DISTINCT wt.company AS factory_name, ex.remark03 AS db_link
    BULK COLLECT INTO v_db_list
    FROM   (SELECT * FROM extenditem_mapping
            WHERE  class = 'FACTORY_MAP_DBLINK') ex,
           ztpp_worktime wt
    WHERE  wt.deliver_sap = 'Z'
    AND    wt.company     = ex.remark02(+)
    AND    (wt.company = IN_FACTORY OR IN_FACTORY IS NULL);

    --沒有凍結中的報工資料就結束
    IF v_mode = '手動' THEN
      IF v_db_list.COUNT = 0 THEN
          ROLLBACK;
          OUT_MSG_CODE   := '23';
          OUT_MSG_RESULT := '目前沒有凍結中的報工資料';
          RETURN;
      END IF;
    END IF;  
    --把DB LINK處理的資料全部丟到DEC的TEMP
    FOR i IN 1 .. v_db_list.COUNT LOOP
        v_current_db := v_db_list(i).db_link;

        IF v_current_db IS NULL THEN
            IF v_mode = '手動' THEN
                ROLLBACK;
                OUT_MSG_CODE   := '21';
                OUT_MSG_RESULT := 'DEC.EXTENDITEM_MAPPING廠區未設定：' || v_db_list(i).factory_name;
                RETURN;
            END IF;

            P_SEND_TEAMS_MSG(
                p_group_id => c_group_id,
                p_msg      => '執行P_RELEASE_EXPIRED_FREEZE@DEC，發生COMPANY:' || v_db_list(i).factory_name ||
                              '找不到對應DB LINK 請確認'
            );
            CONTINUE;
        END IF;

        BEGIN
            --手動執行：檢查解凍模式與盤點結束時間
            IF v_mode = '手動' AND IN_DEPT IS NOT NULL THEN
                v_sql :=
                    'SELECT TO_DATE(remark04, ''FXYYYYMMDDHH24MISS''), remark06
                     FROM   bs_extenditem_mapping' || v_current_db || '
                     WHERE  class    = ''INVENTORY_FREEZE''
                     AND    remark01 = :1';

                BEGIN
                    EXECUTE IMMEDIATE v_sql INTO v_finish_date, v_freeze_mode USING IN_DEPT;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        ROLLBACK;
                        OUT_MSG_CODE   := '24';
                        OUT_MSG_RESULT := '查無部門 ' || IN_DEPT || ' 的盤點凍結設定';
                        RETURN;
                END;

                IF v_freeze_mode IS NULL OR v_freeze_mode != v_mode THEN
                    ROLLBACK;
                    OUT_MSG_CODE   := '25';
                    OUT_MSG_RESULT := '部門 ' || IN_DEPT || ' 的解凍設定為[' || NVL(v_freeze_mode, '未設定') ||
                                      ']，與目前執行模式[' || v_mode || ']不符';
                    RETURN;
                ELSIF v_finish_date IS NULL THEN
                    ROLLBACK;
                    OUT_MSG_CODE   := '24';
                    OUT_MSG_RESULT := '部門 ' || IN_DEPT || ' 未設定盤點結束時間';
                    RETURN;
                ELSIF SYSDATE < v_finish_date THEN
                    ROLLBACK;
                    OUT_MSG_CODE   := '22';
                    OUT_MSG_RESULT := '尚未到達盤點結束時間，盤點結束時間為:' ||
                                      TO_CHAR(v_finish_date, 'YYYY/MM/DD HH24:MI:SS');
                    RETURN;
                END IF;
            END IF;

            --預存EX,LOT符合的資料到TEMP，避免過多DBLINK
            v_sql :=
                'INSERT INTO GTT_FREEZE_LOT (sap_wo, lot, dept_id, factory_name)
                 SELECT lot.sap_wo, lot.lot, lot.dept_id, bf.factory_name
                 FROM   wip_lot' || v_current_db || ' lot,
                        bs_extenditem_mapping' || v_current_db || ' ex,
                        bs_factory' || v_current_db || ' bf
                 WHERE  lot.factory_id = bf.factory_id
                 AND    lot.dept_id    = ex.remark01
                 AND    ex.class       = ''INVENTORY_FREEZE''
                 AND    ex.remark06    = :1
                 AND    SYSDATE > TO_DATE(ex.remark04, ''FXYYYYMMDDHH24MISS'')';

            IF IN_DEPT IS NOT NULL THEN
                v_sql := v_sql || ' AND ex.remark01 = :2';
                EXECUTE IMMEDIATE v_sql USING v_mode, IN_DEPT;
            ELSE
                EXECUTE IMMEDIATE v_sql USING v_mode;
            END IF;

        EXCEPTION
            WHEN OTHERS THEN
                -- 如果客製化分類時間格式設定錯誤
                IF SQLCODE IN (-1858, -1830, -1843, -1847, -1841, -1861, -1862) THEN
                    ROLLBACK;   -- 清除 GTT 的資料
                    OUT_MSG_CODE   := '20';
                    OUT_MSG_RESULT := SUBSTR(
                        '資料格式錯誤：' || v_current_db ||
                        ' 系統的[客製化分類設定].[結束時間] 格式不正確，請確認設定。錯誤訊息: ' || SQLERRM,
                        1, 4000
                    );
                    RETURN;
                ELSE
                    RAISE;   -- 不是日期格式問題，往外拋給最外層的 EXCEPTION 處理
                END IF;
        END;
    END LOOP;

    -- 解除凍結UPDATE
    UPDATE ztpp_worktime wt
    SET    deliver_sap = 'N'
    WHERE  deliver_sap = 'Z'
    AND    EXISTS (
        SELECT 1
        FROM   GTT_FREEZE_LOT sfc
        WHERE  wt.runcard    = sfc.lot
        AND    wt.work_order = sfc.sap_wo
        AND    wt.company    = sfc.factory_name
        AND    (IN_DEPT IS NULL OR sfc.dept_id = IN_DEPT)
    );

    COMMIT;

    OUT_MSG_CODE   := '00';
    OUT_MSG_RESULT := '解除凍結完成';

EXCEPTION
    WHEN OTHERS THEN
        --預期外錯誤就發TEAMS
        ROLLBACK;
        P_SEND_TEAMS_MSG(
            p_group_id => c_group_id,
            p_msg      => 'P_RELEASE_EXPIRED_FREEZE@DEC，執行者:' || NVL(IN_ADACCOUNT, 'JOB') ||
                          '，' || NVL(v_current_db, '(未知)') || ' Z轉換N發生錯誤: ' || SQLERRM
        );
        IF v_mode = '手動' THEN
          OUT_MSG_CODE   := '99';
          OUT_MSG_RESULT := SUBSTR(
              '執行例外錯誤: ' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE ||
              DBMS_UTILITY.FORMAT_ERROR_STACK || ' & ' || SQLCODE || ' -- ' || SQLERRM,
              1, 4000
          );
        END IF;
END P_RELEASE_EXPIRED_FREEZE;
/
