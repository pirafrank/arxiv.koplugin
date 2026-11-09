--[[--
arXiv PDF downloader for KOReader's File Manager.

UI glue only: parsing lives in arxiv.lua, transfer and file handling in download.lua.
]]

local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

-- Load siblings by path: require("download") could return an unrelated module
-- that another plugin already cached under the same generic name.
local plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local ArxivId = dofile(plugin_dir .. "/arxiv.lua")
local Download = dofile(plugin_dir .. "/download.lua")

local PARSE_ERRORS = {
    empty = _("Please enter an arXiv identifier or URL."),
    unsupported_legacy = _("Old-style identifiers (before April 2007, e.g. cs/9901001) are not supported yet."),
    untrusted_host = _("Only arxiv.org links are accepted."),
}

local DOWNLOAD_ERRORS = {
    not_found = _("arXiv has no PDF for this identifier (HTTP 404). Check the ID and version."),
    http_error = _("arXiv returned an error (HTTP %1). Please try again later."),
    network = _("Network error. Check your Wi-Fi connection and try again."),
    timeout = _("The connection timed out. Check your Wi-Fi connection and try again."),
    tls = _("Secure connection to arXiv failed (certificate check). Check the device date and time."),
    insecure_redirect = _("Download refused: the server redirected to an insecure (HTTP) address."),
    bad_redirect = _("Download refused: the server redirected to an unexpected address."),
    redirect_loop = _("Download refused: the server redirected in a loop."),
    too_many_redirects = _("Download refused: too many redirects."),
    too_large = _("Download refused: the PDF exceeds the 100 MiB size limit."),
    empty = _("The server returned an empty file."),
    invalid_pdf = _("The server did not return a PDF."),
    truncated = _("The download was incomplete. Please try again."),
    fs_error = _("Could not write the file. Check free space and that the download folder is writable."),
    invalid_destination = _("The download folder is not usable."),
    busy = _("A download for this paper is already in progress."),
    exists = _("The file already exists; nothing was changed."),
    internal = _("Unexpected error. Please report it with your KOReader crash.log."),
}

local Arxiv = WidgetContainer:extend{
    name = "arxiv",
    busy = false,
    -- Exposed for the integration spec (transport injection); not a public API.
    arxiv_id = ArxivId,
    download = Download,
}

function Arxiv:init()
    self.ui.menu:registerToMainMenu(self)
end

function Arxiv:addToMainMenu(menu_items)
    if self.ui.document then -- File Manager only in v0.1
        return
    end
    menu_items.arxiv_download_pdf = {
        text = _("Download arXiv PDF"),
        sorting_hint = "search",
        callback = function()
            self:showInputDialog()
        end,
    }
end

function Arxiv:showInputDialog()
    self.input_dialog = InputDialog:new{
        title = _("arXiv paper ID or URL"),
        input_hint = "2609.16338",
        description = _("For example 2609.16338, 2609.16338v2 or https://arxiv.org/abs/2609.16338"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    self:closeInputDialog()
                end,
            },
            {
                text = _("Download"),
                id = "download",
                is_enter_default = true,
                callback = function()
                    self:onSubmit(self.input_dialog:getInputText())
                end,
            },
        }},
    }
    UIManager:show(self.input_dialog)
    self.input_dialog:onShowKeyboard()
end

function Arxiv:closeInputDialog()
    if self.input_dialog then
        UIManager:close(self.input_dialog)
        self.input_dialog = nil
    end
end

function Arxiv:showMessage(text)
    UIManager:show(InfoMessage:new{ text = text })
end

--- KOReader's shared download folder (the one OPDS uses), or nil.
function Arxiv:getDownloadDir()
    local dir
    local shortcuts = self.ui.folder_shortcuts
    if shortcuts and shortcuts.expandPath then
        dir = shortcuts:expandPath("%D%") -- an unset provider leaves "%D%" unexpanded
    end
    if type(dir) ~= "string" or dir:find("%D%", 1, true) then
        dir = G_reader_settings:readSetting("download_dir") or G_reader_settings:readSetting("lastdir")
    end
    if type(dir) ~= "string" then
        return nil
    end
    dir = dir:gsub("/+$", "")
    if not dir:match("^/.") or lfs.attributes(dir, "mode") ~= "directory" then
        return nil
    end
    return dir
end

function Arxiv:onSubmit(text)
    local id, err = ArxivId.parse(text)
    if not id then
        -- Keep the input dialog open so the text can be corrected.
        self:showMessage(PARSE_ERRORS[err] or T(_("Not a valid arXiv identifier or URL:\n%1"), text))
        return
    end
    self:closeInputDialog()
    local dir = self:getDownloadDir()
    if not dir then
        self:showMessage(_("No usable download folder.\nSet KOReader's download folder and try again."))
        return
    end
    local path = dir .. "/" .. ArxivId.filename(id)
    if lfs.symlinkattributes(path, "mode") then
        UIManager:show(MultiConfirmBox:new{
            text = T(_("%1 already exists."), BD.filepath(path)),
            choice1_text = _("Read existing"),
            choice1_callback = function()
                self:openPdf(path)
            end,
            choice2_text = _("Overwrite"),
            choice2_callback = function()
                self:startDownload(id, path, true)
            end,
        })
    else
        self:startDownload(id, path, false)
    end
end

function Arxiv:startDownload(id, path, overwrite)
    if self.busy then
        self:showMessage(DOWNLOAD_ERRORS.busy)
        return
    end
    NetworkMgr:runWhenConnected(function()
        self:runDownload(id, path, overwrite)
    end)
end

function Arxiv:runDownload(id, path, overwrite)
    if self.busy then -- a queued connect callback may arrive twice
        return
    end
    self.busy = true
    local info = InfoMessage:new{ text = T(_("Downloading arXiv:%1…"), id) }
    UIManager:show(info)
    -- Like OPDS: give e-ink time to draw the status before the blocking transfer.
    UIManager:scheduleIn(1, function()
        local ok, result = pcall(self.download.download_pdf, {
            url = ArxivId.build_pdf_url(id),
            destination = path,
            overwrite = overwrite,
        })
        self.busy = false
        UIManager:close(info)
        if not ok then
            result = { ok = false, code = "internal", detail = tostring(result) }
        end
        if result.ok then
            logger.info("arXiv: saved", path)
            self:onDownloaded(path)
        else
            logger.warn("arXiv: download failed", id, result.code, result.detail)
            local text = DOWNLOAD_ERRORS[result.code]
            text = text and T(text, result.detail or "") or T(_("Download failed: %1"), result.code)
            UIManager:nextTick(function()
                self:showMessage(text)
            end)
        end
    end)
end

function Arxiv:onDownloaded(path)
    if self.ui.file_chooser then
        pcall(self.ui.file_chooser.changeToPath, self.ui.file_chooser, path:match("^(.*)/"), path)
    end
    -- Show on the next tick, after the "Downloading" message closes (avoids e-ink congestion, as OPDS does).
    UIManager:nextTick(function()
        UIManager:show(ConfirmBox:new{
            text = T(_("File saved to:\n%1\nWould you like to read it now?"), BD.filepath(path)),
            ok_text = _("Read now"),
            cancel_text = _("Later"),
            ok_callback = function()
                self:openPdf(path)
            end,
        })
    end)
end

function Arxiv:openPdf(path)
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
end

return Arxiv
