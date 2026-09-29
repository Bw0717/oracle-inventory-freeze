-- =============================================================
-- J_RELEASE_EXPIRED_FREEZE
-- 每分鐘以「自動」模式執行解除凍結。
-- 使用 PLSQL_BLOCK（STORED_PROCEDURE 類型的 job 不支援 OUT 參數）。
-- 回傳碼非 '00' 時拋出錯誤，讓失敗紀錄出現在
-- USER_SCHEDULER_JOB_RUN_DETAILS。
-- =============================================================
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'J_RELEASE_EXPIRED_FREEZE',
        job_type        => 'PLSQL_BLOCK',
        job_action      => q'[
DECLARE
    v_code VARCHAR2(10);
    v_msg  VARCHAR2(4000);
BEGIN
    P_RELEASE_EXPIRED_FREEZE(
        IN_MODE        => '自動',
        IN_FACTORY     => NULL,
        IN_DEPT        => NULL,
        OUT_MSG_CODE   => v_code,
        OUT_MSG_RESULT => v_msg);

    IF v_code <> '00' THEN
        RAISE_APPLICATION_ERROR(-20000, v_code || ': ' || SUBSTR(v_msg, 1, 500));
    END IF;
END;]',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=MINUTELY;INTERVAL=1',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => '每分鐘自動解除已到期的庫存凍結');
END;
/
