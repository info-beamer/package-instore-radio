gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

if not sys.provides "audio" then
    function node.render()
        font:write(5, 5, "audio not enabled", 32, 1,1,1,1)
    end
    return
end


util.no_globals()

local font = resource.load_font "font.ttf"
local json = require "json"
local deque = require "deque"

local w = resource.create_colored_texture(1,1,1,1)
local base_volume = 1

local function log(fmt, ...)
    print(string.format("[PLAYER] "..fmt, ...))
end

local function dbg_writer()
    local y = 5
    local x = 5

    local function write(fmt, ...)
        font:write(x, y, string.format(fmt, ...), 32, 1,1,1,1)
        y = y + 32
    end

    local function space()
        y = y + 10
    end

    local function reset()
        y = 0
    end

    return {
        write = write;
        space = space;
        reset = reset;
    }
end

local dbg = dbg_writer()

-------------------------------------------------------------------------------------

local function StreamPlayer(url, buffer)
    local stream
    local handle
    local volume = 0
    local volume_target = 0
    local healthy = false
    local last_error = ""
    local next_open = sys.now()
    local worked_once = false

    local function is_ready()
        local s, preload = stream:state()
        if s == "loaded" or s == "paused" then
            return preload > buffer
        else
            return false
        end
    end

    local function is_failing()
        local s, preload = stream:state()
        if s == "loaded" or s == "paused" then
            return preload < 5
        else
            return true
        end
    end

    local function is_gone()
        local s = stream:state()
        return s == "finished" or s == "error"
    end

    local function terminate()
        if stream then
            stream:dispose()
            stream = nil
        end
    end

    local function handle_stream()
        local started = sys.now()
        log("starting stream")
        while not is_ready() do
            if sys.now() > started + buffer + 10 then
                log("cannot open stream")
                -- try again
                return terminate()
            end
            coroutine.yield()
        end

        stream:start()

        log("starting stream %s", url)
        healthy = true
        worked_once = true

        while not is_failing() and not is_gone() do
            coroutine.yield()
        end

        log("ending stream %s", url)
        healthy = false

        while volume > 0 and not is_gone() do
            coroutine.yield()
        end

        return terminate()
    end

    local function open()
        if url == "" then
            last_error = "No stream configured"
            next_open = sys.now() + 5
            return
        end
        local ok, next_stream = pcall(resource.load_audio, {
            file = url,
            buffer = buffer + 5,
            paused = true,
        })
        if not ok then
            last_error = next_stream
            next_open = sys.now() + 5
            return
        end
        stream = next_stream
        volume = 0
        volume_target = 0
        stream:volume(volume * base_volume)
        handle = coroutine.wrap(handle_stream)
    end

    local function debug()
        dbg.write("Stream")
        if not stream then
            dbg.write(" last error: %s", last_error)
            dbg.write(" next open: %f", next_open - sys.now())
            dbg.space()
        else
            local s, preload = stream:state()
            dbg.write(" url: %s", url)
            dbg.write(" state: %s", s)
            if s == "error" then
                dbg.write(" error: %s", preload)
            else
                dbg.write(" cur buffer: %s", preload or 0)
            end
            dbg.write(" target buffer: %ds", buffer)
            dbg.write(" volume: %f", volume)
            for k, v in pairs(stream:metadata()) do
                dbg.write("  %s: %s", k, v)
            end
        end
        dbg.space()
    end

    local function tick()
        if not stream and sys.now() > next_open then
            open()
        end
        debug()
        if not stream then
            return
        end
        if volume < volume_target then
            volume = math.min(1, volume + 0.02)
        elseif volume > volume_target then
            volume = math.max(0, volume - 0.02)
        end
        stream:volume(volume * base_volume)
        handle()
    end

    local function set_volume(vol)
        volume_target = vol
    end

    local function on()
        set_volume(1)
    end

    local function off()
        set_volume(0)
    end

    local function is_healthy()
        return healthy
    end

    local function has_worked_once()
        return worked_once
    end

    return {
        tick = tick;
        on = on;
        off = off;
        set_volume = set_volume;
        is_healthy = is_healthy;
        has_worked_once = has_worked_once;
        terminate = terminate;
    }
end

local function LocalPlayer(source, initial_volume)
    local volume = initial_volume or 1
    local volume_target = initial_volume or 1

    local audio = resource.load_audio{
        file = source.file:copy(),
        buffer = 2,
        paused = true,
    }

    local function eos()
        local s = audio:state()
        return s == "finished" or s == "error"
    end

    local function terminate()
        audio:dispose()
        audio = nil
    end

    local function debug()
        local s, preload = audio:state()
        dbg.write("Local")
        dbg.write(" file: %s", source.name)
        dbg.write(" state: %s", s)
        dbg.write(" cur buffer: %.3fs", preload or 0)
        dbg.write(" volume: %f", volume)
        dbg.space()
    end

    local function tick()
        if volume < volume_target then
            volume = math.min(1, volume + 0.02)
        elseif volume > volume_target then
            volume = math.max(0, volume - 0.02)
        end
        if volume > 0 then
            audio:start()
        else
            audio:stop()
        end
        audio:volume(volume * base_volume)

        debug()
    end

    local function set_volume(vol)
        volume_target = vol
    end

    local function on()
        set_volume(1)
    end

    local function off()
        set_volume(0)
    end

    return {
        tick = tick;
        on = on;
        off = off;
        set_volume = set_volume;
        eos = eos;
        terminate = terminate;
    }
end

-------------------------------------------------------------------------------------

local CreateStream = (function()
    local stream
    local last_url
    local last_buffer

    return function(new_url, new_buffer)
        if new_url == last_url and new_buffer == last_buffer then
            return stream
        end
        log("setting new stream url %s", new_url)
        last_url = new_url
        last_buffer = new_buffer
        if stream then
            stream.terminate()
        end
        stream = StreamPlayer(new_url, new_buffer)
        return stream
    end
end)()

local function Fallback()
    local pos = 0
    local playlist = {}
    local force_fallback_until = sys.now()
    local min_fallback = 60
    local player

    local function set_playlist(items)
        local next_playlist = {}
        for idx, item in ipairs(items) do
            next_playlist[idx] = {
                file = resource.open_file(item.file.asset_name);
                name = item.file.filename;
            }
        end

        -- make switching atomic. In case the above loop
        -- fails for any reason, nothing will change.
        playlist = next_playlist
        pos = 0
    end

    local function set_min_fallback(seconds)
        min_fallback = seconds
    end

    local function get_next()
        pos = pos % #playlist + 1
        local item = playlist[pos]
        if not item then
            return {
                file = resource.open_file "idle.mp3",
                name = "idle.mp3",
            }
        else
            return {
                file = item.file,
                name = item.name,
            }
        end
    end

    local function load_next()
        if player then
            player.terminate()
        end
        player = LocalPlayer(get_next())
    end

    local function is_active()
        return sys.now() < force_fallback_until
    end

    local function activate(for_seconds)
        log("triggering fallback for %d seconds", for_seconds)
        force_fallback_until = sys.now() + for_seconds
    end

    local function check_if_needed(stream, silence_detector)
        -- Already in fallback? No change. Wait until the
        -- fallback expires.
        if is_active() then
            return
        end

        -- At this point, the stream is supposed to play. Check if
        -- it's broken or silent.
        if not stream.is_healthy() or silence_detector.is_silent() then
            if stream.has_worked_once() then
                -- Problem and then configured stream worked at
                -- least once? Then trigger hard fallback.
                activate(min_fallback)
            else
                -- Only trigger a very temporary fallback to give
                -- the stream a chance to start.
                activate(5)
            end
        end
    end

    local function tick()
        if not player or player.eos() then
            load_next()
        end
        dbg.write("Fallback")
        if is_active() then
            dbg.write(" active for %.3f", force_fallback_until - sys.now())
        else
            dbg.write(" not active")
        end
        dbg.space()
        player.tick()
    end

    return {
        tick = tick;
        check_if_needed = check_if_needed;
        activate = activate;
        set_playlist = set_playlist;
        set_min_fallback = set_min_fallback;
        is_active = is_active;
        set_volume = function(...) player.set_volume(...) end;
        on = function() player.on() end;
        off = function() player.off() end;
    }
end


local function Overlay()
    local queue = deque:new()
    local player = nil
    local volume = 0
    local last_h, last_m
    local overlays = {}
    local overlay_by_asset_spec = {}

    local function set_overlays(new_overlays)
        for _, overlay in ipairs(new_overlays) do
            overlay.asset_id = overlay.file.asset_id
            overlay.file = {
                file = resource.open_file(overlay.file.asset_name),
                name = overlay.file.filename,
            }
        end
        overlays = new_overlays

        overlay_by_asset_spec = {}
        for _, overlay in ipairs(overlays) do
            overlay_by_asset_spec[overlay.asset_id] = overlay.file
        end
    end

    local function enqueue(item)
        log("enqeue new item: %s", item.file.name)
        queue:push_right(item)
    end

    local function play(asset_spec, volume)
        local file = overlay_by_asset_spec[asset_spec]
        if file then
            enqueue{
                file = file,
                volume = volume or 0,
            }
        end
    end

    local function stop()
        player.terminate()
        player = nil
    end

    local function abort()
        stop()
        queue = deque:new()
    end

    local function update_time(h, m)
        local function minute_match(m, minute_config)
            if m == minute_config then
                return true
            elseif minute_config == "every-3" then
                return m % 3 == 0
            elseif minute_config == "every-5" then
                return m % 5 == 0
            elseif minute_config == "every-10" then
                return m % 10 == 0
            elseif minute_config == "every-15" then
                return m % 15 == 0
            elseif minute_config == "every-20" then
                return m % 20 == 0
            end
            return false
        end

        if h == last_h and m == last_m then
            return
        end
        last_h = h
        last_m = m
        local matched = {}
        for _, overlay in ipairs(overlays) do
            if h >= overlay.start_hour and
               h <= overlay.end_hour and
               minute_match(m, overlay.minute)
            then
                local item = {
                    file = overlay.file,
                    volume = overlay.volume,
                }
                if overlay.merge == "overwrite" then
                    matched = {item}
                elseif overlay.merge == "append" then
                    table.insert(matched, item)
                elseif overlay.merge == "prepend" then
                    table.insert(matched, 1, item)
                else
                    error "invalid merge value"
                end
            end
        end
        log("matched %d overlays at %02d:%02d", #matched, h, m)
        for _, item in ipairs(matched) do
            enqueue(item)
        end
    end

    local function debug()
        dbg.write("Overlay")
        if last_h then
            dbg.write(" time: %02d:%02d", last_h, last_m)
        else
            dbg.write(" time: <unknown>")
        end
        dbg.write(" queue: %d items", queue:length())
        dbg.space()
    end

    local function tick()
        if player then
            player.tick()
            if player.eos() then
                stop()
            end
        elseif not queue:is_empty() then
            local item = queue:pop_left()
            log("about to play next item")
            player = LocalPlayer(item.file)
            volume = item.volume
        end
        debug()
    end

    local function is_playing()
        return player ~= nil
    end

    local function get_volume()
        return volume
    end

    return {
        tick = tick;
        play = play;
        abort = abort;
        set_overlays = set_overlays;
        update_time = update_time;
        get_volume = get_volume;
        is_playing = is_playing;
    }
end

local function SilenceDetector()
    local above_threshold = sys.now()
    local loudness
    local threshold = 5
    local t = {}

    local function tick()
        loudness = sys.audio.loudness()
        if loudness > 0.05 then
            above_threshold = sys.now()
        end
    end

    local function set_threshold(new_threshold)
        threshold = new_threshold
    end

    local function silence_duration()
        return sys.now() - above_threshold
    end

    local function is_silent()
        return silence_duration() > threshold
    end

    local function debug()
        dbg.write("Silence detector")
        dbg.write(" silent for: %f", silence_duration())
        dbg.write(" threshold: %f", threshold)
        dbg.write(" loudness: %f", loudness)
        dbg.space()
    end

    local function graph()
        t = sys.audio.freq(t)
        local function avg(off, count)
            local sum = 0
            for i = off, off+count do
                sum = sum + t[i]
            end
            return sum/count
        end
        for i = 1, 32 do
            local x = i * WIDTH/33
            w:draw(x, HEIGHT-30  - t[i]*(HEIGHT-20), x + 30, HEIGHT-30, 0.3)
        end
        w:draw(0, HEIGHT-30, WIDTH*sys.audio.loudness(), HEIGHT)
    end

    return {
        tick = tick;
        is_silent = is_silent;
        set_threshold = set_threshold;
        debug = debug;
        graph = graph;
    }
end

-------------------------------------------------------------------------------------

local stream
local fallback = Fallback()
local overlay = Overlay()
local silence_detector = SilenceDetector()

util.json_watch("config.json", function(config)
    base_volume = config.base_volume
    stream = CreateStream(config.stream, config.buffer)
    fallback.set_playlist(config.playlist)
    fallback.set_min_fallback(config.min_fallback)
    overlay.set_overlays(config.overlays)
    silence_detector.set_threshold(config.silence_threshold)
    node.gc()
end)

util.data_mapper{
    ["overlay/play"] = function(raw)
        local asset_spec = json.decode(raw)
        overlay.play(asset_spec, 0.1)
    end;
    ["overlay/abort"] = function()
        overlay.abort()
    end;
    fallback = function(force)
        if force == "yes" then
            fallback.activate(1000000000)
        else
            fallback.activate(0)
        end
    end;
    time = function(msg)
        local time = json.decode(msg)
        overlay.update_time(time.hour, time.minute)
    end;
}

function node.render()
    dbg.reset()

    fallback.check_if_needed(stream, silence_detector)

    local l = sys.audio.loudness()

    if overlay.is_playing() then
        gl.clear(l, l, 0, 1)
    elseif fallback.is_active() then
        gl.clear(l, 0, 0, 1)
    else
        gl.clear(0, l, 0, 1)
    end

    stream.tick()
    fallback.tick()
    overlay.tick()
    silence_detector.tick()

    if overlay.is_playing() then
        if fallback.is_active() then
            fallback.set_volume(overlay.get_volume())
        else
            stream.set_volume(overlay.get_volume())
        end
    elseif fallback.is_active() then
        fallback.on()
        stream.off()
    else
        stream.on()
        fallback.off()
    end

    silence_detector.debug()
    silence_detector.graph()
end
