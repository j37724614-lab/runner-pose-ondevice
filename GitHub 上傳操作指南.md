---
title: GitHub 上傳操作指南

---

---
title: GitHub Push
---

# GitHub 上傳操作指南

Git 不會直接把工作目錄中的檔案上傳到 GitHub。完整流程是：

```text
檢查狀態 → 選取檔案（add）→ 建立版本（commit）→ 上傳（push）
```

## Git 狀態符號

| 符號 | 說明 |
|---|---|
| `M` | 已被 Git 追蹤的檔案有修改 |
| `D` | 已被 Git 追蹤的檔案被刪除 |
| `??` | 新檔案尚未被 Git 追蹤 |
| `A` | 新檔案已加入暫存區，將包含在下一次 commit |

## 建議的安全上傳流程

| 順序 | 指令 | 簡短說明 |
|---|---|---|
| 1 | `git status --short` | 查看目前有哪些修改、新增或刪除 |
| 2 | `git branch --show-current` | 確認目前所在分支，避免誤推到 `main` |
| 3 | `git remote -v` | 查看遠端名稱與 GitHub repository URL；**沒有任何輸出代表尚未設定 remote**，需先執行下方的 `git remote add origin` |
| 4 | `git add path/to/file.py` | 只將指定檔案加入暫存區，最安全 |
| 5 | `git diff --cached --name-status` | 確認下一個 commit 會包含哪些檔案 |
| 6 | `git diff --cached` | 查看即將 commit 的實際修改內容 |
| 7 | `git commit -m "修改說明"` | 將暫存區內容建立成一個版本 |
| 8 | `git push -u origin HEAD` | 將目前分支推到 GitHub，並設定追蹤關係 |

首次成功執行 `git push -u origin HEAD` 後，同一分支之後通常只需：

```bash
git push
```

### 尚未設定 remote 時（`git remote -v` 沒有輸出）

第一次上傳一個全新的 repository，或 `git remote -v` 完全沒有印出東西時，代表本機還沒有連到任何 GitHub repository，需要先在 GitHub 建立一個空的 repository，再把它加為 `origin`：

```bash
# SSH（建議，需先設定 SSH key）
git remote add origin git@github.com:<帳號>/<repository>.git

# 或 HTTPS
git remote add origin https://github.com/<帳號>/<repository>.git

git remote -v          # 確認 origin 的 fetch / push URL 都正確
git branch --show-current   # 確認分支名稱（新 repo 常是 master，GitHub 預設 main）
git push -u origin HEAD     # 第一次推送並建立追蹤關係
```

| 用途 | 指令 | 簡短說明 |
|---|---|---|
| 新增遠端 | `git remote add origin <URL>` | 將 GitHub repository 設為名為 `origin` 的遠端 |
| 修改遠端 URL | `git remote set-url origin <URL>` | remote 已存在但 URL 打錯或要換成 SSH / HTTPS 時使用 |
| 移除遠端 | `git remote remove origin` | 刪除設定錯誤的遠端後重新 `add` |
| 重新命名本機分支 | `git branch -m master main` | 推送前把 `master` 改名為 `main`，與 GitHub 預設一致 |

## 常用 Git 指令

| 用途 | 指令 | 簡短說明 |
|---|---|---|
| 查看完整狀態 | `git status` | 顯示工作區、暫存區與未追蹤檔案 |
| 查看簡潔狀態 | `git status --short` | 使用 `M`、`D`、`??` 等符號顯示狀態 |
| 查看目前分支 | `git branch --show-current` | 顯示目前所在分支名稱 |
| 查看所有本機分支 | `git branch` | 列出本機分支，`*` 代表目前分支 |
| 建立並切換分支 | `git switch -c feature-name` | 從目前版本建立新分支並切換過去 |
| 切換既有分支 | `git switch branch-name` | 切換到指定的本機分支 |
| 查看遠端 | `git remote -v` | 顯示 `origin` 等遠端名稱及 URL |
| 更新遠端資訊 | `git fetch origin` | 取得 GitHub 最新分支與 commit，不修改工作檔案 |
| 加入指定檔案 | `git add path/to/file.py` | 只暫存指定檔案 |
| 加入多個檔案 | `git add file1.py file2.py` | 一次暫存多個指定檔案 |
| 加入目前目錄變更 | `git add .` | 暫存目前目錄範圍內的新增、修改與刪除 |
| 加入整個 repository | `git add -A` | 暫存整個 repository 的所有新增、修改與刪除 |
| 取消暫存指定檔案 | `git restore --staged path/to/file.py` | 從暫存區移除，但保留本機修改 |
| 取消全部暫存 | `git restore --staged .` | 清空暫存區，但不刪除本機修改 |
| 查看未暫存修改 | `git diff` | 顯示尚未 `git add` 的修改 |
| 查看已暫存修改 | `git diff --cached` | 顯示下一次 commit 將包含的內容 |
| 建立 commit | `git commit -m "修改說明"` | 將已暫存內容保存為一個 commit |
| 查看尚未推送的 commit | `git log --oneline origin/main..HEAD` | 比較目前分支與遠端 `main` 的 commit |
| 查看尚未推送的檔案 | `git diff --name-status origin/main..HEAD` | 顯示目前分支相對遠端 `main` 的檔案差異 |
| 推送目前分支 | `git push -u origin HEAD` | 推送目前分支，不必手動輸入分支名稱 |
| 再次推送目前分支 | `git push` | 推送到先前設定的遠端追蹤分支 |
| 直接推送 `main` | `git push origin main` | 將本機 `main` 推送到 GitHub 的 `main` |

## 分支上傳範例

建議在新分支保存修改，確認後再透過 Pull Request 合併到 `main`：

```bash
git switch -c feature-name
git add path/to/file.py
git diff --cached
git commit -m "refactor: update pipeline"
git push -u origin HEAD
```

`git push -u origin HEAD` 只會推送目前分支。如果目前分支是 `feature-name`，GitHub 的 `main` 不會被修改。只有合併 Pull Request，或在 `main` 上執行 push，才會更新 `main`。

## 上傳指定 Python 檔案範例

```bash
git restore --staged .
git add core/pipeline.py core/tracking.py run_pipeline.py
git diff --cached --name-status
git commit -m "refactor: update runner analysis pipeline"
git push -u origin HEAD
```

> 執行 `git add .` 或 `git add -A` 前，務必先檢查 `git status --short`。它們可能包含不預期的刪除、大型模型、簡報或其他未追蹤檔案。
