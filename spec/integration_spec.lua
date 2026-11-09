--[[--
Integration spec: boots the real KOReader runtime headless (SDL dummy video),
loads plugins through KOReader's own PluginLoader and drives the arXiv plugin
through its real widgets. Must run from the KOReader install directory:

  cd "$KOREADER_DIR" && KO_HOME="$tmp" SDL_VIDEODRIVER=dummy \
    ./luajit "$REPO/spec/runner.lua" "$REPO/spec/integration_spec.lua"

scripts/check.sh --integration prepares KO_HOME (plugin install + settings).
Set ARXIV_REAL_NETWORK=1 to also download a real paper from arxiv.org.
]]

require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local FileManager = require("apps/filemanager/filemanager")
local lfs = require("libs/libkoreader-lfs")
local time = require("ui/time")

local KO_HOME = DataStorage:getDataDir()
local DOWNLOADS = KO_HOME .. "/downloads"
lfs.mkdir(DOWNLOADS)
G_reader_settings:saveSetting("download_dir", DOWNLOADS)

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local PDF = read_file(SPEC_REPO_ROOT .. "/spec/fixtures/minimal.pdf")
local HTML = read_file(SPEC_REPO_ROOT .. "/spec/fixtures/error.html")

local function write_file(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

-- Run due and soon-due UI tasks (scheduleIn/nextTick) without the input loop.
local function drain()
    for _ = 1, 6 do
        UIManager:shiftScheduledTasksBy(-time.s(2))
        UIManager:_checkTasks()
    end
end

local function top()
    return UIManager:getTopmostVisibleWidget()
end

-- Find a Button by its label anywhere in a widget tree.
local function find_button(widget, label, seen)
    seen = seen or {}
    if type(widget) ~= "table" or seen[widget] then return nil end
    seen[widget] = true
    if widget.text == label and type(widget.callback) == "function" and widget.label_widget then
        return widget
    end
    for k, v in pairs(widget) do
        if k ~= "show_parent" and k ~= "ui" and k ~= "parent" and type(v) == "table" then
            local found = find_button(v, label, seen)
            if found then return found end
        end
    end
end

local function press(widget, label)
    local button = find_button(widget, label)
    assert(button, "button not found: " .. label)
    button.callback()
    drain()
end

-- Directory listing, ignoring KOReader's own per-document metadata (*.sdr).
local function dir_entries()
    local names = {}
    for name in lfs.dir(DOWNLOADS) do
        if name ~= "." and name ~= ".." and not name:match("%.sdr$") then names[#names + 1] = name end
    end
    table.sort(names)
    return table.concat(names, ",")
end

local function clear_downloads()
    require("ffi/util").purgeDir(DOWNLOADS)
    lfs.mkdir(DOWNLOADS)
end

local function close_all()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if ReaderUI and ReaderUI.instance then
        ReaderUI.instance:onClose()
    end
    if FileManager.instance then
        FileManager.instance:onClose()
    end
    drain()
    while UIManager._window_stack[1] do
        UIManager:close(UIManager._window_stack[#UIManager._window_stack].widget)
    end
end

local function open_fm()
    close_all()
    FileManager:showFiles(DOWNLOADS)
    drain()
    return FileManager.instance
end

local function menu_items(fm)
    fm.menu:setUpdateItemTable()
    local found = {}
    local function walk(t, seen)
        if type(t) ~= "table" or seen[t] then return end
        seen[t] = true
        if type(t.text) == "string" then
            found[#found + 1] = t
        end
        for _, v in ipairs(t) do walk(v, seen) end
        if t.sub_item_table then walk(t.sub_item_table, seen) end
    end
    walk(fm.menu.tab_item_table, {})
    return found
end

-- Count menu entries by their menu_items key (MenuSorter stores it as .id).
local function count_id(items, id)
    local n, item = 0, nil
    for _, it in ipairs(items) do
        if it.id == id then n, item = n + 1, it end
    end
    return n, item
end

local real_request

-- Route plugin downloads through a scripted transport.
local function fake_transport(fm, response)
    local calls = { n = 0 }
    real_request = real_request or fm.arxiv.download.koreader_request
    fm.arxiv.download.koreader_request = function(req)
        calls.n = calls.n + 1
        req.sink(response.body)
        req.sink(nil)
        return response.code, { ["content-length"] = tostring(#response.body) }
    end
    return calls
end

local function submit(fm, text)
    local item = select(2, count_id(menu_items(fm), "arxiv_download_pdf"))
    item.callback()
    drain()
    local dialog = fm.arxiv.input_dialog
    assert(dialog and top() == dialog, "input dialog shown")
    dialog:setInputText(text)
    press(dialog, "Download")
    return dialog
end

describe("plugin loading and menu", function()
    it("loads arxiv alongside OPDS", function()
        local fm = open_fm()
        assert.truthy(fm.arxiv, "arxiv plugin instance")
        assert.truthy(fm.opds, "opds plugin instance")
    end)

    it("shows exactly one menu entry, next to the other downloaders", function()
        local fm = open_fm()
        local items = menu_items(fm)
        local n, item = count_id(items, "arxiv_download_pdf")
        assert.equal(1, n)
        assert.equal("Download arXiv PDF", item.text) -- sorting_hint placed it: no "NEW: " prefix
        assert.equal(1, (count_id(items, "opds")))
    end)

    it("does not stack entries across File Manager close/reopen cycles", function()
        for _ = 1, 3 do open_fm() end
        local fm = FileManager.instance
        assert.equal(1, (count_id(menu_items(fm), "arxiv_download_pdf")))
        local n = 0
        for _, w in ipairs(fm.menu.registered_widgets) do
            if tostring(w.name):match("arxiv$") then n = n + 1 end
        end
        assert.equal(1, n)
    end)
end)

describe("download folder", function()
    it("follows KOReader's shared %D% download folder, including later changes", function()
        local fm = open_fm()
        assert.equal(DOWNLOADS, fm.arxiv:getDownloadDir())
        local other = KO_HOME .. "/other-downloads"
        lfs.mkdir(other)
        G_reader_settings:saveSetting("download_dir", other)
        assert.equal(other, fm.arxiv:getDownloadDir())
        G_reader_settings:saveSetting("download_dir", DOWNLOADS)
        assert.equal(DOWNLOADS, fm.arxiv:getDownloadDir())
    end)
end)

describe("input dialog", function()
    it("keeps the dialog and text on invalid input, without network or files", function()
        clear_downloads()
        local fm = open_fm()
        local calls = fake_transport(fm, { code = 200, body = PDF })
        local dialog = submit(fm, "https://evil.test/abs/2609.16338")
        assert.equal(0, calls.n)
        assert.truthy(UIManager:isWidgetShown(dialog), "dialog still open")
        assert.equal("https://evil.test/abs/2609.16338", dialog:getInputText())
        assert.equal("", dir_entries())
        close_all()
    end)

    it("cancel closes the dialog", function()
        local fm = open_fm()
        local item = select(2, count_id(menu_items(fm), "arxiv_download_pdf"))
        item.callback()
        drain()
        local dialog = fm.arxiv.input_dialog
        press(dialog, "Cancel")
        assert.falsy(UIManager:isWidgetShown(dialog))
        assert.equal(nil, fm.arxiv.input_dialog)
    end)
end)

describe("download flow", function()
    it("downloads, offers Read now, and opens the PDF in ReaderUI", function()
        clear_downloads()
        local fm = open_fm()
        local calls = fake_transport(fm, { code = 200, body = PDF })
        submit(fm, "arXiv:2609.16338")
        assert.equal(1, calls.n)
        local path = DOWNLOADS .. "/2609.16338.pdf"
        assert.equal(PDF, read_file(path))
        assert.equal("2609.16338.pdf", dir_entries())
        press(top(), "Read now")
        local ReaderUI = require("apps/reader/readerui")
        assert.truthy(ReaderUI.instance, "reader opened")
        assert.equal(path, ReaderUI.instance.document.file)
        close_all()
    end)

    it("asks before touching an existing file; Read existing opens it", function()
        local fm = open_fm()
        local calls = fake_transport(fm, { code = 200, body = PDF })
        submit(fm, "2609.16338")
        assert.equal(0, calls.n)
        press(top(), "Read existing")
        local ReaderUI = require("apps/reader/readerui")
        assert.truthy(ReaderUI.instance, "reader opened")
        close_all()
    end)

    it("Cancel on the existing-file prompt changes nothing", function()
        local fm = open_fm()
        local calls = fake_transport(fm, { code = 200, body = HTML })
        submit(fm, "2609.16338")
        press(top(), "Cancel")
        assert.equal(0, calls.n)
        assert.equal(PDF, read_file(DOWNLOADS .. "/2609.16338.pdf"))
    end)

    it("a failed overwrite keeps the original bytes and leaves no temp files", function()
        local fm = open_fm()
        write_file(DOWNLOADS .. "/2609.16338.pdf", PDF)
        local calls = fake_transport(fm, { code = 200, body = HTML })
        submit(fm, "2609.16338")
        press(top(), "Overwrite")
        assert.equal(1, calls.n)
        assert.equal(PDF, read_file(DOWNLOADS .. "/2609.16338.pdf"))
        assert.equal("2609.16338.pdf", dir_entries())
        assert.truthy(top().text and top().text:find("did not return a PDF"), "error shown")
        close_all()
    end)

    it("a 404 shows an error and creates no file", function()
        clear_downloads()
        local fm = open_fm()
        fake_transport(fm, { code = 404, body = HTML })
        submit(fm, "2609.99999")
        assert.equal("", dir_entries())
        assert.truthy(top().text and top().text:find("HTTP 404"), "404 error shown")
        close_all()
    end)

    it("offline: defers to NetworkMgr and starts no transfer", function()
        clear_downloads()
        local fm = open_fm()
        local calls = fake_transport(fm, { code = 200, body = PDF })
        local orig_connected, orig_before = NetworkMgr.isConnected, NetworkMgr.beforeWifiAction
        local deferred = 0
        NetworkMgr.isConnected = function() return false end
        NetworkMgr.beforeWifiAction = function() deferred = deferred + 1 end
        local ok, err = pcall(submit, fm, "2609.16338")
        NetworkMgr.isConnected, NetworkMgr.beforeWifiAction = orig_connected, orig_before
        assert.truthy(ok, tostring(err))
        assert.equal(1, deferred)
        assert.equal(0, calls.n)
        assert.equal("", dir_entries())
        assert.falsy(fm.arxiv.busy)
        close_all()
    end)
end)

if os.getenv("ARXIV_REAL_NETWORK") == "1" then
    local REAL_ID = os.getenv("ARXIV_REAL_ID") or "2609.16338"
    describe("real network (arxiv.org)", function()
        it("downloads " .. REAL_ID .. " with TLS verification and opens it", function()
            clear_downloads()
            local fm = open_fm()
            fm.arxiv.download.koreader_request = real_request or fm.arxiv.download.koreader_request
            submit(fm, "https://arxiv.org/abs/" .. REAL_ID)
            local path = DOWNLOADS .. "/" .. REAL_ID .. ".pdf"
            local data = read_file(path)
            assert.truthy(data and data:sub(1, 5) == "%PDF-", "real PDF saved")
            assert.equal(REAL_ID .. ".pdf", dir_entries())
            press(top(), "Read now")
            local ReaderUI = require("apps/reader/readerui")
            assert.truthy(ReaderUI.instance and ReaderUI.instance.document.file == path, "opened")
            close_all()
        end)

        it("rejects a certificate whose names do not match the host", function()
            local request = real_request or open_fm().arxiv.download.koreader_request
            local code, err = request({ url = "https://wrong.host.badssl.com/", sink = function() return 1 end })
            assert.equal(nil, code)
            assert.truthy(tostring(err):find("hostname mismatch"), tostring(err))
            code, err = request({ url = "https://expired.badssl.com/", sink = function() return 1 end })
            assert.equal(nil, code)
            assert.truthy(tostring(err):find("certificate"), tostring(err))
        end)
    end)
end

close_all()
UIManager:quit()
