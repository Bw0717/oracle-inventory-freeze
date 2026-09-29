-- =============================================================
-- PKG_INV_FREEZE
-- 共用設定與工具函式
-- =============================================================
CREATE OR REPLACE PACKAGE PKG_INV_FREEZE AS

    -- Teams 通知群組 ID（部署前請改成實際值）
    c_teams_group_id CONSTANT VARCHAR2(40) := '<YOUR_TEAMS_GROUP_ID>';

    -- 驗證 DB LINK 字串（格式須為 '@LINK_NAME'），不合法則拋出 ORA-20001
    FUNCTION check_dblink(p_dblink IN VARCHAR2) RETURN VARCHAR2;

    -- 判斷 SQLCODE 是否為日期格式轉換錯誤
    FUNCTION is_date_error(p_sqlcode IN NUMBER) RETURN BOOLEAN;

END PKG_INV_FREEZE;
/

CREATE OR REPLACE PACKAGE BODY PKG_INV_FREEZE AS

    FUNCTION check_dblink(p_dblink IN VARCHAR2) RETURN VARCHAR2 IS
        v_dummy VARCHAR2(200);
    BEGIN
        IF p_dblink IS NULL OR SUBSTR(p_dblink, 1, 1) <> '@' THEN
            RAISE_APPLICATION_ERROR(-20001, 'DB LINK 設定不合法（須以 @ 開頭）: ' || p_dblink);
        END IF;

        -- 以 "X@LINK" 形式交給 DBMS_ASSERT 驗證，防止 SQL Injection
        BEGIN
            v_dummy := DBMS_ASSERT.QUALIFIED_SQL_NAME('X' || p_dblink);
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(-20001, 'DB LINK 設定不合法: ' || p_dblink);
        END;

        RETURN p_dblink;
    END check_dblink;

    FUNCTION is_date_error(p_sqlcode IN NUMBER) RETURN BOOLEAN IS
    BEGIN
        RETURN p_sqlcode IN (-1830, -1841, -1843, -1847, -1858, -1861, -1862);
    END is_date_error;

END PKG_INV_FREEZE;
/
