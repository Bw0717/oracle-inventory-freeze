# Oracle Inventory Freeze

MES 報工資料的「庫存凍結 / 自動解凍」機制（Oracle PL/SQL）。

盤點或特殊管制期間，指定部門的報工資料暫停拋轉 SAP；凍結期間結束後，自動恢復拋轉。支援多廠區，各廠區 MES 資料透過 DB LINK 讀取。

## 運作流程

```
報工寫入 ZTPP_WORKTIME
        │
        ▼
ITRIGGER_INV_FREEZE（BEFORE INSERT）
  └─ 依 COMPANY 找 DB LINK → 查 LOT 所屬部門是否在凍結期間
        ├─ 是 → DELIVER_SAP = 'Z'（凍結，不拋 SAP）
        └─ 否 → 維持原值
        │
        ▼
J_RELEASE_EXPIRED_FREEZE（每分鐘）/ UI 手動
  └─ P_RELEASE_EXPIRED_FREEZE
        └─ 凍結已到期、且無其他生效中凍結 → DELIVER_SAP = 'N'（恢復拋轉）
```

任何錯誤都會寫入 `TEAMS_SEND_LIST` 發送 Teams 通知；Trigger 發生錯誤時**不會**阻擋報工寫入。

## 物件清單

| 檔案 | 物件 | 說明 |
|---|---|---|
| `sql/01_gtt_freeze_lot.sql` | `GTT_FREEZE_LOT` | 解凍用暫存表 |
| `sql/02_pkg_inv_freeze.sql` | `PKG_INV_FREEZE` | 設定值（Teams 群組 ID）與共用函式 |
| `sql/03_p_send_teams_msg.sql` | `P_SEND_TEAMS_MSG` | 寫入 Teams 待發送佇列（自治交易） |
| `sql/04_trg_inv_freeze.sql` | `ITRIGGER_INV_FREEZE` | 報工寫入時判斷是否凍結 |
| `sql/05_p_release_expired_freeze.sql` | `P_RELEASE_EXPIRED_FREEZE` | 解除到期凍結 |
| `sql/06_job_release_expired_freeze.sql` | `J_RELEASE_EXPIRED_FREEZE` | 每分鐘自動解凍排程 |

## 相依資料表

以下資料表不在本 repo 內，需事先存在。

**本地端**

- `ZTPP_WORKTIME`：報工資料（`COMPANY`、`RUNCARD`、`WORK_ORDER`、`DELIVER_SAP`）
- `EXTENDITEM_MAPPING`，`class = 'FACTORY_MAP_DBLINK'`：
  - `remark02`：廠區名稱（對應 `ZTPP_WORKTIME.COMPANY`）
  - `remark03`：DB LINK，格式為 `@LINK_NAME`
- `TEAMS_SEND_LIST`：Teams 通知佇列，由外部服務負責實際發送

**各廠區（透過 DB LINK）**

- `WIP_LOT`、`BS_FACTORY`
- `BS_EXTENDITEM_MAPPING`，`class = 'INVENTORY_FREEZE'`：

| 欄位 | 意義 |
|---|---|
| `remark01` | 部門 ID |
| `remark02` | 是否啟用（`Y` / `N`） |
| `remark03` | 開始時間，`YYYYMMDDHH24MISS` |
| `remark04` | 結束時間，`YYYYMMDDHH24MISS` |
| `remark06` | 解凍模式（`自動` / `手動`） |

## 安裝

1. 修改 `sql/02_pkg_inv_freeze.sql` 中的 `c_teams_group_id`。
2. 執行：

```bash
sqlplus user/password@db @install.sql
```

排程建立後會立即啟用。若要先停用：

```sql
EXEC DBMS_SCHEDULER.DISABLE('J_RELEASE_EXPIRED_FREEZE');
```

## 手動解凍（UI 呼叫）

```sql
DECLARE
    v_code VARCHAR2(10);
    v_msg  VARCHAR2(4000);
BEGIN
    P_RELEASE_EXPIRED_FREEZE('手動', 'FACTORY_A', NULL, v_code, v_msg);
    DBMS_OUTPUT.PUT_LINE(v_code || ' ' || v_msg);
END;
/
```

| 參數 | 說明 |
|---|---|
| `IN_MODE` | `自動` / `手動`，`NULL` 視為自動 |
| `IN_FACTORY` | 廠區，`NULL` 為全部 |
| `IN_DEPT` | 部門，`NULL` 為全部 |

## 回傳碼

| 代碼 | 說明 |
|---|---|
| `00` | 成功（訊息含解凍筆數與略過的廠區數） |
| `18` | 廠區未選擇 |
| `19` | 部門未選擇 |
| `20` | 凍結設定時間格式錯誤（手動模式） |
| `21` | 廠區未設定 DB LINK（手動模式） |
| `99` | 非預期錯誤 |

## 自動與手動模式的差異

- **自動**：某廠區失敗（DB LINK 未設定、連線失敗、時間格式錯誤）時，發 Teams 通知並略過該廠區，其他廠區照常處理。
- **手動**：任一廠區失敗即整批 ROLLBACK，並回傳錯誤碼給 UI。

## 注意事項

- Trigger 每寫入一筆報工，就會透過 DB LINK 查詢一次，大量批次寫入時會影響效能。
- 自動模式下若設定錯誤未修正，每分鐘都會發送一次 Teams 通知。
- 停用中（`remark02 = 'N'`）的凍結設定，仍會被視為「已到期」的解凍依據；但不會被視為「生效中」的凍結。

## License

MIT
