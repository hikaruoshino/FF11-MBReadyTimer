-- =============================================================================
-- MBReadyTimer.lua : FFXI 黒魔道士 MB (マジックバースト) 次詠唱可能・硬直可視化アドオン (v3.2.0 完全適応版)
-- =============================================================================
-- 【概要】
-- Windower 4 Addon Development Rules & API 仕様書 (config, texts, resources, packets) に完全準拠。
-- 自動キャスト (autocast) による FFXI クラッシュリスクを徹底排除した 100% 安全・受動型アシストツール。
-- FFXI 画面左上のキャストタイマー (100% -> 0% カウントダウン表示) と完全同調する HUD バーをリアルタイム表示。
-- 
-- 【FC 逆算タイマー ＆ 硬直解除可視化モデル】
--   - 100.0% -> 着弾%: 魔法詠唱中 (実効詠唱時間 = 基本詠唱時間 * (1 - FC率))
--   - 着弾%  -> 解除%: 着弾後・サーバー/アニメーション硬直中
--   - 解除%  ->  0.0%: ★ READY! (硬直完全解除・即座に次魔法キャスト可能)
-- 
-- 【仕様書準拠・文字化け・POLクラッシュ防止対策】
-- 1. HUD画面表示 (libs/texts.lua): DirectWrite 用 UTF-8 エンコーディング。
-- 2. チャットログ (windower.add_to_chat): FFXI本体用 Shift-JIS 変換 (windower.to_shift_jis) 適用。
-- 3. 設定永続化 (libs/config.lua): FC率、硬直目標%、位置情報を data/settings.xml へ自動保存。
-- 4. リソース参照 (libs/resources.lua): res.spells による精霊・古代・ジャ系魔法の詠唱時間完全動的算出。
-- 5. 改行文字に string.char(10) を使用し Lua 構文エラー (unfinished string) を構造的に防止。
-- =============================================================================

_addon.name     = "MBReadyTimer"
_addon.author   = "Gemini Notebook"
_addon.version  = "3.2.0"
_addon.commands = {"mbtimer", "mbr"}

require("luau")
local config  = require("config")
local texts   = require("texts")
local res     = require("resources")
local packets = require("packets")

-- -----------------------------------------------------------------------------
-- デフォルト設定 (data/settings.xml)
-- -----------------------------------------------------------------------------
local defaults = {}
defaults.pos = {x = 500, y = 300}
defaults.text = {font = "Meiryo", size = 11, alpha = 255}
defaults.bg = {alpha = 180, red = 10, green = 10, blue = 15}
defaults.padding = 6
defaults.fc_rate = 0.80       -- ファストキャスト率 (上限80%想定)
defaults.post_lock_sec = 3.08  -- 着弾後のサーバー/アニメーション硬直実効秒数 (ジャ系でTimer残り36.0%で解除)
defaults.sound_enabled = true
defaults.show_hud = true
defaults.show_mb_window = true

local settings = config.load(defaults)

-- -----------------------------------------------------------------------------
-- チャット出力用 Shift-JIS 変換ヘルパー関数
-- -----------------------------------------------------------------------------
local function chat_msg(msg, color)
    color = color or 207
    if windower and windower.to_shift_jis then
        local ok, converted = pcall(windower.to_shift_jis, tostring(msg))
        if ok and converted then
            windower.add_to_chat(color, converted)
            return
        end
    end
    windower.add_to_chat(color, tostring(msg))
end

-- カラーコード装飾 (HUD用 UTF-8)
local function color_text(str, r, g, b)
    return string.format("\\cs(%d,%d,%d)%s\\cr", r, g, b, tostring(str or ""))
end

-- -----------------------------------------------------------------------------
-- 状態管理変数
-- -----------------------------------------------------------------------------
local state = {
    is_active = false,
    spell_name = "",
    base_cast_time = 7.0,     -- 基本詠唱時間 (秒)
    cast_start_time = 0,
    
    actual_cast_time = 1.4,   -- FC適用後の実効詠唱時間 (秒)
    ready_time_sec = 4.48,    -- 次詠唱可能までの総経過秒数 (秒)
    
    land_rem_pct = 80.0,      -- 着弾時の FFXI Cast Timer 残り% (100% - 20% = 80%)
    ready_rem_pct = 36.0,     -- 硬直解除時の FFXI Cast Timer 残り% (残り36%)
    
    mb_window_active = false,
    mb_window_start = 0,
    mb_window_duration = 9.0,
    
    is_ready_signaled = false,
}

-- HUDテキストボックス初期化 (texts.lua 仕様準拠)
local hud = texts.new("${text}", settings)

-- 効果音再生
local function play_sound()
    if settings.sound_enabled then
        windower.play_sound(windower.addon_path .. "sounds/ready.wav")
    end
end

-- -----------------------------------------------------------------------------
-- HUD 描画アップデート処理 (毎フレーム呼び出し: 100% -> 0% Cast Timer カウントダウン基準)
-- -----------------------------------------------------------------------------
windower.register_event("prerender", function()
    if not settings.show_hud then
        hud:hide()
        return
    end

    local now = os.clock()
    local lines = {}
    
    table.insert(lines, color_text("=== [ FFXI Cast Timer Assist v3.2 ] ===", 200, 220, 255))
    
    if state.is_active then
        local elapsed = now - state.cast_start_time
        local rem_pct = math.max(0.0, (1.0 - (elapsed / state.base_cast_time)) * 100.0)
        
        -- 1. 詠唱中 (Cast Timer 100% -> 着弾点 land_rem_pct%)
        if elapsed < state.actual_cast_time then
            local remaining_cast = math.max(0, state.actual_cast_time - elapsed)
            local progress = math.min(1.0, elapsed / state.actual_cast_time)
            local bar_len = 15
            local filled = math.floor(progress * bar_len)
            local bar = string.rep("=", filled) .. string.rep("-", bar_len - filled)
            
            table.insert(lines, string.format("魔法: %s (基本%.1fs / FC%d%%)", color_text(state.spell_name, 255, 220, 100), state.base_cast_time, math.floor(settings.fc_rate * 100)))
            table.insert(lines, string.format("Cast Timer: %s (着弾: 残り%.1f%% / 解除: 残り%.1f%%)", color_text(string.format("残り %.1f%%", rem_pct), 255, 200, 50), state.land_rem_pct, state.ready_rem_pct))
            table.insert(lines, string.format("状態: %s [%s] 着弾まで%.2fs", color_text("詠唱中...", 255, 180, 50), bar, remaining_cast))

        -- 2. 着弾後・アニメーション硬直中 (着弾点 land_rem_pct% -> 解除点 ready_rem_pct%)
        elseif elapsed < state.ready_time_sec then
            local remaining_lock = math.max(0, state.ready_time_sec - elapsed)
            local lock_elapsed = elapsed - state.actual_cast_time
            local lock_dur = state.ready_time_sec - state.actual_cast_time
            local progress = math.min(1.0, lock_elapsed / lock_dur)
            local bar_len = 15
            local filled = math.floor(progress * bar_len)
            local bar = string.rep("#", filled) .. string.rep("-", bar_len - filled)
            
            table.insert(lines, string.format("魔法: %s (着弾済・硬直中)", color_text(state.spell_name, 255, 150, 150)))
            table.insert(lines, string.format("Cast Timer: %s (目標解除: 残り%.1f%%)", color_text(string.format("残り %.1f%%", rem_pct), 255, 100, 100), state.ready_rem_pct))
            table.insert(lines, string.format("状態: %s [%s] 硬直切れるまで%.2fs", color_text("硬直中 (待機)", 255, 80, 80), bar, remaining_lock))

        -- 3. 硬直解除！ (ready_rem_pct% 到達・次キャスト可能)
        else
            if not state.is_ready_signaled then
                state.is_ready_signaled = true
                play_sound()
            end
            
            local ready_elapsed = elapsed - state.ready_time_sec
            if ready_elapsed < 2.5 then
                table.insert(lines, string.format("Cast Timer: %s (解除点 残り%.1f%% 通過)", color_text(string.format("残り %.1f%%", rem_pct), 50, 255, 100), state.ready_rem_pct))
                table.insert(lines, color_text("★ READY! (硬直解除・次キャスト可)", 50, 255, 100))
                table.insert(lines, color_text(">> 今すぐ次のマクロを押してください！ <<", 100, 255, 150))
            else
                state.is_active = false
                table.insert(lines, string.format("状態: %s", color_text("待機中 (Idle)", 180, 180, 180)))
            end
        end
    else
        table.insert(lines, string.format("状態: %s", color_text("待機中 (Idle)", 180, 180, 180)))
    end

    -- 4. 連携MBウインドウ表示 & 次推奨魔法ナビ
    if settings.show_mb_window and state.mb_window_active then
        local mb_elapsed = now - state.mb_window_start
        local mb_remaining = math.max(0, state.mb_window_duration - mb_elapsed)
        
        if mb_remaining > 0 then
            table.insert(lines, string.format("MB受付枠: %s", color_text(string.format("残り %.1f秒", mb_remaining), 255, 150, 255)))
            
            if state.is_active and (now - state.cast_start_time) < state.ready_time_sec then
                table.insert(lines, color_text("次推奨: [硬直解除待ち...]", 255, 120, 120))
            else
                local recommend = "次推奨: 精霊4系 (実効1.0s)"
                if mb_remaining >= (2.1 + 0.2) then
                    recommend = "★推奨: 精霊6系 (実効2.1s)"
                elseif mb_remaining >= (1.5 + 0.2) then
                    recommend = "★推奨: 精霊5系 (実効1.5s)"
                elseif mb_remaining >= (1.4 + 0.2) then
                    recommend = "★推奨: ジャ系/古代II (実効1.4s)"
                elseif mb_remaining >= (1.0 + 0.1) then
                    recommend = "★推奨: 精霊4系 (実効1.0s)"
                else
                    recommend = "次推奨: [MB枠受付終了間近]"
                end
                table.insert(lines, color_text(recommend, 100, 255, 150))
            end
        else
            state.mb_window_active = false
        end
    end

    hud.text = table.concat(lines, string.char(10))
    hud:show()
end)

-- -----------------------------------------------------------------------------
-- アクションパケットイベント検知 (Cast Start & Action Finish)
-- -----------------------------------------------------------------------------
windower.register_event("action", function(act)
    local player = windower.ffxi.get_player()
    if not player or act.actor_id ~= player.id then return end

    -- Category 8: 魔法詠唱開始 (Spell Casting Start)
    if act.category == 8 then
        local target = act.targets and act.targets[1]
        local action = target and target.actions and target.actions[1]
        local spell_id = action and action.param
        
        if spell_id then
            local spell = res.spells[spell_id]
            if spell and spell.type == "BlackMagic" then
                local base_cast = spell.cast_time or 3.0
                local fc = settings.fc_rate or 0.80
                local post_lock = settings.post_lock_sec or 3.08
                
                state.is_active = true
                state.spell_name = spell.japanese or spell.name
                state.base_cast_time = base_cast
                state.cast_start_time = os.clock()
                
                state.actual_cast_time = base_cast * (1.0 - fc)                -- 着弾時間
                state.ready_time_sec = state.actual_cast_time + post_lock      -- 硬直解除時間
                
                state.land_rem_pct = (1.0 - (state.actual_cast_time / base_cast)) * 100.0   -- 着弾時の残り%
                state.ready_rem_pct = (1.0 - (state.ready_time_sec / base_cast)) * 100.0     -- 硬直解除時の残り%
                
                if state.ready_rem_pct < 0 then state.ready_rem_pct = 0.0 end
                
                state.is_ready_signaled = false
            end
        end

    -- Category 4: 魔法完了 / 着弾 (Spell Cast Complete)
    elseif act.category == 4 then
        local spell_id = act.param
        local spell = res.spells[spell_id]
        if spell and spell.type == "BlackMagic" then
            if not state.mb_window_active then
                state.mb_window_active = true
                state.mb_window_start = os.clock()
                state.mb_window_duration = 8.5
            end
        end
    end
end)

-- -----------------------------------------------------------------------------
-- アクションメッセージ (連携発生時の検知)
-- -----------------------------------------------------------------------------
windower.register_event("action message", function(actor_id, target_id, actor_index, target_id_2, message_id, param_1, param_2, param_3)
    if (message_id >= 288 and message_id <= 302) or (message_id >= 385 and message_id <= 398) then
        state.mb_window_active = true
        state.mb_window_start = os.clock()
        state.mb_window_duration = 9.0
    end
end)

-- -----------------------------------------------------------------------------
-- イベントクリーンアップ (unload / zone change)
-- -----------------------------------------------------------------------------
windower.register_event("unload", function()
    if hud then hud:hide() end
end)

windower.register_event("zone change", function()
    state.is_active = false
    state.mb_window_active = false
end)

-- -----------------------------------------------------------------------------
-- セルフコマンド処理 (//mbr または //mbtimer)
-- -----------------------------------------------------------------------------
windower.register_event("addon command", function(cmd, ...)
    local args = {...}
    cmd = cmd and cmd:lower()

    if cmd == "pos" and args[1] and args[2] then
        settings.pos.x = tonumber(args[1])
        settings.pos.y = tonumber(args[2])
        config.save(settings)
        hud:pos(settings.pos.x, settings.pos.y)
        chat_msg(string.format("[MBReadyTimer] HUD位置を変更しました: X=%d, Y=%d", settings.pos.x, settings.pos.y))

    elseif cmd == "lock" and args[1] then
        local val = tonumber(args[1])
        if val then
            if val > 0 and val <= 100 then
                local elapsed_pct = (100.0 - val) / 100.0
                local target_elapsed_sec = 7.0 * elapsed_pct
                settings.post_lock_sec = math.max(0.1, target_elapsed_sec - 1.4)
                config.save(settings)
                chat_msg(string.format("[MBReadyTimer] ジャ系解除目標を Cast Timer 残り %.1f%% (経過 %.2f秒 / 硬直 %.2f秒) に調整しました。", val, target_elapsed_sec, settings.post_lock_sec))
            end
        end

    elseif cmd == "fc" and args[1] then
        local fc_val = tonumber(args[1])
        if fc_val and fc_val >= 0 and fc_val <= 80 then
            settings.fc_rate = fc_val / 100.0
            config.save(settings)
            chat_msg(string.format("[MBReadyTimer] FC率設定を %d%% に変更しました。", fc_val))
        end

    elseif cmd == "sound" then
        settings.sound_enabled = not settings.sound_enabled
        config.save(settings)
        chat_msg(string.format("[MBReadyTimer] 効果音通知: %s", settings.sound_enabled and "ON" or "OFF"))

    elseif cmd == "hud" then
        settings.show_hud = not settings.show_hud
        config.save(settings)
        chat_msg(string.format("[MBReadyTimer] HUD表示: %s", settings.show_hud and "ON" or "OFF"))

    elseif cmd == "test" then
        -- ジャ系テスト (Base 7.0s, FC 80% => 着弾残り80.0%, 硬直解除残り36.0%)
        state.is_active = true
        state.spell_name = "サンダジャ"
        state.base_cast_time = 7.0
        state.cast_start_time = os.clock()
        state.actual_cast_time = 1.4
        state.ready_time_sec = 4.48
        state.land_rem_pct = 80.0
        state.ready_rem_pct = 36.0
        state.is_ready_signaled = false
        
        state.mb_window_active = true
        state.mb_window_start = os.clock()
        state.mb_window_duration = 8.5
        chat_msg("[MBReadyTimer] FFXI Cast Timer カウントダウン (残り80%着弾 -> 残り36%解除) のテスト表示を開始します。")

    else
        chat_msg("=== MBReadyTimer コマンドヘルプ ===")
        chat_msg("//mbr lock <残り%>  : ジャ系の硬直解除%目標を調整 (例: //mbr lock 36)")
        chat_msg("//mbr fc <FC率>     : FC率設定を変更 (例: //mbr fc 80)")
        chat_msg("//mbr pos <x> <y>   : HUD表示位置の変更 (例: //mbr pos 600 400)")
        chat_msg("//mbr sound         : READY効果音ON/OFF切り替え")
        chat_msg("//mbr hud           : HUD表示ON/OFF切り替え")
        chat_msg("//mbr test          : タイマー動作テスト")
    end
end)
