# OleOle Move Controller

Ableton Move（Move Everything / move-anything 環境）向けの、iPad専用ライブパフォーマンス用MIDI CCコントローラーです。

- 4本のスライダー
- 4つのXYパッド（名前付きMIDI設定を切り替えて使える。マルチタッチで同時に操作可能）
- ストップウォッチ
- Move Mirror Display（128×64 OLEDのミラー表示）

これらをすべて1画面に並べています。画面遷移、タブ、縦スクロールはありません。

- 対象: iPadOS 17以降、横画面専用（`TARGETED_DEVICE_FAMILY = 2`）
- 使用フレームワーク: SwiftUI、Observation、Core MIDI、WebKit、Network
- 外部ライブラリ: なし
  - 参考アプリでは AudioKit `Controls` の XYPad を使っていましたが、本アプリでは同じ見た目と操作を SwiftUI `Canvas` と `DragGesture(minimumDistance: 0)` で実装しました。

---

## 1. 接続構成

```
iPad（USBホスト） ── USB-C ── Ableton Move（Standalone）
      │                               │
      └──── Wi-Fi（同じネットワーク）──┘   ← Mirror Display 用（USBネットワークが無い場合）
```

### MIDI（USB-C）

1. iPadとMoveをUSB-Cケーブルで直結します。
   - データ転送に対応したケーブルを使ってください。充電専用ケーブルではMIDIが通りません。
2. アプリを起動すると、Core MIDIのDestinationを列挙します。
   - 名前、メーカー名、モデル名に "move" を含むか、メーカー名に "ableton" を含むポートを自動で選びます。
   - 該当するポートが無い場合は、USBポートを選びます。
   - ポート名をコードに固定していません。
3. 最上段の MIDI 表示が `USB MIDI · <ポート名>` になれば接続済みです。
4. 接続先を手動で選ぶ場合は、最上段の MIDI 表示または ⚙ から **SETTINGS → MIDI OUTPUT** を開きます。
   - 選んだ接続先は保存されます。保存するのは uniqueID と名前で、再接続時は uniqueID、次に名前の順で照合します。
   - 手動で選んだ機器が見つからないときは `WAITING` と表示し、ほかの機器へは送信しません。
5. USBの抜き差しには自動で対応します。
   - 抜いた時点で送信を止めます（`DROP` としてログに記録）。
   - 挿し直すと自動で再接続し、送信を再開します。
   - 再接続後に **SEND ALL** を押すと、全コントロールの現在値を送り直せます。

### Move側でCCを受け取るには（重要）

**iPadは Move の USB-C ポートにつないでください。USB-A ポートではMIDIが通りません。**

- MoveのUSB-Aはホスト側の端子で、USB MIDI**デバイス**を挿すための口です。iPadは汎用のUSB MIDIデバイスとして振る舞えないので、USB-Aに挿してもMIDIの経路ができません。
- MoveのUSB-Cにホスト（iPad）をつなぐと、Moveは「Ableton Move」として複数のMIDIポート（Live / User / External / Standalone）を出します。
- [Schwung](https://github.com/charlesvestal/schwung)（旧 Move Everything）が外部MIDI（cable 2）として受け取るのは、**Standalone Port** に送ったMIDIだけです（Schwung の `docs/SYSEX.md` にある実測結果）。
  - このアプリは自動選択で Standalone Port を最優先にします。
- 届いたCCは、Schwung の CC map / CC learn で割り当てます。各スライダーとXYパッドの設定（名前を長押し）にある SEND / TEST / SEND X/Y/BOTH は、この学習のときに使ってください。
- Ableton Move の標準ファームウェアだけでは、任意のCCを割り当てる機能は限られています。

## 2. Mirror Display の有効化

[move-anything の MANUAL.md](https://github.com/peterjungx/move-anything/blob/main/MANUAL.md) の「Display Mirror」の手順です。

1. Moveで **Shift + Vol + Step 2** を押し、Global Settings を開きます。
2. **Display → Mirror Display** を **On** にします。この設定は再起動後も保持されます。
3. ブラウザで `http://move.local:7681` を開くと、Moveの画面が表示されます。

### 配信方式（`src/host/display_server.c` を調査した結果）

| 項目 | 内容 |
|---|---|
| サーバー | ポート7681のHTTPサーバー（起動時に自動で立ち上がり、Mirror OFF中は待機） |
| `GET /` | HTML。`<canvas width=128 height=64>` と描画用のJS |
| `GET /stream` | **Server-Sent Events**。1フレームは1024バイト（SSD1306形式、8ページ×128列、1bit/px）をbase64化したもの。約30Hzで、画面に変化があったときだけ送られる |
| 同時接続 | 最大8クライアント |

本アプリでは、この配信ページを **WKWebView でそのまま表示**しています。独自のストリーミング処理は実装していません。
ページには次のCSSとJSだけを注入しています。

- 黒背景にして、canvasをビュー全体に拡大する（`image-rendering: pixelated`）
- 枠線とステータス表示を消す
- ネオンブルーの着色（設定でOFFにすると白黒表示）
- ページ内の `#status`（`connected - 30 fps` など）の文字列をネイティブ側に渡し、接続状態として表示する

WebViewは表示専用です。スクロール、ピンチズーム、タッチ操作はすべて無効にしています。

### 表示する経路（USB優先）

- 既定のURLは **`http://172.16.254.1:7681`** です。
  - 172.16.254.1 は、USB-Cでつないだときの Move のアドレスです（[Ableton公式ヘルプ](https://help.ableton.com/hc/en-us/articles/14645140037788-Troubleshooting-Move-network-connections)に記載）。
  - display_server は全インターフェースで待ち受けているので、USB-Cケーブルだけでミラー表示できます。
  - 以前の既定値 `http://move.local:7681` が保存されていた場合は、起動時に自動でUSBのアドレスへ移行します。
- **USBに届かないときはWi-Fiで表示**します（設定で切り替え可能、既定はON）。
  - USBで読み込めないと、すぐ `move.local`（Wi-Fi）で表示を試みます。
  - Wi-Fiで表示している間は、15秒ごとにUSB側を確認し、復帰していればUSBに戻します。
  - ケーブルを抜くなどしてストリームが5秒戻らなければ、経路を切り替えて読み直します。
- メイン画面の「Disp」の下に、表示中の経路（`USB` / `Wi-Fi` / `LAN`）を小さく表示します。
- 設定画面の **USB 172.16.254.1** / **Wi-Fi move.local** ボタンで、明示的に切り替えることもできます。
- **NETWORK PATH CHECK** では、有線（USB Ethernet）、Wi-Fi、経路を限定しない場合のそれぞれで、配信ページに届くかを確かめます。

接続に失敗すると、エラーを表示したうえで自動的に再試行します。未接続のときにMirror表示をタップすると、すぐに再接続します。
Mirror Display がつながらなくても、MIDI操作には影響しません。

---

## 3. 画面と操作

参考アプリ（OleOleMIDICon）のデザインに合わせています。

- 画面にはライブ中に触るものだけを置いています。枠付きのボタン、パネル、ログは置いていません。
- 設定は**長押し**で開きます。設定は画面中央のシートで表示し、スクロールできるので、画面外に見切れません。

| 位置 | 内容 | 操作 |
|---|---|---|
| 最上段 | アプリ名、M（MIDI接続中は光る）、ストップウォッチ | アプリ名かMを**長押し** → 全体設定。時間表示を**タップ** → START/STOP、**長押し** → RESET |
| 左上 | Move Mirror Display（空いた面積で最大の2:1）。左下に表示経路（USB / Wi-Fi） | 未接続のときに**タップ** → 再接続 |
| 右上 | スライダー S1〜S4 | スライダーをドラッグ。名前を**長押し** → スライダーの設定 |
| 左下 | XY 1 / XY 2 | 下記参照 |
| 右下 | XY 3 / XY 4 | 下記参照 |

### スライダー

- 参考アプリの ModWheel と同じ見た目・大きさです（65×210pt、濃紺の角丸に青い横バー）。
- **相対ドラッグ方式**です。上へ動かすと値が増えます。スライダーの高さが0〜127の全域に相当し、タッチした位置で値が飛ぶことはありません。
- 名前の長押しで開く設定では、名前、MIDI CH、CCの変更と、SEND / TEST / 0 / 64 / 127 の送信ができます。
  - **TEST** は 0→127→現在値 の順に、約1秒かけて値を送るスイープです。

### XYパッド

- XYパッドは**2つで1セット**です。左下が SET 1（XY 1・XY 2）、右下が SET 2（XY 3・XY 4）です。
- セットごとに**名前付きのMIDI設定を最大16個**持てます。1つのMIDI設定には、2パッド分（各パッドの X/Y の CH・CC・反転）が入ります。
  - セットの下の **◁ 名前 ▷** をタップすると、2つのパッドがまとめて切り替わります。
  - 切り替えただけではMIDIを送信しません（受信側のパラメーターが急に変わらないように）。
  - マーカーの位置はMIDI設定ごとに記憶し、切り替えるとその設定の最後の位置に戻ります。
- MIDI設定の名前を**長押し**すると、設定シートが開きます。
  - MIDI設定の追加（選択中の設定を複製し、各CCを+2）、削除、並べ替え、名前の変更ができます。
  - 2つのパッドそれぞれの X/Y の MIDI CH・CC、Reverse X/Y、ON/OFF、SEND X / Y / BOTH、CENTER もここで操作します。

- 左端が X=0、右端が X=127、下端が Y=0、上端が Y=127 です。
- 動作の流れ
  - タッチした瞬間に値を更新して送信します。
  - ドラッグ中はリアルタイムに送信します。
  - 指を離したときは、最終値を必ず送信します。
  - 指を離しても、最後の位置を保持します。
- ON/OFF
  - OFFのときは、パッドを操作してもMIDIを送信しません（マーカーは動きます）。
  - SEND X / Y / BOTH は、CCラーニング用の明示的な操作なので、OFFのときでも送信します。
  - **CENTER** は X=64、Y=64 に移動し、ONのときだけ送信します。
- Reverse X / Reverse Y は軸ごとに送信値を反転します（`127 - v`）。既定はOFFです。
- 各パッドは、それぞれ独立した `DragGesture` を持っています。スライダーも含めて、別々の指で同時に操作できます。

### ストップウォッチ

- 計測は「開始時刻」と「積算時間」から計算しています。画面の更新回数には依存しません。
- バックグラウンドから戻ったときや、アプリを再起動した後も、正しい経過時間を表示します。状態は保存されています。
- 動作中は、参考アプリと同じく背景のグラデーションが暗い青に変わります。
- SETTINGS でミリ秒表示（`HH:MM:SS.mmm`）に切り替えられます。

---

## 4. MIDI 実装

- 送信APIの流れ
  - 準備: `MIDIClientCreateWithBlock` → `MIDIOutputPortCreate`
  - 送信先の取得: `MIDIGetNumberOfDestinations` / `MIDIGetDestination`
  - 送信: `MIDISendEventList`（MIDI 1.0 プロトコル、UMP Message Type 2）
- メッセージ形式: `Status = 0xB0 | (channel - 1)`、`Data1 = CC番号`、`Data2 = 値`
  - UMPワードは `0x2g_Bn_cc_vv` です（g はグループ）。
- 抜き差しの検知: `msgSetupChanged`、`msgObjectAdded`、`msgObjectRemoved`、`msgPropertyChanged` の通知を受けて再列挙します。
- 送信の流れ
  - 送信処理は、SwiftUI Viewから分離した `MIDISendEngine` が担当します。専用のシリアルキュー（QoS `.userInteractive`）で動きます。
  - 間引き（`CCThrottle`）はコントロールごと（スライダー1本、またはXYの1軸ごと）に独立しています。
    - 同じ値は連続して送りません。
    - 送信頻度は最大60Hzです。間隔内に来た値は保留し、最新の値だけを後で送ります。
    - タッチ終了時の最終値は、間隔に関係なくすぐに送ります。
    - SENDボタンなどの明示的な送信は、同じ値でも必ず送ります。
  - 接続先がない、または送信エラーが起きた場合は、そのメッセージを `DROP` / `ERR` として記録します。間引きの記憶もリセットするので、再接続後は同じ値でも送信されます。
- デバッグログ
  - 送信スレッドからロック付きのリングバッファ（300件）に追記します。
  - UIは `TimelineView` で、0.2秒ごとに読み出すだけです。SwiftUIの監視対象にしていないので、送信のたびに画面を再描画することはありません。
  - ログはOFFにでき、OFFでも送信数は数えます。
- **Loopback test port**（SETTINGS）
  - アプリ内に仮想MIDI Destinationを作ります。それを接続先に選ぶと、実際にCore MIDIを通ったバイト列を `RX` としてログに表示します。
  - ハードウェアなしで送信内容を確かめるための機能です。
  - iOSで仮想エンドポイントを作るには `UIBackgroundModes: audio` が必要なので、Info.plistに設定しています。

---

## 5. 設定の保存

`AppConfiguration`（Codable）をJSONにして UserDefaults に保存します。

- 操作中は0.6秒のデバウンスをかけて保存します。バックグラウンドへ移ったときは、すぐに保存します。
- 保存する内容
  - 4本のスライダーの名前、CH/CC、最終値
  - XYパッドの名前付きMIDI設定（各軸のCH/CC、反転、位置）、選択中の設定、ON/OFF
  - MIDI接続先の識別情報
  - Mirror Display の URLと着色設定
  - ストップウォッチの状態
  - ログ設定
- 保存データにないキーは既定値で補います。将来、項目が増えても既存の設定は壊れません。

初期値:

| | CH | CC |
|---|---|---|
| S1〜S4 | 1 | 20, 21, 22, 23 |
| XY 1 X / Y | 1 / 1 | 24 / 25 |
| XY 2 X / Y | 1 / 1 | 26 / 27 |
| XY 3 X / Y | 1 / 1 | 28 / 29 |
| XY 4 X / Y | 1 / 1 | 30 / 31 |

**SETTINGS → RESET CH/CC TO DEFAULTS** で、コントロールの設定を初期値に戻せます。

---

## 6. ライブ運用のための設定

- 起動中は自動スリープしません（`isIdleTimerDisabled`）。
- 画面端のシステムジェスチャより、アプリの操作を優先します（`defersSystemGestures`）。ステータスバーとホームインジケータは隠しています。
- スクロールするViewはありません。Mirror表示のWebViewもタッチを受け付けません。
- 描画の負荷を抑える工夫
  - `@Observable` でプロパティ単位に監視しているので、1つのコントロールを動かしても、ほかのコントロールは再描画されません。
  - スライダーとXYパッドは `Canvas` で描いています。グロー効果は、位置に依存しない背面レイヤーに付けています。
- タップや長押しを受け付ける文字は、どれも高さ44pt以上の当たり判定を持たせています。スライダーとXYパッドは本体全体が当たり判定です。

---

## 7. ビルド

```bash
open OleOleMoveController.xcodeproj
```

- Scheme: `OleOleMoveController`
- 実機で動かす場合は、Signing & Capabilities で Team を設定してください（初期値は参考プロジェクトと同じTeamです）。
- テストの実行:

```bash
xcodebuild test -project OleOleMoveController.xcodeproj -scheme OleOleMoveController -destination 'platform=iOS Simulator,name=iPad Pro (11-inch) (4th generation)'
```

### ファイル構成

| ファイル | 役割 |
|---|---|
| `OleOleMoveControllerApp.swift` | エントリポイント、スリープ防止、ScenePhaseに応じた保存と再接続 |
| `ContentView.swift` | 1画面レイアウト（`ControllerLayout` で各エリアの寸法を計算）、最上段と下段のパネル |
| `MIDIMessage.swift` | `ControlChange`（バイト列とUMP）、`CCValueMapper`、`CCThrottle`。Core MIDIに依存しない純粋なロジック |
| `MIDIManager.swift` | Core MIDI のクライアントとポート、接続先の列挙・自動選択・抜き差し対応、`MIDISendEngine`、`MIDILog` |
| `MIDIControlConfiguration.swift` | 永続化する設定の型 |
| `ConfigurationStore.swift` | UserDefaults への保存と読み込み（デバウンス付き） |
| `ControllerModels.swift` | `KnobModel`、`XYPadModel`、`AppModel` |
| `SliderView.swift` | スライダー |
| `XYPadView.swift` | XYパッド（MIDI設定の切り替え ◁ ▷ を含む） |
| `StopwatchView.swift` | ストップウォッチ（ロジックと表示） |
| `MoveMirrorView.swift` | WKWebView による Mirror 表示、`MirrorController` |
| `MirrorDiagnostics.swift` | USB/Wi-Fi 経路ごとの到達性チェック、インターフェースの監視 |
| `SettingsView.swift` | スライダー・XYパッド（MIDI設定の管理）・全体の設定シート |
| `Theme.swift` | 配色、Futura フォント、`Neon` / `BlueShadow`（参考アプリ由来） |

---

## 8. 検証状況

| # | 項目 | 状態 |
|---|---|---|
| 1 | iPad横画面でレイアウトが収まる | ✅ `LayoutTests` で主要6機種のサイズを計算上検証。実機（iPad Pro 11" M4）へインストールして起動済み。**目視確認は未実施** |
| 2 | 4スライダーの独立操作 | ✅ 相対ドラッグをユニットテストで検証。実機での操作は未確認 |
| 3 | 2つのXYパッドの同時操作 | ⚠️ 各パッドが独立した `DragGesture` を持つ構造。**実機での同時操作は未確認** |
| 4 | 各軸のCH/CC設定の独立 | ✅ ユニットテスト |
| 5 | 正しいMIDI CCメッセージの出力 | ✅ ステータスバイト・データバイト・UMPのユニットテストに加え、Core MIDIの仮想ポート（ループバック）を実際に通す結合テストで `B2 16 63` / `BF 1B 00` を受信して確認 |
| 6 | SEND操作で現在値を送信 | ✅ ユニットテスト（force送信） |
| 7 | USBの抜き差し | ⚠️ 切断中は送信を止め、再接続後に再送するロジックをユニットテストで検証。**実機でのUSB抜き差しは未検証** |
| 8 | 再起動後も設定を維持 | ✅ 保存と読み込み、欠けたキーの補完をユニットテストで検証。実機での再起動確認は未実施 |
| 9 | ストップウォッチ | ✅ ユニットテスト（時刻からの計算、RESET、時計の逆行） |
| 10 | Mirror Displayの接続 | ⚠️ モックサーバー（`Tools/mock_display_server.py`）がHTTPとSSEで応答することは確認。**アプリ内での表示と実機Moveでの表示は未検証** |
| 11 | Mirror接続失敗時もUIが動作 | ⚠️ 設計上、MIDIとは独立（失敗時はエラー表示と自動再試行）。**動作確認は未実施** |

**ハードウェアが必要なため未検証の項目**

- Ableton Move を実際に USB-C でつないだときの、MIDIポート名、自動検出、CC受信
- USB-C ケーブルだけで HTTP（Mirror）に到達できるか
  - Move が iPad に対して USB Ethernet として見えるかどうかは、アプリ内の NETWORK PATH CHECK で確かめられます。
- 実機での同時マルチタッチ、レイテンシー

### モックサーバーで Mirror を試す

Mac で次のコマンドを実行し、シミュレーター側で URL を `http://localhost:7681` にします。

```bash
python3 Tools/mock_display_server.py
```
