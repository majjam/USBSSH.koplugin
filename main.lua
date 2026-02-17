local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

-- This plugin uses a patched dropbear that adds two things:
-- the -n option to bypass password checks
-- reads the authorized_keys file from the relative path: settings/SSH/authorized_keys

local data_dir = DataStorage:getFullDataDir()
local pid_path = "/tmp/dropbear_koreader_usb.pid"
local usb_gadget_path = "/etc/init.d/usb-gadget"
local usb_net_if = "rndis0"
if not util.pathExists("dropbear") then
    return { disabled = true, }
end

local USBSSH = WidgetContainer:extend{
    name = "USBSSH",
    is_doc_only = false,
}

function USBSSH:init()
    self.SSH_port = G_reader_settings:readSetting("USBSSH_port") or "2222"
    self.allow_no_password = G_reader_settings:isTrue("USBSSH_allow_no_password")
    self.autostart = G_reader_settings:isTrue("USBSSH_autostart")
    self.stop_usb_on_stop = G_reader_settings:nilOrTrue("USBSSH_stop_usb_on_stop")

    if self.autostart then
        self:start()
    end

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

function USBSSH:startUSBGadgetEthernet()
    if not Device:isKobo() then
        return true
    end
    if not util.pathExists(usb_gadget_path) then
        return false, _("USB gadget helper not found.")
    end
    if os.execute(string.format("%q start ethernet", usb_gadget_path)) ~= 0 then
        return false, _("Failed to start USB ethernet gadget.")
    end
    for _ = 1, 20 do
        if util.pathExists("/sys/class/net/" .. usb_net_if) then
            return true
        end
        ffiutil.sleep(0.1)
    end
    return false, _("USB ethernet interface did not come up.")
end

function USBSSH:stopUSBGadgetEthernet()
    if not Device:isKobo() then
        return true
    end
    if not util.pathExists(usb_gadget_path) then
        return true
    end
    return os.execute(string.format("%q stop ethernet", usb_gadget_path)) == 0
end

function USBSSH:start()
    if self:isRunning() then
        logger.dbg("[USBSSH] Not starting SSH server, already running.")
        return
    end

    local ok, err = self:startUSBGadgetEthernet()
    if not ok then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = err,
        })
        return
    end

    local cmd = string.format("%s %s %s %s%s %s",
        "./dropbear",
        "-E",
        "-R",
        "-p", self.SSH_port,
        "-P " .. pid_path)
    if self.allow_no_password then
        cmd = string.format("%s %s", cmd, "-n")
    end

    -- An SSH/telnet server needs pseudoterminals.
    if Device:isKobo() then
        os.execute([[if [ ! -d "/dev/pts" ] ; then
            mkdir -p /dev/pts
            mount -t devpts devpts /dev/pts
            fi]])
    end

    if not util.pathExists(data_dir .. "/settings/SSH/") then
        os.execute("mkdir -p " .. data_dir .. "/settings/SSH")
    end
    logger.dbg("[USBSSH] Launching SSH server:", cmd)
    if os.execute(cmd) == 0 then
        UIManager:show(InfoMessage:new{
            timeout = 12,
            text = T(_("USB SSH server started.\n\nSSH port: %1\n%2"),
                self.SSH_port,
                Device.retrieveNetworkInfo and Device:retrieveNetworkInfo() or _("Could not retrieve network info.")),
        })
    else
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Failed to start USB SSH server."),
        })
    end
end

function USBSSH:isRunning()
    return util.pathExists(pid_path)
end

--- Stops the Dropbear process started by this plugin.
--- @param force boolean If true, forces the process to stop if it doesn't exit gracefully.
--- @return boolean Success, string|nil Error
function USBSSH:stopPlugin(force)
    if not self:isRunning() then
        return true
    end

    local function readPID()
        local f = io.open(pid_path, "r")
        if not f then
            return nil
        end
        local s = f:read("*l")
        f:close()
        return s and tonumber(s) or nil
    end

    local pid = readPID()

    local function isProcAlive(p)
        return p and util.pathExists("/proc/" .. p)
    end

    local function send(sig, p)
        return os.execute(string.format("kill -%s %d", sig, p)) == 0
    end

    send("TERM", pid)
    for _ = 1, 20 do
        if not isProcAlive(pid) then
            break
        end
        ffiutil.sleep(0.1)
    end

    if isProcAlive(pid) and force then
        send("KILL", pid)
        for _ = 1, 10 do
            if not isProcAlive(pid) then
                break
            end
            ffiutil.sleep(0.1)
        end
    end

    if not isProcAlive(pid) then
        os.remove(pid_path)
        return true
    end
    return false, "dropbear process did not exit"
end

function USBSSH:stop()
    local ok, err = self:stopPlugin(false)
    if not ok then
        logger.warn("USBSSH: graceful stop failed:", err)
        ok, err = self:stopPlugin(true)
        if not ok then
            logger.err("USBSSH: force-stop failed:", err)
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("Failed to stop USB SSH server."),
            })
            return
        end
    end

    if self.stop_usb_on_stop then
        self:stopUSBGadgetEthernet()
    end

    UIManager:show(InfoMessage:new{
        text = _("USB SSH server stopped."),
        timeout = 2,
    })
end

function USBSSH:onToggleUSBSSHServer()
    if self:isRunning() then
        self:stop()
    else
        self:start()
    end
end

function USBSSH:show_port_dialog(touchmenu_instance)
    self.port_dialog = InputDialog:new{
        title = _("Choose SSH port"),
        input = self.SSH_port,
        input_type = "number",
        input_hint = self.SSH_port,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.port_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = tonumber(self.port_dialog:getInputText())
                        if value and value >= 0 then
                            self.SSH_port = value
                            G_reader_settings:saveSetting("USBSSH_port", self.SSH_port)
                            UIManager:close(self.port_dialog)
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.port_dialog)
    self.port_dialog:onShowKeyboard()
end

function USBSSH:addToMainMenu(menu_items)
    menu_items.usb_ssh = {
        text = _("USB SSH server"),
        sorting_hint = "network",
        checked_func = function() return self:isRunning() end,
        hold_callback = function(touchmenu_instance)
            self:onToggleUSBSSHServer()
            ffiutil.sleep(1)
            touchmenu_instance:updateItems()
        end,
        sub_item_table = {
            {
                text = _("USB SSH server"),
                checked_func = function() return self:isRunning() end,
                check_callback_updates_menu = true,
                callback = function(touchmenu_instance)
                    self:onToggleUSBSSHServer()
                    ffiutil.sleep(1)
                    touchmenu_instance:updateItems()
                end,
            },
            {
                text_func = function()
                    return T(_("SSH port: %1"), self.SSH_port)
                end,
                keep_menu_open = true,
                enabled_func = function() return not self:isRunning() end,
                callback = function(touchmenu_instance)
                    self:show_port_dialog(touchmenu_instance)
                end,
            },
            {
                text = _("SSH public key"),
                keep_menu_open = true,
                enabled_func = function() return not self:isRunning() end,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        timeout = 60,
                        text = T(_("Put your public SSH keys in\n%1"), BD.filepath(data_dir .. "/settings/SSH/authorized_keys")),
                    })
                end,
            },
            {
                text = _("Login without password (DANGEROUS)"),
                checked_func = function() return self.allow_no_password end,
                enabled_func = function() return not self:isRunning() end,
                callback = function()
                    self.allow_no_password = not self.allow_no_password
                    G_reader_settings:flipNilOrFalse("USBSSH_allow_no_password")
                end,
            },
            {
                text = _("Stop USB ethernet when SSH stops"),
                checked_func = function() return self.stop_usb_on_stop end,
                enabled_func = function() return not self:isRunning() end,
                callback = function()
                    self.stop_usb_on_stop = not self.stop_usb_on_stop
                    if self.stop_usb_on_stop then
                        G_reader_settings:saveSetting("USBSSH_stop_usb_on_stop", true)
                    else
                        G_reader_settings:delSetting("USBSSH_stop_usb_on_stop")
                    end
                end,
            },
            {
                text = _("Start USB SSH server with KOReader"),
                checked_func = function() return self.autostart end,
                enabled_func = function() return not self:isRunning() end,
                callback = function()
                    self.autostart = not self.autostart
                    G_reader_settings:flipNilOrFalse("USBSSH_autostart")
                end,
            },
        },
    }
end

function USBSSH:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_usb_ssh_server", {
        category = "none",
        event = "ToggleUSBSSHServer",
        title = _("Toggle USB SSH server"),
        general = true,
    })
end

return USBSSH
