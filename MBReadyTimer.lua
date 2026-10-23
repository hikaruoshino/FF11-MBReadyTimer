-- =============================================================================
-- MBReadyTimer.lua : FFXI 自分の魔法の着弾と、次の詠唱ができるまでの硬直を表示するアドオン (v4.4.0)
-- =============================================================================
-- 【概要】
-- 自動キャストは一切行わない受動型アシストツール。
-- 自分の詠唱 → 着弾 → 硬直解除 (次の詠唱可能) を HUD に表示し、自分の魔法の後に
-- 次の魔法をどのタイミングで詠唱できるかを測る。
--
-- 【タイミングの考え方 (v4.2)】
--   - 詠唱開始 : 自分の詠唱開始パケット (category 8)
--   - 着弾     : 自分の魔法完了パケット (category 4) を受け取った時刻 (実測)
--                受け取るまでは、これまでの実測 (FC・精霊魔法の詠唱時間短縮装備・通信の遅れを含む) から予測する。
--                実測がまだ無いときは「基本詠唱時間 × (1 - FC率)」で計算する
--   - 硬直解除 : 着弾 + post_lock_sec (設定値)
--   ※ 連携後の MB 受付の表示は v4.2 で削除した (受付時間は連携を起こす人によって変わり、このアドオンの目的と違うため)
--
-- 【学者の震天連携 (v4.3)】
--   学者は震天動地の章で、自分の魔法 2 発から連携を起こし、そのままマジックバーストまで 1 人で行う。
--   - 震天動地の章の効果中に詠唱した魔法が連携にならなかったとき (1 発目) は、READY の効果音を鳴らさない
--   - 自分の魔法で連携が起きたとき (2 発目) は、硬直が解けた時点で READY を鳴らす (ここからマジックバースト)
--   - 自分の魔法で起きた連携だけ、連携からの経過時間と、その後の魔法がマジックバーストになったかを表示・記録する
--     (自分で起こした連携なので、受付の長さが毎回ほぼ同じ。他の人の連携は今までどおり扱わない)
--   - 連携のあとに撃った魔法 (マジックバースト) の再詠唱の残りを表示する。溶解 → 核熱と続けて 3 回マジックバーストを
--     入れる流れで、3 発目に 1 発目と同じ魔法 (ファイアV) をもう一度撃てるかを見るため
--
-- 【文字コード】
--   - HUD (libs/texts.lua) : UTF-8
--   - チャット (windower.add_to_chat) : Shift-JIS (windower.to_shift_jis)
-- =============================================================================

_addon.name     = "MBReadyTimer"
_addon.author   = "hikaruoshino"
_addon.version  = "4.4.0"
_addon.commands = {"mbtimer", "mbr"}

require("luau")
local config  = require("config")
local texts   = require("texts")
local res     = require("resources")

-- -----------------------------------------------------------------------------
-- デフォルト設定 (data/settings.xml)
-- -----------------------------------------------------------------------------
local defaults = {}
defaults.pos = {x = 500, y = 300}
defaults.text = {font = "Meiryo", size = 11, alpha = 255}
defaults.bg = {alpha = 180, red = 10, green = 10, blue = 15}
defaults.padding = 6
defaults.fc_rate = 0.80        -- ファストキャスト率 (上限80%)
defaults.post_lock_sec = 3.08  -- 着弾から次の詠唱が可能になるまでの秒数
defaults.sound_enabled = true
defaults.show_hud = true
defaults.sc_mode = true         -- 学者の震天連携の動き (1 発目は READY を鳴らさない・連携後の経過表示)
defaults.sc_window_sec = 10.0   -- 連携からマジックバーストの受付が閉じるまでの目安 (表示の目盛りに使うだけ)
defaults.sc_report = true       -- 連携が終わったら、マジックバーストの結果をチャットログに 1 行出す
defaults.lang = "auto"          -- 表示の言語: auto (クライアントの言語に合わせる) / ja / en

local settings = config.load(defaults)

-- 表示の言語。auto のときはゲームクライアントの言語 (windower.ffxi.get_info().language) に合わせる
local LANG
local function resolve_lang()
    local s = tostring(settings.lang or "auto"):lower()
    if s == "ja" or s == "en" then return s end
    local ok, info = pcall(windower.ffxi.get_info)
    local l = ok and info and info.language and tostring(info.language):lower() or "japanese"
    return (l == "japanese") and "ja" or "en"
end
LANG = resolve_lang()

-- 日本語と英語の文を対で書く。言語に合わせたほうを返す
local function L(ja, en)
    if LANG == "ja" then return ja end
    return en
end

-- 魔法・系統の名前。日本語クライアントは日本語、英語クライアントは英語
local function res_name(entry)
    if not entry then return nil end
    if LANG == "ja" then return entry.ja or entry.en end
    return entry.en or entry.ja
end

-- -----------------------------------------------------------------------------
-- 定数
-- -----------------------------------------------------------------------------
local REFRESH_SEC = 0.05          -- HUD 更新間隔 (毎フレームの文字列生成を避ける)
local READY_SHOW_SEC = 2.5        -- READY 表示を続ける秒数
local LAND_TIMEOUT_SEC = 10.0     -- 予測の着弾時刻をこの秒数過ぎても着弾パケットが来なければ、待機中に戻す (パケットの取りこぼし対策)
local INTERRUPT_PARAM = 28787     -- category 8 の詠唱中断
local MSG_MAGIC_BURST = 252       -- 「Magic Burst!」ダメージ
local MSG_MAGIC_DAMAGE = 2        -- 魔法の通常のダメージ (マジックバーストにならなかった)
local IMMANENCE_BUFF = 470        -- 震天動地の章
local SC_TRACK_SEC = 15.0         -- 連携のあと、この秒数まで自分の魔法の結果を記録する (受付が閉じた後の 1 発も残すため)
local RECAST_POLL_SEC = 0.25      -- 再詠唱の残りを読み直す間隔 (全魔法の表を取るので、毎フレームは読まない)
local RECAST_KEEP_SEC = 8.0       -- 再詠唱が明けてから、この秒数だけ「撃てます」を表示して消す
local RECAST_MAX_SEC = 90.0       -- 見張りを続ける上限 (何かの理由で残りが読めなくても、ここで消す)
-- 技連携の追加効果メッセージ → 連携の名前
local SKILLCHAIN_MESSAGES = {}
do
    local order = LANG == "ja"
        and {"光", "闇", "重力", "分解", "湾曲", "核熱", "収縮", "溶解", "硬化", "振動", "貫通", "切断", "炸裂", "衝撃"}
        or {"Light", "Darkness", "Gravitation", "Fragmentation", "Distortion", "Fusion", "Compression", "Liquefaction", "Induration", "Reverberation", "Transfixion", "Scission", "Detonation", "Impaction"}
    for i, name in ipairs(order) do
        SKILLCHAIN_MESSAGES[287 + i] = name
        SKILLCHAIN_MESSAGES[384 + i] = name
    end
    local radiance, umbra = L("極光", "Radiance"), L("黒闇", "Umbra")
    SKILLCHAIN_MESSAGES[767] = radiance; SKILLCHAIN_MESSAGES[769] = radiance
    SKILLCHAIN_MESSAGES[768] = umbra; SKILLCHAIN_MESSAGES[770] = umbra
end
local SOUND_FILE = windower.addon_path .. "sounds/ready.wav"

-- -----------------------------------------------------------------------------
-- ヘルパー
-- -----------------------------------------------------------------------------
local function chat_msg(msg, color)
    color = color or 207
    if LANG == "ja" and windower.to_shift_jis then
        local ok, converted = pcall(windower.to_shift_jis, tostring(msg))
        if ok and converted then
            windower.add_to_chat(color, converted)
            return
        end
    end
    windower.add_to_chat(color, tostring(msg))
end

local function color_text(str, r, g, b)
    return string.format("\\cs(%d,%d,%d)%s\\cr", r, g, b, tostring(str or ""))
end

local function num(v, default)
    return tonumber(v) or default
end

local function fc_rate()
    return math.max(0, math.min(0.8, num(settings.fc_rate, 0.8)))
end

local function effective_cast(base)
    return base * (1.0 - fc_rate())
end

-- -----------------------------------------------------------------------------
-- 実測による詠唱時間の予測
--   自分の「詠唱開始 → 着弾」の実測時間を、魔法の系統 (精霊魔法など) と基本詠唱時間ごとに覚えて予測に使う。
--   実測には FC・精霊魔法の詠唱時間短縮装備・通信の遅れがすべて含まれるので、計算で足し合わせるより実際に近い。
--   予測の順: 同じ系統・同じ基本詠唱時間の実測 → 同じ系統の「実測 ÷ 基本」の比率 → FC 率だけの計算
-- -----------------------------------------------------------------------------
local ELEMENTAL_SKILL = 36        -- res/skills.lua の精霊魔法
local LEARN_WEIGHT = 0.3          -- 新しい実測をどれだけ重く見るか (残りはこれまでの平均)
local LEARN_MIN_RATIO = 0.1       -- 「実測 ÷ 基本」がこの範囲から外れたら、異常値として覚えない
local LEARN_MAX_RATIO = 1.2       --   (クイックマジック・大きなラグなど)
local SPEEDUP_BUFFS = {[362] = true, [363] = true}  -- 電光石火の章 / 疾風迅雷の章 (詠唱時間半減。覚えない)

local learned = {}                -- [系統] = {ratio = 比率, count = 回数, by_base = {[基本詠唱時間] = 秒}}

local function blend(old, new)
    if not old then return new end
    return old + (new - old) * LEARN_WEIGHT
end

local function learn_cast(skill, base, measured)
    if not skill or not base or base <= 0 then return end
    local ratio = measured / base
    if ratio < LEARN_MIN_RATIO or ratio > LEARN_MAX_RATIO then return end
    local l = learned[skill] or {count = 0, by_base = {}}
    learned[skill] = l
    l.ratio = blend(l.ratio, ratio)
    l.by_base[base] = blend(l.by_base[base], measured)
    l.count = l.count + 1
end

-- 予測の実効詠唱時間と、実測を使ったかどうか
local function predict_cast(skill, base)
    local l = skill and learned[skill]
    if l then
        if l.by_base[base] then return l.by_base[base], true end
        if l.ratio then return base * l.ratio, true end
    end
    return effective_cast(base), false
end

local function bar(progress, len, fill_char)
    progress = math.max(0, math.min(1, progress))
    local filled = math.floor(progress * len + 0.5)
    return string.rep(fill_char, filled) .. string.rep("-", len - filled)
end

local function play_sound()
    if settings.sound_enabled and windower.file_exists and windower.file_exists(SOUND_FILE) then
        windower.play_sound(SOUND_FILE)
    end
end

-- -----------------------------------------------------------------------------
-- 状態
-- -----------------------------------------------------------------------------
local state = {
    cast = {
        active = false,
        spell_name = "",
        base = 0,
        skill = nil,       -- 魔法の系統 (res/skills.lua の番号)
        start = 0,
        predicted = 0,     -- 予測した実効詠唱時間
        from_learned = false, -- 予測に実測を使ったか
        learnable = false, -- この詠唱の実測を覚えてよいか (詠唱時間半減のバフ中は覚えない)
        landed_at = nil,   -- 着弾パケットを受け取った時刻
        ready_signaled = false,
        immanence = false, -- 震天動地の章の効果中に詠唱した魔法か
        sc_name = nil,     -- この魔法で起きた連携の名前 (起きなければ nil)
    },
    sc = nil,                  -- 自分の魔法で起きた連携 {name = 名前, at = 時刻, casts = {{name, t, mb}, ...}}
    recast_watch = {},         -- 連携のあとに撃った魔法の再詠唱 [魔法の番号] = {name, landed_at, remaining, polled_at, total, ready_at}
    last_recast_poll = 0,
    last_measured_cast = nil,  -- 直近の実測詠唱時間 (FC の確認用)
    mb_success_at = nil,       -- 自分の魔法がマジックバーストになった時刻
    last_refresh = 0,
    last_error_at = -100,
}

local hud = texts.new("", settings)

-- 大きさ変更の目印「◢」: HUD の右下の角に重ねて表示する別のテキスト (背景なし・移動不可)
local GRIP_COLOR     = {150, 150, 150}  -- 通常
local GRIP_COLOR_HOT = {255, 220, 100}  -- 角にカーソルが乗っている / 大きさ変更中
local grip = texts.new("◢", {
    pos = {x = 0, y = 0},
    text = {font = "Meiryo", size = 10, alpha = 230, red = GRIP_COLOR[1], green = GRIP_COLOR[2], blue = GRIP_COLOR[3]},
    bg = {visible = false},
    flags = {draggable = false},
    padding = 0,
})
local grip_hot = false

-- 目印を HUD の右下の角に合わせる (文字サイズは HUD に比例)
local function update_grip()
    if not hud:visible() then
        grip:hide()
        return
    end
    local size = math.max(8, math.floor((tonumber(hud:size()) or 11) * 0.9 + 0.5))
    if grip:size() ~= size then grip:size(size) end
    local c = grip_hot and GRIP_COLOR_HOT or GRIP_COLOR
    grip:color(c[1], c[2], c[3])
    local px, py = hud:pos()
    local w, h = hud:extents()
    local gw, gh = grip:extents()
    if px and py and w and h and gw and gh then
        grip:pos(px + w - gw, py + h - gh)
    end
    grip:show()
end

-- -----------------------------------------------------------------------------
-- HUD 生成
-- -----------------------------------------------------------------------------
local function build_cast_lines(lines, now)
    local c = state.cast
    if not c.active then
        table.insert(lines, string.format(L("状態: %s", "Status: %s"), color_text(L("待機中 (Idle)", "Idle"), 180, 180, 180)))
        return
    end

    local elapsed = now - c.start
    local post = num(settings.post_lock_sec, 3.08)

    if not c.landed_at then
        -- 1. 詠唱中 (着弾パケット待ち)
        local remaining = c.predicted - elapsed
        table.insert(lines, string.format(L("魔法: %s (基本%.1fs / 予測詠唱%.2fs / %s)", "Spell: %s (base %.1fs / est. cast %.2fs / %s)"),
            color_text(c.spell_name, 255, 220, 100), c.base, c.predicted,
            c.from_learned and L("実測から予測", "from measured") or string.format(L("FC%d%%で計算", "FC %d%% calc"), math.floor(fc_rate() * 100 + 0.5))))
        if remaining >= 0 then
            table.insert(lines, string.format(L("状態: %s [%s] 着弾まで%.2fs", "Status: %s [%s] lands in %.2fs"),
                color_text(L("詠唱中...", "Casting..."), 255, 180, 50), bar(elapsed / math.max(c.predicted, 0.01), 15, "="), remaining))
        else
            table.insert(lines, string.format(L("状態: %s [%s] 予測より+%.2fs", "Status: %s [%s] +%.2fs over estimate"),
                color_text(L("着弾待ち", "Waiting for landing"), 255, 180, 50), bar(1, 15, "="), -remaining))
        end
        return
    end

    local since_land = now - c.landed_at
    if since_land < post then
        -- 2. 着弾後の硬直中
        table.insert(lines, string.format(L("魔法: %s (着弾済 / 実測詠唱%.2fs)", "Spell: %s (landed / measured cast %.2fs)"),
            color_text(c.spell_name, 255, 150, 150), state.last_measured_cast or 0))
        table.insert(lines, string.format(L("状態: %s [%s] 次の詠唱まで%.2fs", "Status: %s [%s] next cast in %.2fs"),
            color_text(L("硬直中", "Locked"), 255, 80, 80), bar(since_land / math.max(post, 0.01), 15, "#"), post - since_land))
        if settings.sc_mode and c.sc_name then
            table.insert(lines, color_text(L("連携・" .. c.sc_name .. " 発生 → 硬直が解けたらマジックバースト", "Skillchain " .. c.sc_name .. " -> magic burst when the lock ends"), 255, 230, 80))
        elseif settings.sc_mode and c.immanence then
            table.insert(lines, color_text(L("震天 1 発目 (READY の音は鳴らしません)", "Immanence 1st spell (no READY sound)"), 180, 180, 180))
        end
        return
    end

    -- 3. 硬直解除 (効果音と待機中への切り替えは update_state で行う)
    if settings.sc_mode and c.immanence and not c.sc_name then
        -- 震天の 1 発目: 次の魔法は連携の 2 発目なので、マジックバーストの合図は出さない
        table.insert(lines, color_text(L("震天 1 発目の硬直解除 (次の魔法で連携)", "Immanence 1st spell done (next spell makes the skillchain)"), 180, 180, 180))
    elseif settings.sc_mode and c.sc_name then
        table.insert(lines, color_text(L("★ READY! 連携・" .. c.sc_name .. " → マジックバースト", "★ READY! Skillchain " .. c.sc_name .. " -> Magic Burst"), 50, 255, 100))
    else
        table.insert(lines, color_text(L("★ READY! (硬直解除・次の詠唱可)", "★ READY! (you can cast now)"), 50, 255, 100))
    end
end

-- 自分の魔法で起きた連携の表示: 連携からの経過と、その後の魔法の結果
local function build_sc_lines(lines, now)
    local sc = state.sc
    if not (settings.sc_mode and sc) then return end
    local elapsed = now - sc.at
    local window = math.max(1, num(settings.sc_window_sec, 10.0))
    if elapsed <= window then
        table.insert(lines, string.format(L("連携: %s [%s] %.1fs 経過 (目安 残り%.1fs)", "Skillchain: %s [%s] %.1fs elapsed (about %.1fs left)"),
            color_text(sc.name, 255, 230, 80), bar(elapsed / window, 15, ">"), elapsed, window - elapsed))
    else
        table.insert(lines, string.format(L("連携: %s %s (%.1fs 経過)", "Skillchain: %s %s (%.1fs elapsed)"),
            color_text(sc.name, 180, 180, 180), color_text(L("受付の目安を過ぎました", "window has probably closed"), 180, 180, 180), elapsed))
    end
    for i, cast in ipairs(sc.casts) do
        table.insert(lines, string.format(L("  %d 発目 %s %.1fs後 %s", "  #%d %s at %.1fs %s"), i, cast.name, cast.t,
            cast.mb and color_text("MB", 255, 230, 80) or color_text(L("MB ならず", "no MB"), 255, 120, 120)))
    end
end

-- 連携のあとに撃った魔法の再詠唱の残り (3 発目にもう一度同じ魔法を撃てるかを見る)
local function build_recast_lines(lines, now)
    if not settings.sc_mode then return end
    local ids = {}
    for id in pairs(state.recast_watch) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b) return state.recast_watch[a].landed_at < state.recast_watch[b].landed_at end)
    for _, id in ipairs(ids) do
        local w = state.recast_watch[id]
        if w.remaining then
            -- 読み直すまでの間は、前に読んだ値から経過分を引いて表示する
            local left = w.remaining - (now - w.polled_at)
            if left > 0.05 then
                table.insert(lines, string.format(L("再詠唱: %s あと%.1fs", "Recast: %s %.1fs left"), color_text(w.name, 255, 150, 150), left))
            else
                table.insert(lines, string.format(L("再詠唱: %s %s", "Recast: %s %s"), color_text(w.name, 50, 255, 100), color_text(L("撃てます", "ready"), 50, 255, 100)))
            end
        end
    end
end

-- 再詠唱の残りを読み直す。初めて読めたときに、着弾からの再詠唱時間 (実測) をチャットログに残す
local function poll_recasts(now)
    if next(state.recast_watch) == nil then return end
    if now - state.last_recast_poll < RECAST_POLL_SEC then return end
    state.last_recast_poll = now
    local recasts = windower.ffxi.get_spell_recasts() or {}
    for id, w in pairs(state.recast_watch) do
        local remaining = (tonumber(recasts[id]) or 0) / 60   -- get_spell_recasts は 1/60 秒単位
        w.remaining, w.polled_at = remaining, now
        if remaining > 0 then
            w.ready_at = nil
            if not w.total then
                w.total = remaining + (now - w.landed_at)
                if settings.sc_report then
                    chat_msg(string.format(L("[MBReadyTimer] %s の再詠唱時間: %.1f秒 (着弾から)", "[MBReadyTimer] %s recast: %.1fs (from landing)"), w.name, w.total))
                end
            end
        else
            w.ready_at = w.ready_at or now
        end
        if (w.ready_at and now - w.ready_at > RECAST_KEEP_SEC) or now - w.landed_at > RECAST_MAX_SEC then
            state.recast_watch[id] = nil
        end
    end
end

-- 連携の記録を閉じる。マジックバーストを狙った魔法があれば、結果をチャットログに 1 行残す
local function close_sc()
    local sc = state.sc
    state.sc = nil
    if not (sc and settings.sc_report and #sc.casts > 0) then return end
    local parts, mb_count = {}, 0
    for _, cast in ipairs(sc.casts) do
        if cast.mb then mb_count = mb_count + 1 end
        parts[#parts + 1] = string.format(L("%s %.1fs後%s", "%s at %.1fs%s"), cast.name, cast.t, cast.mb and "" or L(" (MBならず)", " (no MB)"))
    end
    chat_msg(string.format(L("[MBReadyTimer] 連携・%s: MB %d 回 / %s", "[MBReadyTimer] Skillchain %s: %d MB / %s"), sc.name, mb_count, table.concat(parts, " -> ")))
end

-- 時間の経過で変わる状態を進める。HUD の表示とは別に毎回行う (HUD を消していても READY の効果音を鳴らすため)
local function update_state(now)
    local c = state.cast
    if state.sc and now - state.sc.at > SC_TRACK_SEC then
        close_sc()
    end
    if settings.sc_mode then poll_recasts(now) end
    if c.active and not c.landed_at and now - c.start > c.predicted + LAND_TIMEOUT_SEC then
        c.active = false
        return
    end
    if c.active and c.landed_at then
        local since_ready = now - c.landed_at - num(settings.post_lock_sec, 3.08)
        if since_ready >= 0 and not c.ready_signaled then
            c.ready_signaled = true
            -- 震天の 1 発目 (連携にならなかった震天中の魔法) では鳴らさない。連携が起きた魔法では鳴らす
            if not (settings.sc_mode and c.immanence and not c.sc_name) then
                play_sound()
            end
        end
        if since_ready >= READY_SHOW_SEC then
            c.active = false
        end
    end
end

local last_text = nil   -- 前回 HUD に設定した文字列 (同じなら設定し直さない)

local function render(now)
    local lines = {}
    table.insert(lines, color_text("=== [ MB Ready Timer v" .. _addon.version .. " ] ===", 200, 220, 255))
    build_cast_lines(lines, now)
    build_sc_lines(lines, now)
    build_recast_lines(lines, now)
    if state.mb_success_at and now - state.mb_success_at < 3.0 then
        table.insert(lines, color_text(L("★ マジックバースト成功！", "★ Magic Burst!"), 255, 230, 80))
    end
    -- texts の text() は設定のたびに文字列を解析し直すので、変わったときだけ設定する (待機中は毎回同じ)
    local text = table.concat(lines, string.char(10))
    if text ~= last_text then
        hud:text(text)
        last_text = text
    end
    if not hud:visible() then hud:show() end
    update_grip()
end

local function report_error(now, label, err)
    -- 毎フレーム同じエラーでチャットを埋めないよう 10 秒に 1 回だけ知らせる
    if now - state.last_error_at > 10 then
        state.last_error_at = now
        chat_msg("[MBReadyTimer] " .. label .. ": " .. tostring(err), 167)
    end
end

windower.register_event("prerender", function()
    local now = os.clock()
    if now - state.last_refresh < REFRESH_SEC then return end
    state.last_refresh = now

    local ok, err = pcall(update_state, now)
    if not ok then report_error(now, L("状態更新エラー", "state update error"), err) end

    if not settings.show_hud then
        if hud:visible() then hud:hide() end
        if grip:visible() then grip:hide() end
        return
    end
    ok, err = pcall(render, now)
    if not ok then report_error(now, L("表示エラー", "display error"), err) end
end)

-- -----------------------------------------------------------------------------
-- アクション検知
-- -----------------------------------------------------------------------------
local function on_own_cast_start(act)
    if act.param == INTERRUPT_PARAM then
        -- 詠唱中断: 硬直は発生しないものとして表示を止める
        state.cast.active = false
        return
    end
    local target = act.targets and act.targets[1]
    local action = target and target.actions and target.actions[1]
    local spell = action and res.spells[action.param]
    if not spell then return end

    local base = num(spell.cast_time, 3.0)
    local c = state.cast
    c.active = true
    c.spell_name = res_name(spell) or "?"
    c.base = base
    c.skill = spell.skill
    c.start = os.clock()
    c.predicted, c.from_learned = predict_cast(c.skill, base)
    c.landed_at = nil
    c.ready_signaled = false
    c.immanence = false
    c.sc_name = nil

    -- 電光石火の章・疾風迅雷の章 (詠唱時間半減) の間の実測は、普段の予測に混ぜない
    -- (get_player は自分の詠唱開始のときだけ呼ぶ)
    c.learnable = true
    local player = windower.ffxi.get_player()
    for _, buff in ipairs(player and player.buffs or {}) do
        if SPEEDUP_BUFFS[buff] then c.learnable = false end
        if buff == IMMANENCE_BUFF then c.immanence = true end
    end
    -- 震天で新しい連携を組み始めたら、前の連携の記録はここで閉じる
    if c.immanence and state.sc then close_sc() end
end

local function on_own_cast_finish(act, now)
    local c = state.cast
    if c.active and not c.landed_at then
        c.landed_at = now
        state.last_measured_cast = now - c.start
        if c.learnable then learn_cast(c.skill, c.base, state.last_measured_cast) end
    end
    local sc_name, result = nil, nil
    for _, target in ipairs(act.targets or {}) do
        local action = target.actions and target.actions[1]
        if action then
            if action.message == MSG_MAGIC_BURST then
                state.mb_success_at = now
                result = true
            elseif action.message == MSG_MAGIC_DAMAGE and result == nil then
                result = false
            end
            if action.has_add_effect and SKILLCHAIN_MESSAGES[action.add_effect_message] then
                sc_name = SKILLCHAIN_MESSAGES[action.add_effect_message]
            end
        end
    end

    if sc_name then
        -- 自分の魔法で連携が起きた: ここからの経過と、後に続く魔法の結果を記録する
        if state.sc then close_sc() end
        c.sc_name = sc_name
        state.sc = {name = sc_name, at = now, casts = {}}
    elseif state.sc and result ~= nil and not c.immanence then
        -- 連携のあとに撃った魔法: マジックバーストになったかどうかを残す
        local spell = res.spells[act.param]
        local name = res_name(spell) or c.spell_name
        table.insert(state.sc.casts, {name = name, t = now - state.sc.at, mb = result})
        -- この魔法の再詠唱の残りを見張る (同じ魔法をもう一度撃ったら、新しい着弾から数え直す)
        state.recast_watch[act.param] = {name = name, landed_at = now}
        state.last_recast_poll = 0
    end
end

-- 自分の ID。action は周りの全員の行動ごとに届くので、毎回 get_player() (大きな表を作る) を呼ばずに覚えておく
local player_id = nil
local function get_player_id()
    if not player_id then
        local player = windower.ffxi.get_player()
        player_id = player and player.id or nil
    end
    return player_id
end

windower.register_event("action", function(act)
    -- 自分の詠唱開始 (8) と魔法の完了 (4) だけを見る。周りの人の行動はここで捨てる
    if act.category ~= 8 and act.category ~= 4 then return end
    local ok, err = pcall(function()
        if act.actor_id ~= get_player_id() then return end
        if act.category == 8 then
            on_own_cast_start(act)
        else
            on_own_cast_finish(act, os.clock())
        end
    end)
    if not ok then report_error(os.clock(), L("アクション処理エラー", "action error"), err) end
end)

-- -----------------------------------------------------------------------------
-- HUD の拡大縮小 (マウス)
--   ・HUD の上でホイール            : 文字サイズを 1 ずつ拡大/縮小
--   ・HUD の右下の角をクリック＆ドラッグ : 大きさを変更 (角以外のドラッグは従来どおり移動)
-- -----------------------------------------------------------------------------
local MOUSE_MOVE, MOUSE_LEFT_DOWN, MOUSE_LEFT_UP, MOUSE_WHEEL = 0, 1, 2, 10
local SIZE_MIN, SIZE_MAX = 6, 40
local RESIZE_HANDLE_PX = 18      -- 右下の角とみなす範囲 (px)

local resize = nil               -- ドラッグで大きさを変えている最中の情報
local move_allowed = settings.flags == nil or settings.flags.draggable ~= false  -- 元の「ドラッグで移動」設定

local function current_size()
    return num(hud:size(), num(settings.text and settings.text.size, 11))
end

local function set_size(size)
    size = math.max(SIZE_MIN, math.min(SIZE_MAX, math.floor(size + 0.5)))
    if size ~= current_size() then
        hud:size(size)
    end
    return size
end

-- 角の判定で一時的に止めた「ドラッグで移動」を元に戻してから保存する
local function save_settings()
    if hud:draggable() ~= move_allowed then hud:draggable(move_allowed) end
    config.save(settings)
end

local function in_resize_handle(x, y)
    if not hud:visible() then return false end
    local px, py = hud:pos()
    local w, h = hud:extents()
    if not (px and py and w and h) then return false end
    return x >= px + w - RESIZE_HANDLE_PX and x <= px + w and y >= py + h - RESIZE_HANDLE_PX and y <= py + h
end

-- HUD のマウス操作 (true を返すとクリックをゲームに渡さない)
local function on_mouse(mtype, x, y, delta, blocked)
    if blocked or not settings.show_hud then return end

    if mtype == MOUSE_MOVE then
        if resize then
            -- ドラッグした分だけ、幅・高さの伸び率の大きい方に合わせて文字サイズを変える
            local rx = (resize.w + (x - resize.x)) / math.max(resize.w, 1)
            local ry = (resize.h + (y - resize.y)) / math.max(resize.h, 1)
            set_size(resize.size * math.max(rx, ry))
            update_grip()
            return true
        end
        -- 角の上では libs/texts の「ドラッグで移動」を止め、クリックをこちらで受け取る
        local on_handle = in_resize_handle(x, y)
        if move_allowed then
            local want = not on_handle
            if hud:draggable() ~= want then hud:draggable(want) end
        end
        -- 角に乗ったら目印を光らせる
        if on_handle ~= grip_hot then
            grip_hot = on_handle
            update_grip()
        end

    elseif mtype == MOUSE_LEFT_DOWN then
        if in_resize_handle(x, y) then
            local w, h = hud:extents()
            resize = {x = x, y = y, w = w, h = h, size = current_size()}
            return true
        end

    elseif mtype == MOUSE_LEFT_UP then
        if resize then
            resize = nil
            save_settings()
            return true
        end

    elseif mtype == MOUSE_WHEEL then
        if hud:hover(x, y) then
            local step = (tonumber(delta) or 0) > 0 and 1 or -1
            set_size(current_size() + step)
            save_settings()
            update_grip()
            return true
        end
    end
end

-- エラーが起きてもマウスの処理を止めず、大きさ変更の途中なら解除する (OmniChain と同じ)
windower.register_event("mouse", function(mtype, x, y, delta, blocked)
    local ok, result = pcall(on_mouse, mtype, x, y, delta, blocked)
    if ok then return result end
    resize = nil
    if hud:draggable() ~= move_allowed then hud:draggable(move_allowed) end
    report_error(os.clock(), L("マウス処理エラー", "mouse error"), result)
end)

-- -----------------------------------------------------------------------------
-- クリーンアップ
-- -----------------------------------------------------------------------------
local function reset_state()
    state.cast.active = false
    state.mb_success_at = nil
end

windower.register_event("zone change", reset_state)
windower.register_event("logout", function()
    reset_state()
    player_id = nil   -- 別のキャラクターでログインし直したときのため
end)
windower.register_event("unload", function()
    if hud then
        if hud:draggable() ~= move_allowed then hud:draggable(move_allowed) end
        hud:hide()
    end
    if grip then grip:destroy() end
end)

-- -----------------------------------------------------------------------------
-- コマンド (//mbr または //mbtimer)
-- -----------------------------------------------------------------------------
windower.register_event("addon command", function(cmd, ...)
    local args = {...}
    cmd = cmd and cmd:lower()

    if cmd == "pos" and tonumber(args[1]) and tonumber(args[2]) then
        settings.pos.x = tonumber(args[1])
        settings.pos.y = tonumber(args[2])
        save_settings()
        hud:pos(settings.pos.x, settings.pos.y)
        chat_msg(string.format(L("[MBReadyTimer] HUD位置を変更しました: X=%d, Y=%d", "[MBReadyTimer] HUD position set: X=%d, Y=%d"), settings.pos.x, settings.pos.y))

    elseif cmd == "post" and tonumber(args[1]) then
        local sec = tonumber(args[1])
        if sec > 0 and sec <= 10 then
            settings.post_lock_sec = sec
            save_settings()
            chat_msg(string.format(L("[MBReadyTimer] 着弾後の硬直を %.2f秒 に設定しました。", "[MBReadyTimer] Lock after landing set to %.2fs."), sec))
        end

    elseif cmd == "fc" and tonumber(args[1]) then
        local fc_val = tonumber(args[1])
        if fc_val >= 0 and fc_val <= 80 then
            settings.fc_rate = fc_val / 100.0
            save_settings()
            chat_msg(string.format(L("[MBReadyTimer] FC率を %d%% に変更しました。", "[MBReadyTimer] FC rate set to %d%%."), fc_val))
        end

    elseif cmd == "learn" then
        -- //mbr learn : 覚えている実測の一覧 / //mbr learn reset : 忘れる (装備を大きく変えたとき)
        if args[1] and args[1]:lower() == "reset" then
            learned = {}
            chat_msg(L("[MBReadyTimer] 実測の記録を消しました。次の詠唱から覚え直します。", "[MBReadyTimer] Measurements cleared. It will learn again from your next cast."))
            return
        end
        local any = false
        for skill, l in pairs(learned) do
            any = true
            local skill_name = res_name(res.skills[skill]) or tostring(skill)
            chat_msg(string.format(L("[MBReadyTimer] %s: 実測 %d回 / 基本に対する比率 %.2f (実効FC 約%d%%)", "[MBReadyTimer] %s: %d measurements / ratio to base %.2f (effective FC about %d%%)"),
                skill_name, l.count, l.ratio, math.floor((1 - l.ratio) * 100 + 0.5)))
            local bases = {}
            for base in pairs(l.by_base) do bases[#bases + 1] = base end
            table.sort(bases)
            for _, base in ipairs(bases) do
                chat_msg(string.format(L("    基本%.1fs → 実測平均 %.2fs", "    base %.1fs -> measured average %.2fs"), base, l.by_base[base]))
            end
        end
        if not any then
            chat_msg(L("[MBReadyTimer] まだ実測がありません。魔法を詠唱すると覚えます (それまでは FC 率で計算)。", "[MBReadyTimer] No measurements yet. It learns as you cast (until then it uses the FC rate)."))
        end

    elseif cmd == "size" and tonumber(args[1]) then
        local size = set_size(tonumber(args[1]))
        save_settings()
        chat_msg(string.format(L("[MBReadyTimer] HUD の文字サイズを %d に変更しました。", "[MBReadyTimer] HUD text size set to %d."), size))

    elseif cmd == "sound" then
        settings.sound_enabled = not settings.sound_enabled
        save_settings()
        chat_msg(string.format(L("[MBReadyTimer] 効果音通知: %s%s", "[MBReadyTimer] Sound: %s%s"), settings.sound_enabled and "ON" or "OFF",
            (windower.file_exists and not windower.file_exists(SOUND_FILE)) and L(" (sounds/ready.wav がありません)", " (sounds/ready.wav not found)") or ""))

    elseif cmd == "hud" then
        settings.show_hud = not settings.show_hud
        save_settings()
        chat_msg(string.format(L("[MBReadyTimer] HUD表示: %s", "[MBReadyTimer] HUD: %s"), settings.show_hud and "ON" or "OFF"))

    elseif cmd == "sc" then
        -- //mbr sc : 学者の震天連携の動きの ON/OFF / //mbr sc window <秒> : 受付の目安 / //mbr sc report : 結果の 1 行の ON/OFF
        local sub = args[1] and args[1]:lower()
        if sub == "window" and tonumber(args[2]) then
            local sec = tonumber(args[2])
            if sec >= 3 and sec <= 15 then
                settings.sc_window_sec = sec
                save_settings()
                chat_msg(string.format(L("[MBReadyTimer] 連携からの受付の目安を %.1f秒 にしました。", "[MBReadyTimer] Skillchain window estimate set to %.1fs."), sec))
            else
                chat_msg(L("[MBReadyTimer] 秒数は 3〜15 で指定してください (例: //mbr sc window 10)。", "[MBReadyTimer] Use 3 to 15 seconds (e.g. //mbr sc window 10)."))
            end
        elseif sub == "report" then
            settings.sc_report = not settings.sc_report
            save_settings()
            chat_msg(string.format(L("[MBReadyTimer] 連携ごとの結果の 1 行: %s", "[MBReadyTimer] One-line skillchain result: %s"), settings.sc_report and "ON" or "OFF"))
        else
            settings.sc_mode = not settings.sc_mode
            if not settings.sc_mode then state.sc = nil; state.recast_watch = {} end
            save_settings()
            chat_msg(string.format(L("[MBReadyTimer] 学者の震天連携の動き: %s", "[MBReadyTimer] Scholar Immanence skillchain mode: %s"), settings.sc_mode and "ON" or "OFF"))
        end

    elseif cmd == "status" then
        chat_msg(string.format(L("[MBReadyTimer] 学者の震天連携の動き: %s / 受付の目安 %.1f秒 / 結果の 1 行 %s", "[MBReadyTimer] Scholar Immanence skillchain mode: %s / window estimate %.1fs / one-line result %s"),
            settings.sc_mode and "ON" or "OFF", num(settings.sc_window_sec, 10.0), settings.sc_report and "ON" or "OFF"))
        chat_msg(string.format(L("[MBReadyTimer] FC %d%% (実測が無いときに使用) / 着弾後の硬直 %.2f秒", "[MBReadyTimer] FC %d%% (used when there is no measurement) / lock after landing %.2fs"),
            math.floor(fc_rate() * 100 + 0.5), num(settings.post_lock_sec, 3.08)))
        if state.last_measured_cast and state.cast.base > 0 then
            local real_fc = 1 - state.last_measured_cast / state.cast.base
            chat_msg(string.format(L("[MBReadyTimer] 直近の実測: %s 基本%.1fs → %.2fs (実効FC 約%d%%)", "[MBReadyTimer] Last measurement: %s base %.1fs -> %.2fs (effective FC about %d%%)"),
                state.cast.spell_name, state.cast.base, state.last_measured_cast, math.floor(real_fc * 100 + 0.5)))
        end

    elseif cmd == "lang" then
        -- //mbr lang auto|ja|en : 表示の言語。設定は保存され、読み込み直し (//lua r mbreadytimer) で切り替わる
        local v = args[1] and args[1]:lower()
        if v == "auto" or v == "ja" or v == "en" then
            settings.lang = v
            save_settings()
            chat_msg("[MBReadyTimer] Language: " .. v .. " (reload with //lua r mbreadytimer to apply)")
        else
            chat_msg("[MBReadyTimer] Language: " .. tostring(settings.lang) .. " (now " .. LANG .. "). Use //mbr lang auto|ja|en")
        end

    elseif cmd == "test" then
        -- ジャ系の詠唱 → 着弾 → 硬直 → READY を模擬表示
        local now = os.clock()
        local c = state.cast
        c.active = true
        local test_name = L("サンダジャ", "Thundaja")
        c.spell_name = test_name
        c.base = 7.0
        c.skill = ELEMENTAL_SKILL
        c.start = now
        c.predicted, c.from_learned = predict_cast(ELEMENTAL_SKILL, 7.0)
        c.learnable = false   -- テストの着弾は実測として覚えない
        c.immanence = false
        c.sc_name = nil
        c.landed_at = nil
        c.ready_signaled = false
        -- 着弾パケットの代わりに予測時刻で着弾させる
        coroutine.schedule(function()
            if c.active and not c.landed_at and c.spell_name == test_name then
                c.landed_at = os.clock()
                state.last_measured_cast = c.landed_at - c.start
            end
        end, c.predicted)
        chat_msg(L("[MBReadyTimer] テスト表示を開始します (サンダジャの詠唱 → 着弾 → 硬直 → READY)。", "[MBReadyTimer] Test started (Thundaja cast -> landing -> lock -> READY)."))

    else
        chat_msg(L("=== MBReadyTimer コマンドヘルプ ===", "=== MBReadyTimer commands ==="))
        chat_msg(L("//mbr fc <FC率>       : FC率を変更 (例: //mbr fc 80)", "//mbr fc <rate>       : set the FC rate (e.g. //mbr fc 80)"))
        chat_msg(L("//mbr post <秒>       : 着弾後の硬直秒数を設定 (例: //mbr post 3.08)", "//mbr post <sec>      : set the lock after landing (e.g. //mbr post 3.08)"))
        chat_msg(L("//mbr status          : 現在の設定と直近の実測詠唱時間を表示", "//mbr status          : show settings and the last measured cast time"))
        chat_msg(L("//mbr learn [reset]   : 予測に使っている実測の一覧 / reset で消して覚え直す", "//mbr learn [reset]   : list the measurements used for prediction / reset to learn again"))
        chat_msg(L("//mbr sc              : 学者の震天連携の動き ON/OFF (震天 1 発目は READY を鳴らさない・連携後の経過を表示)", "//mbr sc              : Scholar Immanence skillchain mode ON/OFF (no READY sound on the 1st spell, shows time since the skillchain)"))
        chat_msg(L("//mbr sc window <秒>  : 連携からの受付の目安 (3〜15、初期値 10)", "//mbr sc window <sec> : skillchain window estimate (3-15, default 10)"))
        chat_msg(L("//mbr sc report       : 連携ごとの結果 (何秒後の魔法が MB になったか) の 1 行 ON/OFF", "//mbr sc report       : one-line result per skillchain (which spell burst, and when) ON/OFF"))
        chat_msg(L("//mbr pos <x> <y>     : HUD表示位置の変更 (例: //mbr pos 600 400)", "//mbr pos <x> <y>     : move the HUD (e.g. //mbr pos 600 400)"))
        chat_msg(L("//mbr size <数>       : HUD の文字サイズ (6〜40)。HUD上のホイール / 右下の角のドラッグでも変更可", "//mbr size <n>        : HUD text size (6-40). The mouse wheel or the bottom-right corner also works"))
        chat_msg(L("//mbr sound           : READY効果音 ON/OFF", "//mbr sound           : READY sound ON/OFF"))
        chat_msg(L("//mbr hud             : HUD表示 ON/OFF", "//mbr hud             : HUD ON/OFF"))
        chat_msg("//mbr lang auto|ja|en : " .. L("表示の言語", "display language"))
        chat_msg(L("//mbr test            : 表示テスト", "//mbr test            : show a test display"))
    end
end)
