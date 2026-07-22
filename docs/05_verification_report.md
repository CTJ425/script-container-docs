# agy 審查報告驗證與修正結果報告 (Claude Verification Report)

> **建立時間**：2026-07-22
> **工作流程**：agy (Antigravity/Gemini) 審查 → Claude 逐項驗證裁決 → agy 依核准規格執行修改 → Claude 獨立 code review 與實測
> **對照文件**：`docs/01_overview.md` ～ `docs/04_fixes.md`（agy 原始報告，保留未動）

---

## 1. 總體結論

agy 的原始報告**約六成可信**：低風險項目多數屬實，但其標為 🔴 High/Critical 的四項中有**三項為誤報**，
且 agy 將封存的舊版腳本（`Inital-setup/`、`Seal_RHEL_VM/`、`pve_link_iso/Old/`）當作現行版本審查，
導致多項「Critical 修正建議」實際上早已在 `RHEL-Family-Temp/` 的現行版本中實作完成。

本次處置：採納 6 項真實問題交由 agy 修改，駁回 3 項誤報與 4 項設計性建議，
並刪除封存舊腳本以杜絕後續誤審。所有修改均經過獨立語法檢查、回歸實測與外部查證。

---

## 2. agy 原報告逐項裁決 (Verdict Matrix)

| # | agy 發現 | agy 評級 | 裁決 | 理由與處置 |
|---|---|:---:|:---:|---|
| 1.1 | 舊版 initial-setup 缺輸入驗證 | 🔴 High | ⚠️ 屬實但錯置 | 屬實，但該檔為封存舊版；`RHEL-Family-Temp` 後繼版早已有完整驗證。處置：刪除舊版目錄 |
| 1.2 | nmcli 位置參數錯位 | 🔴 High | ❌ 誤報 | 變數皆有引號，空值展開為空字串參數而非錯位；`ipv4.gateway ""` 是 nmcli 合法的清除語法。agy 自己的「修正版」else 分支同樣傳 `ipv4.gateway ""`，行為與原始碼一致 |
| 1.3 | 缺併發執行鎖 | 🟡 Medium | ✅ 採納 | 已加入 `mkdir /run/initial-setup.lock` 原子鎖 + EXIT trap 清理 |
| 1.4 | hostname 未同步 /etc/hosts | 🟡 Medium | ⚠️ 誇大 | RHEL 9 `nsswitch.conf` 預設含 `myhostname` 模組，「數十秒 sudo 延遲」不成立；現行版本已含 hosts 同步邏輯（本次進一步修正其匹配 bug，見 4.3） |
| 1.5 | 單網卡仍重複詢問 | 🟢 Low | ✅ 採納 | 已改為自動選取並顯示提示（與 repo 內第四輪 CODE_REVIEW_REPORT 建議一致） |
| 2.1 | SSH_TTY 檢查阻擋 SSH 觸發 | 🟡 Medium | ❌ 不採納 | 刻意設計：透過 SSH 執行改 IP 精靈會在套用時斷線，留下半套用的網路設定、未建旗標檔與殘留鎖。維持僅 Console 觸發 |
| 2.2 | 硬編碼路徑 / 未檢查執行權限 | 🟢 Low | ❌ 不採納 | 實際錯誤為 permission denied 而非「語法錯誤」；seal 腳本安裝流程已執行 `chmod +x`，價值極低 |
| 3.1 | seal 覆寫破壞 /etc/hosts | 🔴 High | ⚠️ 已修正在先 | 僅存在於封存的 `Seal_RHEL_VM/` 舊版；`RHEL-Family-Temp` 現行版早已改用 sed 精準移除 hostname。agy 建議的修法其實已被實作。處置：刪除舊版目錄 |
| 3.2 | machine-id 寫入 `uninitialized` 非法 | 🔴 High | ❌ 誤報 | `machine-id(5)` 官方文件明載：內容 `uninitialized\n` 觸發 systemd 完整 first-boot 語意（systemd ≥ 247，即 RHEL 9/10）。`uninitialized` 非合法 32 位 hex，systemd 必定重新產生，「所有 VM 機號相同」不成立。僅微調 RHEL 8 分支（systemd 239 不認得此字串）改為空檔 |
| 3.3 | 未含 AlmaLinux 會 die | 🟡 Medium | ❌ 誤報 | AlmaLinux 的 `ID_LIKE="rhel centos fedora"` 會被 `*" rhel "*` 命中，實際可通過。仍顯式加入 `almalinux` 作為文件化（無行為變更） |
| 3.4 | history 清理命令冗餘 | 🟢 Low | ⚠️ 已修正在先 | 僅存在於封存舊版；現行版已移除該行，且額外提示登出時的 history 回寫風險 |
| 4.1 | validate_dns 未引號展開 | 🟢 Low | ❌ 不採納 | 現行碼已有 `local -; set -f` 防護（agy 自己也承認）；其「修正版」改用 `local -f` 反而是錯誤語法，會引入新 bug |
| 4.2 | DNS 首尾空白未 trim | 🟢 Low | ✅ 採納 | 已以參數展開補上 trim |
| 4.3 | /etc/hosts 子字串誤匹配與累積 | 🟢 Low | ✅ 採納 | 真 bug（相似字首如 `myhost-prod` 會使 `myhost` 漏加）。已改為 word-boundary sed 移除舊名 + 錨定匹配後追加 |
| 5.1 | 舊版 pve 腳本管道子 Shell 計數恆 0 | 🔴 High | ⚠️ 屬實但錯置 | 屬實，但該檔在 `Old/` 封存目錄，現行版早已用行程替代修正。處置：刪除封存目錄 |
| 5.2 | dangling symlink 導致 ln 失敗 | 🔴 High | ❌ 誤報 | 腳本步驟 1 已先 `find -maxdepth 1 -type l -iname "*.iso" -delete` 清除所有（含失效）ISO 連結，`[ ! -e ]` 判斷時不可能殘留 dangling symlink |
| 5.3 | 同名 ISO 被跳過 | 🟡 Medium | ✅ 採納（部分） | 屬實，但「無聲跳過」說法錯誤（原本即有訊息，只是內容誤導）。已改為明確警告（含完整來源路徑）+ 獨立 SKIPPED 計數 |
| 6-1 | SELinux 應改用 /etc/selinux/config | — | ❌ 不採納 | `grubby --args selinux=0` 是 RHEL 9 官方文件記載的停用方式，且腳本 verify 邏輯與之配套；permissive 僅為另一風格選擇，非缺陷 |
| 6-2 | fstab 備份會被重複執行覆寫 | 🟢 Low | ⚠️ 屬實未採 | 影響極小（備份仍為冪等修改後版本），暫不處理 |
| 7.1 | GPU 硬性綁定 | 🟡 Medium | ✅ 採納 | 主檔維持 GPU 預設，新增 `docker-compose.cpu.yml` override（`deploy: !reset {}`，需 Compose ≥ v2.24） |
| 7.2 | 浮動映像 tag | 🟢 Low | ✅ 採納（修正版本） | 採納鎖版，但 agy 修正版給的 `0.5.7`/`0.5.9` 為過時版本，已改由即時查詢 registry 取得當前版本 |

另注意：agy 報告總覽表聲稱 `RHEL-Family-Temp/seal-rhel-template.sh` 有 3 項低風險問題，
但 `02_script_reviews.md` 全文未提供任何細節——該項為報告的未兌現聲明。

---

## 3. 本次實際修改內容

| 檔案 | 變更 |
|---|---|
| `RHEL-Family-Temp/initial-setup.sh` | ① 原子併發鎖 + EXIT trap ② 單網卡自動選取 ③ DNS trim ④ hosts word-boundary 移除舊名 + 錨定追加新名 |
| `RHEL-Family-Temp/seal-rhel-template.sh` | ① `detect_os` 顯式加入 `almalinux` ② RHEL 8 分支 machine-id 改空檔 + chmod 644（9/10 維持 `uninitialized` 不變）③ 內嵌 initial-setup 副本同步上述四項修改 |
| `pve_link_iso/pve_link_iso.sh` | 同名 ISO 跳過改為警告（含完整來源路徑）+ SKIPPED 計數 + 總結列印 |
| `Container/ollama/docker-compose.yml` | 鎖定 `ollama/ollama:0.32.2`、`ghcr.io/open-webui/open-webui:v0.10.2`；加入 CPU 用法註解 |
| `Container/ollama/docker-compose.cpu.yml` | **新增**：CPU-only override（`deploy: !reset {}`），註明需 Compose ≥ v2.24 |
| `Inital-setup/`、`Seal_RHEL_VM/`、`pve_link_iso/Old/` | **待刪除**（見第 5 節） |

修改執行者：agy（依 Claude 核准之精確規格，含明確禁止事項清單）。

---

## 4. Claude 獨立驗證結果（不採信 agy 自報）

| 驗證項目 | 方法 | 結果 |
|---|---|:---:|
| 變更範圍 | `git status` / `git diff` 逐檔比對規格 | ✅ 僅規格內 4 檔 + 1 新檔；`99-firstboot.sh`、k8s、docs 均未被觸碰 |
| 禁止事項 | diff 檢查 | ✅ SSH_TTY 檢查保留、RHEL 9/10 machine-id 未動、`local -` 寫法保留 |
| 語法 | `bash -n` × 3 個腳本 | ✅ 全數通過 |
| 內嵌副本一致性 | 抽出 heredoc 內容與獨立版 `diff` | ✅ 逐位元一致 |
| hosts 邏輯回歸測試 | 假 hosts 檔實測 5 情境（改名、相似字首、冪等重跑、子字串不誤抑制、行中移除）+ DNS trim | ✅ 功能全過（僅行內多重空格塌縮為單一空格之外觀差異，無功能影響） |
| 舊版 bug 回歸案例 | `myhost-prod` → `myhost` 情境（舊碼會漏加） | ✅ 新碼正確處理 |
| image tag 真實性 | Docker Hub API / GHCR manifest API / GitHub Releases API 即時查詢 | ✅ `ollama:0.32.2` 為當前最新穩定版（2026-07-22 推送）；`open-webui:v0.10.2` 為最新正式版（2026-07-01 發布，非 prerelease） |
| Compose 合併驗證 | `docker compose config`（主檔、主檔+CPU override） | ✅ 主檔含 GPU 區塊；合併後 `deploy`/`nvidia` 完全移除；本機 Compose v5.3.1 支援 `!reset` |

**Review 附加發現與處置**：`!reset` 需 Compose ≥ v2.24，已在 `docker-compose.cpu.yml` 加註（Claude 直接補上）。

---

## 5. 遺留事項

1. **封存舊腳本刪除**：`git rm -r Inital-setup Seal_RHEL_VM pve_link_iso/Old` 需由管理員手動執行
   （自動化執行被權限控管攔截）。
2. **README.md 清理**：舊目錄刪除後，`README.md` 中 `Inital-setup` 與 `Seal_RHEL_VM` 的
   快速連結與模組說明段落需一併移除。
3. `k8s_env_init` 的 fstab 備份覆寫（6-2）留待日後（可改為 `cp -n` 保留首次備份）。

---

## 6. 經驗教訓

- **AI 審查報告需逐項對照原始碼驗證**：本案 High 級別發現的誤報率為 3/4。
- **封存舊版與現行版混雜會誤導審查**：agy 對舊版提出的 Critical 修正，多數已存在於現行版——刪除封存目錄可根治。
- **AI 提供的「修正代碼」不可整段照抄**：agy 修正版含 `local -f` 語法錯誤、過時的映像版本號、
  以及與「被修正的原始碼」行為完全相同的「修復」（nmcli 空值處理）。
