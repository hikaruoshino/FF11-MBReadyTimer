-- =============================================================================
-- MBReadyTimer.lua : FFXI 自分の魔法の着弾と、次の詠唱ができるまでの硬直を表示するアドオン (v4.2.0)
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
-- 【文字コード】
--   - HUD (libs/texts.lua) : UTF-8
--   - チャット (windower.add_to_chat) : Shift-JIS (windower.to_shift_jis)
-- =============================================================================

_addon.name     = "MBReadyTimer"
_addon.author   = "hikaruoshino"
_addon.version  = "4.2.0"
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

local settings = config.load(defaults)

-- -----------------------------------------------------------------------------
-- 定数
-- -----------------------------------------------------------------------------
local REFRESH_SEC = 0.05          -- HUD 更新間隔 (毎フレームの文字列生成を避ける)
local READY_SHOW_SEC = 2.5        -- READY 表示を続ける秒数
local LAND_TIMEOUT_SEC = 10.0     -- 予測の着弾時刻をこの秒数過ぎても着弾パケットが来なければ、待機中に戻す (パケットの取りこぼし対策)
local INTERRUPT_PARAM = 28787     -- category 8 の詠唱中断
local MSG_MAGIC_BURST = 252       -- 「Magic Burst!」ダメージ
local SOUND_FILE = windower.addon_path .. "sounds/ready.wav"

-- -----------------------------------------------------------------------------
-- ヘルパー
-- -----------------------------------------------------------------------------
local function chat_msg(msg, color)
    color = color or 207
    if windower.to_shift_jis then
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
    },
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
        table.insert(lines, string.format("状態: %s", color_text("待機中 (Idle)", 180, 180, 180)))
        return
    end

    local elapsed = now - c.start
    local post = num(settings.post_lock_sec, 3.08)

    if not c.landed_at then
        -- 1. 詠唱中 (着弾パケット待ち)
        local remaining = c.predicted - elapsed
        table.insert(lines, string.format("魔法: %s (基本%.1fs / 予測詠唱%.2fs / %s)",
            color_text(c.spell_name, 255, 220, 100), c.base, c.predicted,
            c.from_learned and "実測から予測" or string.format("FC%d%%で計算", math.floor(fc_rate() * 100 + 0.5))))
        if remaining >= 0 then
            table.insert(lines, string.format("状態: %s [%s] 着弾まで%.2fs",
                color_text("詠唱中...", 255, 180, 50), bar(elapsed / math.max(c.predicted, 0.01), 15, "="), remaining))
        else
            table.insert(lines, string.format("状態: %s [%s] 予測より+%.2fs",
                color_text("着弾待ち", 255, 180, 50), bar(1, 15, "="), -remaining))
        end
        return
    end

    local since_land = now - c.landed_at
    if since_land < post then
        -- 2. 着弾後の硬直中
        table.insert(lines, string.format("魔法: %s (着弾済 / 実測詠唱%.2fs)",
            color_text(c.spell_name, 255, 150, 150), state.last_measured_cast or 0))
        table.insert(lines, string.format("状態: %s [%s] 次の詠唱まで%.2fs",
            color_text("硬直中", 255, 80, 80), bar(since_land / math.max(post, 0.01), 15, "#"), post - since_land))
        return
    end

    -- 3. 硬直解除 (効果音と待機中への切り替えは update_state で行う)
    table.insert(lines, color_text("★ READY! (硬直解除・次の詠唱可)", 50, 255, 100))
end

-- 時間の経過で変わる状態を進める。HUD の表示とは別に毎回行う (HUD を消していても READY の効果音を鳴らすため)
local function update_state(now)
    local c = state.cast
    if c.active and not c.landed_at and now - c.start > c.predicted + LAND_TIMEOUT_SEC then
        c.active = false
        return
    end
    if c.active and c.landed_at then
        local since_ready = now - c.landed_at - num(settings.post_lock_sec, 3.08)
        if since_ready >= 0 and not c.ready_signaled then
            c.ready_signaled = true
            play_sound()
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
    if state.mb_success_at and now - state.mb_success_at < 3.0 then
        table.insert(lines, color_text("★ マジックバースト成功！", 255, 230, 80))
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
    if not ok then report_error(now, "状態更新エラー", err) end

    if not settings.show_hud then
        if hud:visible() then hud:hide() end
        if grip:visible() then grip:hide() end
        return
    end
    ok, err = pcall(render, now)
    if not ok then report_error(now, "表示エラー", err) end
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
    c.spell_name = spell.ja or spell.en or "?"
    c.base = base
    c.skill = spell.skill
    c.start = os.clock()
    c.predicted, c.from_learned = predict_cast(c.skill, base)
    c.landed_at = nil
    c.ready_signaled = false

    -- 電光石火の章・疾風迅雷の章 (詠唱時間半減) の間の実測は、普段の予測に混ぜない
    -- (get_player は自分の詠唱開始のときだけ呼ぶ)
    c.learnable = true
    local player = windower.ffxi.get_player()
    for _, buff in ipairs(player and player.buffs or {}) do
        if SPEEDUP_BUFFS[buff] then c.learnable = false; break end
    end
end

local function on_own_cast_finish(act, now)
    local c = state.cast
    if c.active and not c.landed_at then
        c.landed_at = now
        state.last_measured_cast = now - c.start
        if c.learnable then learn_cast(c.skill, c.base, state.last_measured_cast) end
    end
    for _, target in ipairs(act.targets or {}) do
        local action = target.actions and target.actions[1]
        if action and action.message == MSG_MAGIC_BURST then
            state.mb_success_at = now
            break
        end
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
    if not ok then report_error(os.clock(), "アクション処理エラー", err) end
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
    report_error(os.clock(), "マウス処理エラー", result)
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
        chat_msg(string.format("[MBReadyTimer] HUD位置を変更しました: X=%d, Y=%d", settings.pos.x, settings.pos.y))

    elseif cmd == "post" and tonumber(args[1]) then
        local sec = tonumber(args[1])
        if sec > 0 and sec <= 10 then
            settings.post_lock_sec = sec
            save_settings()
            chat_msg(string.format("[MBReadyTimer] 着弾後の硬直を %.2f秒 に設定しました。", sec))
        end

    elseif cmd == "fc" and tonumber(args[1]) then
        local fc_val = tonumber(args[1])
        if fc_val >= 0 and fc_val <= 80 then
            settings.fc_rate = fc_val / 100.0
            save_settings()
            chat_msg(string.format("[MBReadyTimer] FC率を %d%% に変更しました。", fc_val))
        end

    elseif cmd == "learn" then
        -- //mbr learn : 覚えている実測の一覧 / //mbr learn reset : 忘れる (装備を大きく変えたとき)
        if args[1] and args[1]:lower() == "reset" then
            learned = {}
            chat_msg("[MBReadyTimer] 実測の記録を消しました。次の詠唱から覚え直します。")
            return
        end
        local any = false
        for skill, l in pairs(learned) do
            any = true
            local skill_name = res.skills[skill] and (res.skills[skill].ja or res.skills[skill].en) or tostring(skill)
            chat_msg(string.format("[MBReadyTimer] %s: 実測 %d回 / 基本に対する比率 %.2f (実効FC 約%d%%)",
                skill_name, l.count, l.ratio, math.floor((1 - l.ratio) * 100 + 0.5)))
            local bases = {}
            for base in pairs(l.by_base) do bases[#bases + 1] = base end
            table.sort(bases)
            for _, base in ipairs(bases) do
                chat_msg(string.format("    基本%.1fs → 実測平均 %.2fs", base, l.by_base[base]))
            end
        end
        if not any then
            chat_msg("[MBReadyTimer] まだ実測がありません。魔法を詠唱すると覚えます (それまでは FC 率で計算)。")
        end

    elseif cmd == "size" and tonumber(args[1]) then
        local size = set_size(tonumber(args[1]))
        save_settings()
        chat_msg(string.format("[MBReadyTimer] HUD の文字サイズを %d に変更しました。", size))

    elseif cmd == "sound" then
        settings.sound_enabled = not settings.sound_enabled
        save_settings()
        chat_msg(string.format("[MBReadyTimer] 効果音通知: %s%s", settings.sound_enabled and "ON" or "OFF",
            (windower.file_exists and not windower.file_exists(SOUND_FILE)) and " (sounds/ready.wav がありません)" or ""))

    elseif cmd == "hud" then
        settings.show_hud = not settings.show_hud
        save_settings()
        chat_msg(string.format("[MBReadyTimer] HUD表示: %s", settings.show_hud and "ON" or "OFF"))

    elseif cmd == "status" then
        chat_msg(string.format("[MBReadyTimer] FC %d%% (実測が無いときに使用) / 着弾後の硬直 %.2f秒",
            math.floor(fc_rate() * 100 + 0.5), num(settings.post_lock_sec, 3.08)))
        if state.last_measured_cast and state.cast.base > 0 then
            local real_fc = 1 - state.last_measured_cast / state.cast.base
            chat_msg(string.format("[MBReadyTimer] 直近の実測: %s 基本%.1fs → %.2fs (実効FC 約%d%%)",
                state.cast.spell_name, state.cast.base, state.last_measured_cast, math.floor(real_fc * 100 + 0.5)))
        end

    elseif cmd == "test" then
        -- ジャ系の詠唱 → 着弾 → 硬直 → READY を模擬表示
        local now = os.clock()
        local c = state.cast
        c.active = true
        c.spell_name = "サンダジャ"
        c.base = 7.0
        c.skill = ELEMENTAL_SKILL
        c.start = now
        c.predicted, c.from_learned = predict_cast(ELEMENTAL_SKILL, 7.0)
        c.learnable = false   -- テストの着弾は実測として覚えない
        c.landed_at = nil
        c.ready_signaled = false
        -- 着弾パケットの代わりに予測時刻で着弾させる
        coroutine.schedule(function()
            if c.active and not c.landed_at and c.spell_name == "サンダジャ" then
                c.landed_at = os.clock()
                state.last_measured_cast = c.landed_at - c.start
            end
        end, c.predicted)
        chat_msg("[MBReadyTimer] テスト表示を開始します (サンダジャの詠唱 → 着弾 → 硬直 → READY)。")

    else
        chat_msg("=== MBReadyTimer コマンドヘルプ ===")
        chat_msg("//mbr fc <FC率>       : FC率を変更 (例: //mbr fc 80)")
        chat_msg("//mbr post <秒>       : 着弾後の硬直秒数を設定 (例: //mbr post 3.08)")
        chat_msg("//mbr status          : 現在の設定と直近の実測詠唱時間を表示")
        chat_msg("//mbr learn [reset]   : 予測に使っている実測の一覧 / reset で消して覚え直す")
        chat_msg("//mbr pos <x> <y>     : HUD表示位置の変更 (例: //mbr pos 600 400)")
        chat_msg("//mbr size <数>       : HUD の文字サイズ (6〜40)。HUD上のホイール / 右下の角のドラッグでも変更可")
        chat_msg("//mbr sound           : READY効果音 ON/OFF")
        chat_msg("//mbr hud             : HUD表示 ON/OFF")
        chat_msg("//mbr test            : 表示テスト")
    end
end)
