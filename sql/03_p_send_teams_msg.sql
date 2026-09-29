-- =============================================================
-- P_SEND_TEAMS_MSG
-- 寫入 Teams 待發送佇列（實際發送由外部服務處理）
-- 使用自治交易：即使呼叫端 ROLLBACK，通知仍會保留
-- =============================================================
CREATE OR REPLACE PROCEDURE P_SEND_TEAMS_MSG (
    p_group_id IN VARCHAR2,
    p_msg      IN VARCHAR2
)
IS
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    INSERT INTO TEAMS_SEND_LIST (GROUPID, MESSAGE, IS_SUCCESS, DATAFROM)
    VALUES (p_group_id, SUBSTR(p_msg, 1, 4000), 'N', 'MES');
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        -- 通知失敗不影響主流程
        ROLLBACK;
END P_SEND_TEAMS_MSG;
/
