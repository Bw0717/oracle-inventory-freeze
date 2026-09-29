-- 依相依順序安裝全部物件
-- 用法：sqlplus user/pass@db @install.sql
SET DEFINE OFF
SET SERVEROUTPUT ON

PROMPT [1/6] GTT_FREEZE_LOT
@@sql/01_gtt_freeze_lot.sql
PROMPT [2/6] PKG_INV_FREEZE
@@sql/02_pkg_inv_freeze.sql
PROMPT [3/6] P_SEND_TEAMS_MSG
@@sql/03_p_send_teams_msg.sql
PROMPT [4/6] ITRIGGER_INV_FREEZE
@@sql/04_trg_inv_freeze.sql
PROMPT [5/6] P_RELEASE_EXPIRED_FREEZE
@@sql/05_p_release_expired_freeze.sql
PROMPT [6/6] J_RELEASE_EXPIRED_FREEZE（建立後立即啟用）
@@sql/06_job_release_expired_freeze.sql

PROMPT 安裝完成，檢查無效物件：
SELECT object_name, object_type
FROM   user_objects
WHERE  status = 'INVALID'
AND    object_name IN ('PKG_INV_FREEZE', 'P_SEND_TEAMS_MSG',
                       'ITRIGGER_INV_FREEZE', 'P_RELEASE_EXPIRED_FREEZE');
