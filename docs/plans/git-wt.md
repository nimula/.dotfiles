# git-wt 實作計畫

狀態：待實作。按順序完成，每一步驗收後再勾選。

目標：完成 `bin/git-wt` 的 TODO，沿用現有 Zsh 腳本與 Git 原生 worktree 指令。
參考：[tree-me](https://github.com/haacked/dotfiles/blob/main/bin/tree-me) 的分支切換、移除與 shell wrapper。

## 範圍

- 修改 `bin/git-wt`，新增 `tests/git-wt.zsh`，在 `README.md` 補上使用方式。
- shellenv 讓 `git-wt …` 與 `git wt …` 都能自動 cd，並提供 `git-wt` 的 Bash／Zsh tab completion。
- 不實作 PR、Graphite 或額外設定系統。
- 不新增通用預檢、交易／復原框架或測試框架。
- 保留其他未提交變更；現有 `scripts/setup-common.sh` 已有安裝連結，不必重做。

## 行為決定

```text
repo/
├── .git/          # bare repository
├── main/          # worktree
└── feature/
    └── login/     # branch: feature/login
```

- 分支名稱保留 `/`，遷移與建立使用相同命名，不轉成 `-`。
- `switch/create` 在上述結構下建立 worktree；一般 repo 提示先執行 `init`，不自動遷移。
- `list/remove/prune` 可用於一般 repo。
- `switch` 切換既有分支；全新分支使用 `create`。
- 移除只刪 worktree，保留 branch；不允許移除 bare 容器、main worktree 或目前所在 worktree。
- `remove -s/--silent` 只禁止詢問；需要確認時報錯，不視為同意。`-f` 才跳過確認並強制移除。

## 1. 整理共用基礎

- [ ] 修正參數傳遞為 `"$@"`，檢查必要參數、未知選項與 `--`。
- [ ] 確保 print_utils 的來源路徑有引用，從 repo 或安裝連結執行皆可載入。
- [ ] 以 Git common directory 找到容器根目錄，不用目前目錄或 remote 名稱猜測。
- [ ] 用 `git worktree list --porcelain -z` 取得實際 path、branch、HEAD 與 bare 資訊；不解析顯示用表格。
- [ ] 共用函式留在原檔案；避免以 Zsh 特殊變數 `path`、`status` 作一般變數。
- [ ] 建立前用 Git 驗證分支名稱，拒絕目的地碰撞或透過符號連結逸出容器的路徑。

驗收：從容器、worktree 及子目錄找到同一根目錄；支援空白路徑；無效參數回傳非零。

## 2. init：clone 新 repo

對應「帶參數時 bare clone」TODO。

- [ ] 提供 `init <repository> [directory]`；repository 為來源 URL／本機路徑，directory 預設由來源推導。
- [ ] 要求目的地不存在，執行 bare clone 至 `<directory>/.git`。
- [ ] 補上 origin 的 fetch refspec，fetch 後設定 `origin/HEAD`。
- [ ] 為遠端預設分支建立初始 worktree，設定 upstream。
- [ ] clone、fetch 或預設分支解析失敗就停止，指出留下的目錄；成功才回傳切換路徑。

驗收：用本機來源完成 clone，確認目錄、初始分支與 upstream；目的地已存在或來源無效時報錯；空 repo 明確回報尚無可 checkout 的 commit。

## 3. init：遷移目前 repo

對應「無參數時遷移並保留資料」TODO。

- [ ] 將無參數 `init` 接到既有 `git_migrate_bare()`。
- [ ] 保留現有 repo 根目錄、一般 .git 目錄、linked worktree、submodule、sparse checkout 與進行中 Git 操作限制，不擴充通用檢查。
- [ ] 沒有 commit 時沿用 `git rev-parse HEAD` 的失敗結果，改善錯誤訊息即可。
- [ ] 沿用工作目錄與 index 搬移、`worktree add --no-checkout`；不用 stash 或重新 checkout 取代資料搬移。
- [ ] 套用統一分支目錄規則；detached HEAD 使用 `detached-<short-sha>`。
- [ ] 用 Git 取得新 index 的絕對路徑，避免相對路徑受到呼叫目錄影響。
- [ ] 修改前保存會被改動的 Git 設定；搬移前確認目前 Git 支援既有相對 worktree 路徑設定。
- [ ] 各搬移步驟失敗時明確停止。尚未分散資料時移回原目錄；資料已分散時保留全部資料，列出失敗步驟、資料位置及具體復原命令。
- [ ] 不做任意階段自動回滾，不把已搬空的暫存目錄稱為完整備份。只有驗證成功且舊目錄為空時才清除它。
- [ ] 保留目前遷移前後 Git status 比對；成功才回傳新 worktree 路徑。

驗收：同一 fixture 包含 staged、unstaged、untracked、ignored、隱藏檔與符號連結，遷移後比較內容、Git diff、HEAD 與 refs。另驗證 detached HEAD，以及在 metadata 搬移後、檔案部分搬移後失敗時，資料仍完整且能依回報步驟恢復。失敗模擬只放在測試，不新增 CLI 選項。

## 4. switch 與 create

對應兩個分支操作 TODO。

- [ ] `switch/sw/checkout/co <branch>`：已有 worktree 就使用 Git 登記的實際路徑；路徑不存在則報錯，不另建替代目錄。
- [ ] 本機分支存在但沒有 worktree 時，執行 `git worktree add`。
- [ ] 本機分支不存在但 `origin/<branch>` 存在時，建立 tracking branch 與 worktree；第一版不加入多 remote 自動推斷。
- [ ] 分支不存在就報錯並提示 `create`；switch 不自動 fetch。
- [ ] `create <branch> [base]` 使用 `git worktree add -b`，同名分支已存在就報錯。
- [ ] 未指定 base 時依序解析 `origin/HEAD`、本機 `main`、`master`；都不存在就要求提供 base。
- [ ] 成功才回傳切換路徑，失敗保留 Git 錯誤訊息。

驗收：重用既有 worktree、本機／origin 分支、新分支、指定 base、含 `/` 的分支，以及分支／路徑碰撞。確認全程不修改原 worktree 的工作內容。

## 5. remove

對應依 branch、detached HEAD SHA 或 pattern 移除的 TODO。

- [ ] 依精確 branch、detached HEAD SHA、glob 的順序匹配；glob 比對 branch 或 detached 完整 SHA。
- [ ] 短 SHA 必須唯一解析到 commit；同一 SHA 有多個 detached worktree 時保留全部候選，不以 SHA 作唯一 key。
- [ ] 刪除前檢查保護目標；候選包含目前所在 worktree 時拒絕整批操作。
- [ ] 精確單一目標直接交給 Git；pattern 或共用 SHA 先列出路徑，再確認一次，預設拒絕。
- [ ] 支援 `-f/--force`、`-f -f`、`-ff`，轉交 Git 處理 dirty／locked worktree。
- [ ] silent 或非互動模式遇到必要確認且沒有 `-f` 時回傳非零。
- [ ] 批次某項失敗仍處理其他目標，最後有失敗就回傳非零；不自行使用 `rm -rf`。

驗收：branch、共用 detached SHA、quoted glob、零筆匹配、dirty／locked、保護目標、拒絕確認與部分失敗；確認 branch 未被刪除。

## 6. shellenv 與收尾

對應自動 cd 的 TODO，沿用 tree-me 的簡單 marker 方式，並提供基本 tab completion。

- [ ] 成功的 init／switch／create 輸出 `GIT_WT_CD:<absolute-path>`；一般訊息不得使用此前綴。
- [ ] shellenv 輸出 Bash／Zsh 可載入的 `git-wt()`，以 `command git-wt "$@"` 執行原指令。
- [ ] 同時輸出簡單的 `git()` wrapper：第一個參數為 `wt` 時，移除該參數並呼叫 `git-wt()`；其他情況以 `command git "$@"` 原樣執行，保留參數、輸出與結束碼，不遞迴呼叫自身。
- [ ] wrapper 保存結束碼、顯示一般輸出並過濾 marker；成功且有 marker 才以引用過的 `cd --` 切換，不使用 eval。
- [ ] 兩個入口共用同一套 cd 邏輯；`init`、`switch/sw/checkout/co`、`create` 完整成功後才輸出 marker。切換到既有 worktree 也需 cd；`list/remove/prune/help/shellenv`、取消與失敗均不切換目錄。
- [ ] 保留原指令失敗碼；cd 失敗也回傳非零。marker 採逐行格式，第一版不支援 worktree 路徑含換行字元，需在修改前拒絕。
- [ ] shellenv 依目前 shell 載入對應補全函式：Bash 使用 `complete`，Zsh 使用 `compdef`，只註冊 `git-wt`，不覆寫 Git 的補全。
- [ ] 補全子指令及 aliases；`switch/sw/checkout/co` 補全本機分支與去掉 `origin/` 前綴的遠端分支，排除 `origin/HEAD` 並去重。
- [ ] `create` 的新分支名稱自由輸入，第二個參數 base 補全本機分支與 `origin/*`；`remove/rm` 補全可移除 worktree 的 branch 或 detached HEAD SHA，以及 force／silent 選項。
- [ ] 依子指令與參數位置決定候選，`remove -f <TAB>` 等選項後仍能補全目標；`--` 後不補選項。
- [ ] 補全只查本機 Git 資料，不 fetch、不改變 PWD；repo 外仍可補子指令與選項，分支候選為空且不印 Git 錯誤。
- [ ] 沿用使用者現有的 Zsh completion 初始化；沒有 `compdef` 時略過註冊並保留自動 cd，不自行呼叫 compinit 或引入補全框架。README 說明應在 completion 初始化後載入 shellenv。
- [ ] 合併重複 prune 定義，保留原生 Git 行為與正確結束碼。
- [ ] help 移除 PR，補上 init、aliases、實際目錄與 silent 語義；非 TTY 不因 tput 失敗，help／shellenv 在 repo 外可執行。
- [ ] README 補上 `source <(git-wt shellenv)`、補全與基本使用範例；載入後 `git wt sw <branch>` 與 `git-wt sw <branch>` 都會自動 cd。補全入口仍為 `git-wt`，不在本階段改寫 Git 的補全。
- [ ] 說明自動 cd 的範圍為上述兩個 shell function 入口；未載入 shellenv、使用 `command git wt …` 或 `git -C … wt …` 時仍由外部程序執行，不會切換父 shell。不為 Git 全域選項新增解析器。

驗收：Bash／Zsh 分別以 `git-wt …` 與 `git wt …` 執行 init、sw、create，確認成功後的 PWD，包含重用既有 worktree 與遷移後的新目錄。失敗、取消及不需 cd 的指令維持 PWD；確認空白路徑、原指令／cd 的失敗碼與 repo 外 help。重複載入後不得遞迴呼叫；一般 `git status`、`git -C <path> status` 的輸出與結束碼須和 `command git` 相同。

補全驗收：Bash／Zsh 各檢查子指令、switch 的本機／origin 分支、create 的 base、remove 的 branch／detached SHA 與 `-f` 後候選。確認含 `/` 的分支、repo 外、重複載入與 Zsh 未初始化 completion 均不報錯；補全前後 PWD 與 repo 狀態不變。

## 驗證與交付

新增單一 `tests/git-wt.zsh`，以暫存本機 repositories 覆蓋上述驗收，不引入 Bats 或大型 mock 系統。fixture 隔離使用者 Git 設定與 hooks，不讀取 `.env*`，不重新指定 HOME，不在目前 dotfiles repo 執行測試用搬移／移除。失敗時保留 fixture 並印出位置。

```sh
rtk proxy zsh -n bin/git-wt
rtk proxy zsh -n tests/git-wt.zsh
rtk proxy zsh tests/git-wt.zsh
rtk git diff --check
```

- [ ] 六個 TODO 完成，以上檢查通過。
- [ ] Bash／Zsh 自動 cd 與 tab completion 驗收通過。
- [ ] help／README 與實際行為一致，沒有 PR 功能或 gh 相依。
- [ ] 檢查 diff 及新增檔案，確認沒有修改其他使用者工作。
- [ ] 回報修改、實際驗證結果與限制；不自動 commit 或 push。

Git 行為依據：[git-worktree](https://git-scm.com/docs/git-worktree)、[git-clone](https://git-scm.com/docs/git-clone)。
