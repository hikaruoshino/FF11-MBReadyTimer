# MBReadyTimer (v4.4.0)

English follows the Japanese section. → [English](#english)

**ファイナルファンタジーXI（Windower 4用） 自分の魔法の「着弾」と「次の詠唱ができるまで」を見える化するアドオン**

`MBReadyTimer` は、自分が唱えた魔法が着弾してから、次の魔法を詠唱できるようになるまでの時間を HUD に表示する Windower 4 用アドオンです。黒魔道士のマジックバースト（MB）で「次の魔法をいつ唱え始められるか」を目で見て確かめるために作りました。v4.3 からは、学者が震天動地の章で 1 人で連携からマジックバーストまで行うときの表示にも対応しています。

**自動で魔法を唱える機能はありません。** 表示と効果音でタイミングを知らせるだけの、見るためのツールです。

---

## 🔗 GitHub 公式リポジトリ

👉 **[https://github.com/hikaruoshino/FF11-MBReadyTimer](https://github.com/hikaruoshino/FF11-MBReadyTimer)**

---

## 🌟 主な機能

* **詠唱 → 着弾 → 硬直 → READY を表示**
  * 詠唱中は「着弾までの残り」、着弾後は「次の詠唱ができるまでの残り」をバーと秒数で表示します。
  * 硬直が解けると「★ READY!」を表示し、効果音を鳴らします（効果音は下の「効果音を鳴らすには」を参照）。
* **実測から詠唱時間を予測**
  * 自分の「詠唱開始 → 着弾」の実際の時間を覚えて、次からの予測に使います。
  * ファストキャスト・精霊魔法の詠唱時間短縮装備・通信の遅れが、すべて含まれた時間になります。
  * 実測がまだ無いうちは、設定した FC 率（初期値 80%）で計算します。
  * 電光石火の章・疾風迅雷の章（詠唱時間半減）の間や、クイックマジックのような極端に短い詠唱は、普段の予測に混ぜません。
* **マジックバーストの成功表示**
  * 自分の魔法がマジックバーストになると「★ マジックバースト成功！」を表示します。
* **学者の震天連携に対応（v4.3）**
  * 震天動地の章の効果中に唱えた 1 発目（まだ連携になっていない魔法）では、READY の効果音を鳴らしません。
  * 自分の魔法で連携が起きると、硬直が解けたところで「★ READY! 連携・核熱 → マジックバースト」のように表示し、効果音を鳴らします。
  * 連携からの経過時間と、その後に撃った魔法がマジックバーストになったかを表示します。
  * 連携のあとに撃った魔法の再詠唱の残りを表示します（同じ魔法をもう一度撃てるかの確認用）。
  * 詳しくは下の「学者の震天連携」を参照してください。
* **HUD の大きさ・位置を自由に変更**
  * ドラッグで移動、HUD の上でマウスホイール、または右下の「◢」をドラッグで大きさを変えられます。位置と大きさは保存されます。

---

## 📂 インストール方法

1. GitHub リポジトリを開き、**Code → Download ZIP** でファイル一式をダウンロードします。
2. ZIP を解凍し、フォルダー名を **`MBReadyTimer`** にします。
   ※ GitHub の ZIP は `FF11-MBReadyTimer-main` という名前で解凍されるので、`MBReadyTimer` に直してください。フォルダー名が違うと読み込めません。
3. `Windower4/addons/` に `MBReadyTimer` フォルダーごと置きます。
4. ゲーム内で `//lua l mbreadytimer` を打って読み込みます。
5. `//mbr test` で表示を確認できます。

必要なのは **Windower 4** だけです。使っているライブラリはすべて Windower に最初から入っています。

---

## 🖥 HUD について

* HUD は、読み込んでいる間はいつも表示されます（魔法を唱えていないときは「待機中」）。
* 魔法を使わないジョブのときなど、消したいときは **`//mbr hud`** で表示を切り替えられます。HUD を消していても、READY の効果音は鳴ります。

---

## ⏱ 硬直の秒数を自分の環境に合わせる

着弾から次の詠唱ができるまでの秒数は、初期値で **3.08 秒** にしています。これは作者の環境で測った値で、通信環境によって少し変わります。

* READY が出てもまだ唱えられないときは、秒数を増やします（例: `//mbr post 3.2`）。
* READY が出る前から唱えられるときは、秒数を減らします（例: `//mbr post 3.0`）。

---

## 📖 学者の震天連携（v4.3）

学者は震天動地の章を使うと、自分の魔法 2 発で連携を起こし、そのまま 1 人でマジックバーストまで行えます。このとき、これまでの版では 1 発目の魔法でも READY の効果音が鳴っていました。v4.3 では、連携が起きたところで READY を知らせます。

| 場面 | 表示と効果音 |
| :--- | :--- |
| 震天 1 発目（連携になっていない） | 「震天 1 発目 (READY の音は鳴らしません)」。効果音は鳴りません |
| 震天 2 発目（自分の魔法で連携が起きた） | 硬直が解けたら「★ READY! 連携・核熱 → マジックバースト」。効果音が鳴ります |
| 連携のあと | 連携からの経過時間、撃った魔法が何秒後に着弾してマジックバーストになったか、その魔法の再詠唱の残り |

表示の例（数字は例です）:

```
連携: 核熱 [>>>>>>>--------] 4.8s 経過 (目安 残り5.2s)
  1 発目 ファイアV 4.6s後 MB
再詠唱: ファイアV あと6.3s
```

* 連携から 15 秒たつと、結果をチャットログに 1 行出します（例: `[MBReadyTimer] 連携・核熱: MB 2 回 / ファイアV 4.6s後 → ファイアIV 8.9s後`）。`//mbr sc report` で消せます。
* 連携のあとに撃った魔法は、再詠唱時間（着弾から数えた秒数）もチャットログに 1 行出します。
* 経過時間のバーの長さ（初期値 10 秒）は**目安**です。実際のマジックバーストの受付時間を測ったものではありません。`//mbr sc window <秒>` で変えられます。
* 扱うのは**自分の魔法で起きた連携だけ**です。ほかの人が起こした連携は、今までどおり表示しません。
* 学者以外のジョブでは、今までと同じ動きです。この動きが要らないときは `//mbr sc` で切れます。

---

## 🔔 効果音を鳴らすには（お好きな wav を使えます）

READY の効果音は、アドオンには入っていません。**お好きな wav ファイルを置くと、その音が鳴ります。**

1. `Windower4/addons/MBReadyTimer/` の中に **`sounds`** フォルダーを作ります。
2. 鳴らしたい音の wav ファイルを **`ready.wav`** という名前にして、`sounds` フォルダーに置きます。

```
Windower4/addons/MBReadyTimer/
├─ MBReadyTimer.lua
└─ sounds/
   └─ ready.wav   ← お好きな wav ファイル
```

* ファイル形式は **wav** だけです（mp3 などは鳴りません）。
* 作者は [otosozai.com](https://otosozai.com/) の効果音を使っています。素材の再配布は同サイトのルールで禁止されているため、このアドオンには同梱していません。使う場合は、同サイトの「ご利用のルール」を読んだうえで、ご自身でダウンロードしてください。
* ファイルを置いたあと、読み込み直す必要はありません。次の READY から鳴ります。
* 効果音の ON / OFF は `//mbr sound` で切り替えられます。ファイルが無いときは、`//mbr sound` を打つと「sounds/ready.wav がありません」と表示されます。

---

## 💻 コマンド一覧（`//mbr` または `//mbtimer`）

| コマンド | 内容 |
| :--- | :--- |
| `//mbr learn` | 予測に使っている実測の一覧（系統ごとの回数・実効FC・基本詠唱時間ごとの平均） |
| `//mbr learn reset` | 実測を消して覚え直す（装備を大きく変えたときなど） |
| `//mbr fc <FC率>` | 実測が無いときに使う FC 率（例: `//mbr fc 80`） |
| `//mbr post <秒>` | 着弾から次の詠唱ができるまでの秒数（例: `//mbr post 3.08`） |
| `//mbr status` | 現在の設定と直近の実測詠唱時間 |
| `//mbr sc` | 学者の震天連携の動きの ON / OFF |
| `//mbr sc window <秒>` | 連携からの経過時間のバーの長さ（3〜15、初期値 10。目安） |
| `//mbr sc report` | 連携ごとの結果・再詠唱時間をチャットログに出す ON / OFF |
| `//mbr pos <x> <y>` | HUD の位置 |
| `//mbr size <数>` | HUD の文字サイズ（6〜40） |
| `//mbr sound` | 効果音の ON / OFF |
| `//mbr hud` | HUD の ON / OFF（OFF でも効果音は鳴ります） |
| `//mbr lang auto` / `ja` / `en` | 表示の言語（初期値は auto = クライアントの言語。読み込み直しで切り替わります） |
| `//mbr test` | 表示テスト |

`//mbr` だけを打つと、コマンドの一覧が出ます。

---

## ⚠️ 注意事項

* 実測はアドオンを読み込み直すと消えます。数回詠唱すると、また覚えます。
* 「着弾」は、自分の魔法の完了パケットを受け取った時刻です。
* 詠唱を始めたあと、予測の時刻を 10 秒過ぎても着弾を受け取れなかったときは、表示を待機中に戻します。
* 表示とチャットの文言は、ゲームクライアントの言語に合わせて日本語か英語になります。`//mbr lang ja` / `//mbr lang en` で固定できます（`//mbr lang auto` で元に戻る。読み込み直しで切り替わります）。英語クライアントでは未確認です。
* 外部ツールの利用は自己責任でお願いします。

---

## 📜 動作環境・ライセンス

* **作者**: hikaruoshino
* **動作環境**: Windower 4（日本語クライアントで確認。英語クライアントは英語表示に対応していますが、未確認です）
* **使用ライブラリ**: `luau`, `config`, `texts`, `resources`（すべて Windower 標準）
* **ライセンス**: MIT License

---

## 📜 更新履歴（Changelog）

* **v4.4.0 (2026-10-22)**
  * 英語表示に対応。ゲームクライアントの言語に合わせて自動で切り替わる（`//mbr lang auto|ja|en`）。魔法名・連携名も英語で出す。英語クライアントでの動作は未確認。
* **v4.3.0 (2026-10-12)**
  * 学者の震天連携に対応。震天動地の章の 1 発目では READY の効果音を鳴らさず、自分の魔法で連携が起きたところで READY を知らせる。
  * 自分の魔法で起きた連携について、経過時間と、その後の魔法がマジックバーストになったかを表示・記録する。
  * 連携のあとに撃った魔法の再詠唱の残りを表示する。
  * `//mbr sc`・`//mbr sc window <秒>`・`//mbr sc report` を追加。
* **v4.2.0 (2026-10-10)**
  * 連携後の MB 受付の表示を削除（受付時間は連携を起こす人によって変わり、このアドオンの目的と違うため）。
  * 着弾を受け取れなかったとき、表示が「着弾待ち」のまま止まらないようにした。
  * `//mbr lock`（ジャ系の残り%で硬直を指定する旧方式）を削除。硬直は `//mbr post <秒>` で指定する。
  * READY の効果音を同梱しない形に変更（好きな wav を `sounds/ready.wav` に置く）。
* **v4.1.0**
  * 自分の「詠唱開始 → 着弾」の実測を覚えて、詠唱時間の予測に使うようにした。
  * HUD の大きさをマウスホイールと右下の角のドラッグで変えられるようにした。
* **v3.2.0 (2026-10-04)**
  * 最初の公開版。

---

<a id="english"></a>

## English

MBReadyTimer is a Windower 4 addon for FINAL FANTASY XI. It shows when your own spell lands and when you can cast the next one, so you can time magic bursts.

It reads your own actions and draws a HUD. It never sends anything to the game, and it does not cast for you.

**Not tested on the English client yet.** The display switches to English automatically when the client is English (`//mbr lang ja|en|auto` to force it), but I have only played it on the Japanese client.

### What it shows

- Time left until the spell lands, then until you can cast again (bar and seconds).
- "READY!" when the recast is over, with a sound if you add your own wav (see below).
- "Magic Burst!" when your spell bursts.
- Scholar: skillchains made with your own spells (Immanence). The first spell does not play the READY sound. When your second spell makes the skillchain, you get READY, the time since the skillchain, whether each following spell burst, and the recast left on it.

### How it predicts

It remembers how long your last casts took from start to landing, so Fast Cast, gear and lag are already in the number. Until it has a measurement it uses the FC rate you set (default 80%). "Landing" is the moment your client receives the packet saying the spell finished.

The lock after landing is 3.08 s by default, measured on my setup. If READY appears before you can actually cast, raise it (`//mbr post 3.2`). If you can cast before READY, lower it.

### Install

1. On GitHub, click Code, then Download ZIP.
2. Unzip it and rename the folder to `MBReadyTimer`. The ZIP unzips as `FF11-MBReadyTimer-main`, and the addon will not load under that name.
3. Put the folder in `Windower4/addons/`.
4. In game: `//lua l mbreadytimer`. `//mbr test` shows the display.

Only Windower 4 is needed.

### Sound

No sound is included. Put any wav file at `Windower4/addons/MBReadyTimer/sounds/ready.wav` (create the `sounds` folder). Only wav works. You do not need to reload. `//mbr sound` turns the sound on and off.

### Commands (`//mbr` or `//mbtimer`)

| Command | What it does |
| :--- | :--- |
| `//mbr` | List the commands |
| `//mbr test` | Show a test display |
| `//mbr status` | Current settings and the last measured cast time |
| `//mbr learn` / `//mbr learn reset` | List the measurements used for prediction / clear them |
| `//mbr fc <rate>` | FC rate used when there is no measurement (e.g. `//mbr fc 80`) |
| `//mbr post <sec>` | Lock after landing (e.g. `//mbr post 3.08`) |
| `//mbr sc` | Scholar Immanence skillchain mode on / off |
| `//mbr sc window <sec>` | Length of the skillchain timer bar (3-15, default 10; a rough guide, not a measured window) |
| `//mbr sc report` | One-line skillchain result and recast time in the chat log, on / off |
| `//mbr pos <x> <y>` | HUD position (you can also drag it) |
| `//mbr size <n>` | HUD text size, 6-40 (the mouse wheel or the bottom-right corner also works) |
| `//mbr sound` | READY sound on / off |
| `//mbr hud` | HUD on / off (the sound still plays) |
| `//mbr lang auto` / `ja` / `en` | Display language (reload to apply) |

### Notes

- Measurements are lost when you reload the addon. It learns again after a few casts.
- If the landing packet does not arrive within 10 s of the estimate, the HUD goes back to idle.
- Only skillchains made by your own spells are shown. Other players' skillchains are ignored.
- The HUD uses the Meiryo font by default. If your Windows does not have it, change `text.font` in `data/settings.xml`.
- Use of external tools is at your own risk.

Released under the MIT License. Author: hikaruoshino.
