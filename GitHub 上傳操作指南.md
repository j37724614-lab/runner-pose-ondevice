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

## Mac 從 GitHub 更新本機版本

在 Mac 上將 GitHub 的 `main` 最新版本更新到本機：

```bash
cd /Users/catslab/dev/runner-pose-ondevice

git status --short --branch
git pull --rebase origin main
```

先確認 `git status` 沒有需要保留但尚未 commit 的修改。若有本機修改，先暫存後再更新：

```bash
cd /Users/catslab/dev/runner-pose-ondevice

git stash push -u -m "before pulling latest changes"
git pull --rebase origin main
git stash pop
```

如果 `git pull --rebase` 或 `git stash pop` 顯示 conflict，先停止操作並檢查衝突；不要使用
`git reset --hard`，以免刪除尚未保存的程式、模型或測試資料。

## 更新到指定 commit 版本

想把本機更新到某個特定 commit（例如同事在 GitHub 上 push 的版本，但該 commit 不一定是任何分支的最新指向），先用該 commit 的完整 SHA 抓取：

```bash
git fetch origin <commit-sha>
```

接著依情況選擇：

| 情境 | 指令 | 簡短說明 |
|---|---|---|
| 該 commit 是目前分支的直接後代（可以 fast-forward） | `git merge --ff-only FETCH_HEAD` | 乾淨地把目前分支快轉到該 commit，不會產生多餘的 merge commit；若無法 fast-forward 指令會直接失敗，不會動到任何檔案 |
| 只想先檢視該版本內容，不想動到目前分支 | `git checkout FETCH_HEAD` | 進入 detached HEAD 狀態檢視該 commit；之後執行 `git checkout main` 即可切回原本分支 |

> 可用 `git merge-base --is-ancestor HEAD <commit-sha> && echo OK` 事先確認是否能 fast-forward。

## 確認本機目前的版本

| 用途 | 指令 | 簡短說明 |
|---|---|---|
| 顯示完整 SHA | `git rev-parse HEAD` | 顯示目前所在 commit 的完整 40 碼 SHA |
| 顯示簡短 SHA + 訊息 | `git log -1 --oneline` | 簡短 SHA 加上該 commit 的訊息 |
| 顯示完整 commit 資訊 | `git log -1` | 顯示作者、日期、完整 commit 訊息 |
| 確認目前分支 | `git branch --show-current` | 顯示目前所在分支名稱 |

> 若想確認的是「本機安裝的 Git 軟體版本」而非目前 repo 所在的 commit，用 `git --version`。

---

# 2026-10-06 Mac 開發指令複習

這一節整理本次 Local 分析整合實際用到的指令。專案包含兩個 repository，執行 Git 指令前要先確認終端機位於正確資料夾。

| Repository | Mac 路徑 | 使用分支 |
|---|---|---|
| iOS Local 分析套件 | `/Users/catslab/dev/runner-pose-ondevice` | `main` |
| Flutter 前端 | `/Users/catslab/dev/running-analysis-frontend/running-analysis-frontend` | `integrate/f413c3c` |

## 一、更新 iOS Local 分析套件

```bash
cd /Users/catslab/dev/runner-pose-ondevice

git status --short --branch
git pull --rebase origin main
git log -3 --oneline
```

各指令的作用：

| 指令 | 作用 |
|---|---|
| `cd <路徑>` | 切換到指定 repository |
| `git status --short --branch` | 同時查看目前分支、修改檔案與遠端同步狀態 |
| `git pull --rebase origin main` | 將 GitHub `main` 更新到本機，避免產生不必要的 merge commit |
| `git log -3 --oneline` | 顯示最近三個 commit，確認更新版本 |

本次需要確認的修正版本：

```text
6b176be fix: dispatch Flutter analysis events on main queue
```

## 二、有本機修改而無法 pull 時

先查看指定檔案實際改了什麼：

```bash
git diff -- flutter/runner_pose/ios/Classes/RunnerPosePlugin.swift
```

只暫存該檔案，避免把影片、模型及編譯暫存一起放入 stash：

```bash
git stash push -m "FlutterError Swift compatibility fix" -- \
  flutter/runner_pose/ios/Classes/RunnerPosePlugin.swift

git pull --rebase origin main
git stash pop
```

檢查 stash 的常用指令：

```bash
git stash list
git stash show -p stash@{0}
```

注意事項：

- `git stash pop` 會套回修改並移除該筆 stash。
- 如果出現 `CONFLICT`，先停止操作並處理衝突，不要執行 `git reset --hard`。
- `?? BenchApp/.build-spm/` 是未追蹤的 SwiftPM 編譯暫存，不會阻止只有 tracked changes 所造成的 pull 問題。
- `git stash push -u` 會連未追蹤檔案一起收進 stash；repository 內有大型影片或模型時不要隨便使用。

## 三、更新 Flutter 前端

```bash
cd /Users/catslab/dev/running-analysis-frontend/running-analysis-frontend

git status --short --branch
git switch integrate/f413c3c
git pull --ff-only origin integrate/f413c3c
git log -3 --oneline
```

| 指令 | 作用 |
|---|---|
| `git switch integrate/f413c3c` | 切換到 Local 分析整合分支 |
| `git pull --ff-only ...` | 只有能安全快轉時才更新；分支分歧時不會自動建立 merge commit |

本次需要確認的逾時修正版本：

```text
add70cd fix: stop stalled local analysis with actionable timeout
```

## 四、更新 Flutter 與 iOS dependencies

在 Flutter 前端根目錄執行：

```bash
flutter clean
flutter pub get

cd ios
pod install
cd ..
```

| 指令 | 作用 |
|---|---|
| `flutter clean` | 移除舊的 Flutter/Xcode build 產物；更換原生 Swift 程式後適合執行 |
| `flutter pub get` | 依照 `pubspec.yaml` 下載或重新連結 Dart/Flutter dependencies |
| `pod install` | 依照 `Podfile` 與 `Podfile.lock` 安裝 iOS CocoaPods dependencies |
| `pod install --repo-update` | CocoaPods 規格太舊或找不到套件版本時，先更新規格再安裝；平常不必每次使用 |

## 五、確認 iPhone 連線

```bash
flutter devices
```

本次測試手機：

```text
Cats 17
00008150-001909511A9B401C
```

看到其他未開啟 Developer Mode 的裝置出現 `code -27`，不代表 Cats 17 連線失敗；只要 Cats 17 列在 connected devices 中即可。

## 六、用 Debug 模式啟動 App

Debug 適合目前除錯，終端機會保留較完整的原生與 Flutter log。不要加 `--release`：

```bash
cd /Users/catslab/dev/running-analysis-frontend/running-analysis-frontend

flutter run \
  -d 00008150-001909511A9B401C \
  --dart-define=ENABLE_LOCAL_ANALYSIS=true \
  --dart-define=ENABLE_COMPARE_ANALYSIS=false \
  --dart-define=API_BASE_URL=http://catslab.ee.ncku.edu.tw:18000/running_analysis/api
```

執行中的快捷鍵：

| 按鍵 | 作用 |
|---|---|
| `r` | Hot reload；只更新 Dart UI/邏輯 |
| `R` | Hot restart；重新啟動 Flutter app 狀態 |
| `q` | 停止 App 並結束 `flutter run` |
| `h` | 顯示所有互動快捷鍵 |

修改 Swift、Pods、Bundle ID 或 iOS Signing 後，不能只按 `r`；應按 `q` 停止後重新執行 `flutter run`。

## 七、Release 模式啟動方式

Release 適合最後量測效能，不適合優先排查錯誤：

```bash
flutter run --release \
  -d 00008150-001909511A9B401C \
  --dart-define=ENABLE_LOCAL_ANALYSIS=true \
  --dart-define=ENABLE_COMPARE_ANALYSIS=false \
  --dart-define=API_BASE_URL=http://catslab.ee.ncku.edu.tw:18000/running_analysis/api
```

三個 `dart-define` 的用途：

| 設定 | 本次值 | 作用 |
|---|---|---|
| `ENABLE_LOCAL_ANALYSIS` | `true` | 顯示並啟用 Local 分析 |
| `ENABLE_COMPARE_ANALYSIS` | `false` | 暫時不啟用 Server + Local 同時比較 |
| `API_BASE_URL` | port `18000` | 連接自己的 backend，而不是其他正式伺服器 |

## 八、測試與靜態檢查

在 Flutter 前端根目錄執行：

```bash
flutter test
flutter analyze
```

只測 Local adapter：

```bash
flutter test test/local_analysis_adapter_test.dart
```

| 指令 | 作用 |
|---|---|
| `flutter test` | 執行全部 Flutter 單元測試 |
| `flutter analyze` | 找出編譯型別問題、lint 與 deprecated API 提示 |

## 九、這次 Local 逾時行為

- Local 原生分析連續 5 分鐘沒有進度或完成事件：自動取消，顯示卡住的階段與 `local_no_progress_timeout`。
- Local 分析已完成，但同步到 backend 超過 90 秒：顯示 `sync_timeout`，並保留本機結果 bundle。
- 一般同步失敗：顯示 `sync_failed`，並允許按 `Retry Local` 重試。

## 十、常見終端機輸入錯誤

| 錯誤輸入 | 正確輸入 | 原因 |
|---|---|---|
| `flutter devices~` | `flutter devices` | `~` 被當成指令名稱的一部分 |
| `ㄏㄠclear` | `clear` | 中文輸入法文字被加入指令 |
| `^[[200~cd ...` | 重新輸入 `cd ...` | 終端機貼上控制字元，不是路徑內容 |
| 在 `runner-pose-ondevice` 執行前端分支指令 | 先 `cd` 到前端 repo | 不同 repository 擁有不同分支 |

不確定目前位置時，可以執行：

```bash
pwd
git status --short --branch
```
