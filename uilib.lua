--!nonstrict
--[[
    ────────────────────────────────────────────────────────────────────────────
    GraphiteUI — a single-file Roblox Luau GUI library
    ────────────────────────────────────────────────────────────────────────────
    A sleek, monochrome (black / grey) retained-mode UI library in the spirit of
    Dear ImGui / Rayfield / Fluent. No external dependencies, no HTTP requests,
    no third-party assets. Drop it in a ModuleScript and require() it, or load
    it with loadstring() — either way it returns the `Library` singleton.

    Widget set (ImGui parity + Roblox extras):
      Window (drag / resize / minimize / close / icon / toggle key)
      MenuBar + Menu + MenuItem, Tabs, CollapsingHeader (Section, nestable),
      Button, Toggle/Checkbox (with managed loop threads), RadioGroup,
      Dropdown (single + multi select), Slider (int/float), DragInput,
      InputText (placeholder + numeric mode), ColorPicker (HSV + hex),
      ListBox, Table, ProgressBar, Label, Separator, Tooltip (on any widget),
      Modal Dialog, Notifications/Toasts, Keybind picker.

    Threading note (important):
      Roblox Luau has no OS-level parallelism in a LocalScript. "Multithreading"
      here means independent, non-blocking *cooperative* threads created with
      task.spawn(). Each Toggle's LoopCallback runs on its own coroutine so any
      number of toggles can loop simultaneously without blocking each other or
      the UI. The library owns the full thread lifecycle: it starts the loop
      when a toggle turns on, and the loop exits cleanly on its next iteration
      when the toggle turns off (or is destroyed / the window unloads). Errors
      inside loops are caught with xpcall + traceback and surfaced through the
      notification system instead of silently killing the thread.

    Performance notes:
      - No RenderStepped/Heartbeat connections are used by the library itself.
      - Pointer-drag connections are created on press and disconnected on release.
      - Instances are reused; nothing is created/destroyed per frame.
      - Every RBXScriptConnection is tracked in a Maid and disconnected on
        widget/window destroy and on Library:Unload().

    Quick start (full example at the bottom of the file):
        local Library = require(script.GraphiteUI) -- or loadstring(...)()
        local Window  = Library:CreateWindow({ Title = "My Menu" })
        local Tab     = Window:CreateTab("Main")
        Tab:CreateToggle({ Name = "Auto Farm", LoopCallback = function() end })
    ────────────────────────────────────────────────────────────────────────────
]]

-- ═══════════════════════════════════════════ Services ══════════════════════

local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService") -- GenerateGUID only; no HTTP requests
local Players          = game:GetService("Players")
local CoreGui          = game:GetService("CoreGui")

-- ═══════════════════════════════════════════ Theme ═════════════════════════

-- Re-skin the whole library by editing this table (or calling Library:SetTheme
-- with a partial override table at runtime — every themed property re-applies).
local Theme = {
	-- Colors (monochrome by default; Accent is the single configurable pop color)
	WindowBackground = Color3.fromRGB(15, 15, 17),
	TitleBar         = Color3.fromRGB(22, 22, 25),
	Sidebar          = Color3.fromRGB(18, 18, 21),
	Panel            = Color3.fromRGB(27, 27, 31),   -- widget row background
	PanelHover       = Color3.fromRGB(35, 35, 40),
	PanelActive      = Color3.fromRGB(44, 44, 50),
	Section          = Color3.fromRGB(21, 21, 24),   -- collapsing headers / inset areas
	Border           = Color3.fromRGB(48, 48, 55),
	Text             = Color3.fromRGB(235, 235, 240),
	SubText          = Color3.fromRGB(152, 152, 160),
	DisabledText     = Color3.fromRGB(95, 95, 102),
	Accent           = Color3.fromRGB(230, 230, 235), -- neutral light grey by default
	AccentText       = Color3.fromRGB(20, 20, 22),    -- text/knob color drawn on top of Accent

	-- Typography
	Font         = Enum.Font.Gotham,
	FontSemibold = Enum.Font.GothamMedium,
	FontBold     = Enum.Font.GothamBold,
	TextSize     = 13,

	-- Shape
	CornerRadius = 6,
}

-- Instances registered here get their themed properties re-applied by
-- Library:SetTheme(). Weak keys so destroyed instances can be collected.
local ThemeRegistry: { [Instance]: { [string]: string } } = setmetatable({}, { __mode = "k" }) :: any

local function ResolveThemeValue(prop: string, key: string): any
	local value = Theme[key]
	if prop == "CornerRadius" then
		return UDim.new(0, value)
	end
	return value
end

local function SetThemedProp(inst: Instance, prop: string, key: string)
	(inst :: any)[prop] = ResolveThemeValue(prop, key)
end

-- Applies a map of { PropertyName = "ThemeKey" } and registers it for re-theming.
local function Themed(inst: Instance, map: { [string]: string })
	for prop, key in pairs(map) do
		SetThemedProp(inst, prop, key)
	end
	ThemeRegistry[inst] = map
end

-- ═══════════════════════════════════════════ Utilities ═════════════════════

-- Instance factory. Special props:
--   Parent — applied last (cheaper: descendants build before hitting the tree)
--   Theme  — { PropertyName = "ThemeKey" } map, applied + registered via Themed()
local function Create(className: string, props: { [string]: any }?, children: { Instance }?): Instance
	local inst = Instance.new(className)
	local parent, themeMap = nil, nil
	if props then
		for key, value in pairs(props) do
			if key == "Parent" then
				parent = value
			elseif key == "Theme" then
				themeMap = value
			else
				(inst :: any)[key] = value
			end
		end
	end
	if themeMap then
		Themed(inst, themeMap)
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function Tween(inst: Instance, props: { [string]: any }, duration: number?, style: Enum.EasingStyle?, direction: Enum.EasingDirection?): Tween
	local tween = TweenService:Create(
		inst,
		TweenInfo.new(duration or 0.16, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out),
		props
	)
	tween:Play()
	return tween
end

local function Corner(inst: Instance, radius: number?): UICorner
	local corner = Instance.new("UICorner")
	if radius then
		corner.CornerRadius = UDim.new(0, radius)
	else
		Themed(corner, { CornerRadius = "CornerRadius" })
	end
	corner.Parent = inst
	return corner
end

local function Stroke(inst: Instance, transparency: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Thickness = 1
	stroke.Transparency = transparency or 0
	Themed(stroke, { Color = "Border" })
	stroke.Parent = inst
	return stroke
end

local function Pad(inst: Instance, left: number?, top: number?, right: number?, bottom: number?): UIPadding
	return Create("UIPadding", {
		PaddingLeft = UDim.new(0, left or 0),
		PaddingTop = UDim.new(0, top or 0),
		PaddingRight = UDim.new(0, right or 0),
		PaddingBottom = UDim.new(0, bottom or 0),
		Parent = inst,
	}) :: UIPadding
end

local function VList(inst: Instance, spacing: number?): UIListLayout
	return Create("UIListLayout", {
		Padding = UDim.new(0, spacing or 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = inst,
	}) :: UIListLayout
end

-- TextLabel factory with library defaults baked in.
local function Text(props: { [string]: any }): TextLabel
	local themeMap = props.Theme or {}
	if themeMap.TextColor3 == nil then
		themeMap.TextColor3 = "Text"
	end
	if themeMap.Font == nil then
		themeMap.Font = "Font"
	end
	props.Theme = themeMap
	if props.BackgroundTransparency == nil then
		props.BackgroundTransparency = 1
	end
	props.BorderSizePixel = 0
	props.TextSize = props.TextSize or Theme.TextSize
	if props.TextXAlignment == nil then
		props.TextXAlignment = Enum.TextXAlignment.Left
	end
	return Create("TextLabel", props) :: TextLabel
end

-- Minimal Maid: tracks connections / instances / threads / cleanup functions
-- and releases all of them on :Clean(). :Destroy() is an alias so Maids can
-- nest inside other Maids.
local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({ _jobs = {} }, Maid)
end

function Maid:Add(job)
	table.insert(self._jobs, job)
	return job
end

function Maid:Clean()
	local jobs = self._jobs
	self._jobs = {}
	for _, job in ipairs(jobs) do
		local kind = typeof(job)
		if kind == "RBXScriptConnection" then
			job:Disconnect()
		elseif kind == "Instance" then
			job:Destroy()
		elseif kind == "thread" then
			pcall(task.cancel, job)
		elseif kind == "function" then
			pcall(job)
		elseif kind == "table" and job.Destroy then
			pcall(job.Destroy, job)
		elseif kind == "table" and job.Clean then
			pcall(job.Clean, job)
		end
	end
end

Maid.Destroy = Maid.Clean

-- InputObject.Position (and the x/y passed by GuiObject.MouseEnter) live in the
-- same coordinate space as GuiObject.AbsolutePosition, so pointer math can
-- compare the two directly. GetMouseLocation() does NOT share that space (it
-- includes the topbar inset), which is why it is not used anywhere in this
-- file. To place an element inside the ScreenGui at an AbsolutePosition-space
-- point, subtract ScreenGui.AbsolutePosition (see tooltip / menu popups).
local function PointerPos(input: InputObject): Vector2
	return Vector2.new(input.Position.X, input.Position.Y)
end

local function InBounds(gui: GuiObject, pos: Vector2): boolean
	local p, s = gui.AbsolutePosition, gui.AbsoluteSize
	return pos.X >= p.X and pos.X <= p.X + s.X and pos.Y >= p.Y and pos.Y <= p.Y + s.Y
end

-- Runs onMove(screenPos) for every pointer move until the button/touch lifts.
-- Both connections disconnect themselves on release (and are Maid-tracked in
-- case the widget dies mid-drag).
local function BeginPointerDrag(maid, onMove: (Vector2) -> (), onEnd: (() -> ())?)
	local moveConn, endConn
	moveConn = UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			onMove(PointerPos(input))
		end
	end)
	endConn = UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			moveConn:Disconnect()
			endConn:Disconnect()
			if onEnd then
				onEnd()
			end
		end
	end)
	maid:Add(moveConn)
	maid:Add(endConn)
end

local function IsPress(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

-- Snaps a value to a step (relative to min when provided) and clamps.
local function Snap(value: number, step: number?, min: number?, max: number?): number
	if step and step > 0 then
		local base = min or 0
		value = math.floor((value - base) / step + 0.5) * step + base
	end
	if min then
		value = math.max(value, min)
	end
	if max then
		value = math.min(value, max)
	end
	return value
end

local function DecimalsOf(step: number): number
	local s = tostring(step)
	local dot = string.find(s, ".", 1, true)
	if dot then
		return math.min(#s - dot, 4)
	end
	return 0
end

local function FormatNumber(value: number, decimals: number): string
	if decimals <= 0 then
		return tostring(math.floor(value + 0.5))
	end
	return string.format("%." .. decimals .. "f", value)
end

-- Hover/press color feedback for a row or button.
local function Hoverable(maid, inst: GuiObject, normalKey: string, hoverKey: string, isEnabled: (() -> boolean)?)
	maid:Add(inst.MouseEnter:Connect(function()
		if isEnabled == nil or isEnabled() then
			Tween(inst, { BackgroundColor3 = Theme[hoverKey] }, 0.12)
		end
	end))
	maid:Add(inst.MouseLeave:Connect(function()
		Tween(inst, { BackgroundColor3 = Theme[normalKey] }, 0.12)
	end))
end

-- Best available parent: gethui() (exploit env) → CoreGui (if writable) → PlayerGui.
local function GetGuiParent(): Instance
	local ok, hui = pcall(function()
		local getHui = (getgenv and getgenv().gethui) or gethui
		return getHui and getHui() or nil
	end)
	if ok and typeof(hui) == "Instance" then
		return hui
	end
	local canCoreGui = pcall(function()
		local probe = Instance.new("Folder")
		probe.Parent = CoreGui
		probe:Destroy()
	end)
	if canCoreGui then
		return CoreGui
	end
	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	return playerGui or CoreGui
end

-- Calls a user callback safely; errors are logged with a traceback and surfaced
-- as a notification instead of breaking the UI or other callbacks.
local function SafeCall(library, label: string, callback, ...)
	if callback == nil then
		return
	end
	local ok, err = xpcall(callback, function(e)
		return debug.traceback(tostring(e), 2)
	end, ...)
	if not ok then
		warn(("[GraphiteUI] %s error:\n%s"):format(label, err))
		pcall(function()
			library:Notify({
				Title = "Callback error",
				Content = label .. " raised an error — see the console (F9) for the traceback.",
				Duration = 5,
			})
		end)
	end
end

-- ═══════════════════════════════════════════ Library core ══════════════════

local Library = {}
Library.Name = "GraphiteUI"
Library.Version = "1.0.0"
Library.Theme = Theme        -- expose the theme table (mutate or use SetTheme)
Library.Windows = {}         -- all live Window objects
Library.Flags = {}           -- Flag -> widget object (for config save/load)
Library._maid = Maid.new()
Library._unloaded = false

-- Lazily builds the ScreenGui plus the shared tooltip / notification layers.
function Library:_ensureGui()
	if self._gui then
		return
	end
	local guiParent = GetGuiParent()
	-- Re-executing the script creates a fresh Library instance whose Unload()
	-- can't know about the old one — so each new load sweeps stale GraphiteUI
	-- guis left behind by a previous execution.
	for _, child in ipairs(guiParent:GetChildren()) do
		if child:IsA("ScreenGui") and child:GetAttribute("GraphiteUI") then
			child:Destroy()
		end
	end
	local gui = Create("ScreenGui", {
		Name = "graphite_" .. HttpService:GenerateGUID(false),
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 999,
	})
	gui:SetAttribute("GraphiteUI", true)
	gui.Parent = guiParent
	self._gui = gui
	self._topZ = 10 -- incremented to bring clicked windows to the front

	-- Notification stack (bottom-right).
	self._notifRoot = Create("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -16),
		Size = UDim2.new(0, 300, 1, -32),
		ZIndex = 200,
		Parent = gui,
	})
	Create("UIListLayout", {
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		Parent = self._notifRoot,
	})

	-- Shared tooltip (one instance reused for every widget).
	self._tooltip = Text({
		Theme = { TextColor3 = "Text", BackgroundColor3 = "Panel" },
		BackgroundTransparency = 0,
		TextSize = 12,
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		Visible = false,
		ZIndex = 500,
		Parent = gui,
	})
	Pad(self._tooltip, 8, 6, 8, 6)
	Corner(self._tooltip, 4)
	Stroke(self._tooltip)
	Create("UISizeConstraint", { MaxSize = Vector2.new(260, math.huge), Parent = self._tooltip })

	-- Close any open popup (menus) when clicking outside of it.
	self._maid:Add(UserInputService.InputBegan:Connect(function(input)
		if IsPress(input) then
			local popup = self._popup
			if popup then
				local pos = PointerPos(input)
				if not InBounds(popup.frame, pos) and not InBounds(popup.anchor, pos) then
					self:_closePopup()
				end
			end
		end
	end))

	-- Make sure the tooltip-follow connection dies on Unload.
	self._maid:Add(function()
		if self._tooltipConn then
			self._tooltipConn:Disconnect()
			self._tooltipConn = nil
		end
	end)
end

-- ─────────────────────────────── Tooltip ────────────────────────────────────

function Library:_showTooltip(text: string, pointer: Vector2?)
	self:_ensureGui()
	local tip = self._tooltip
	tip.Text = text
	tip.Visible = true
	local function place(pos: Vector2)
		-- pos is AbsolutePosition-space; convert to this ScreenGui's local space
		local localPos = pos - self._gui.AbsolutePosition
		local screen = self._gui.AbsoluteSize
		local size = tip.AbsoluteSize
		tip.Position = UDim2.fromOffset(
			math.min(localPos.X + 14, math.max(0, screen.X - size.X - 4)),
			math.min(localPos.Y + 12, math.max(0, screen.Y - size.Y - 4))
		)
	end
	if pointer then
		place(pointer)
	end
	-- Follow the pointer only while visible; connection is dropped on hide so
	-- there is no permanent InputChanged listener.
	if self._tooltipConn then
		self._tooltipConn:Disconnect()
	end
	self._tooltipConn = UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			place(PointerPos(input))
		end
	end)
end

function Library:_hideTooltip()
	if self._tooltipConn then
		self._tooltipConn:Disconnect()
		self._tooltipConn = nil
	end
	if self._tooltip then
		self._tooltip.Visible = false
	end
end

local function AttachTooltip(library, inst: GuiObject, text: string, maid)
	maid:Add(inst.MouseEnter:Connect(function(x, y)
		library:_showTooltip(text, Vector2.new(x, y))
	end))
	maid:Add(inst.MouseLeave:Connect(function()
		library:_hideTooltip()
	end))
	maid:Add(function()
		if library._tooltip and library._tooltip.Visible then
			library:_hideTooltip()
		end
	end)
end

-- ─────────────────────────────── Popups (menus) ─────────────────────────────

function Library:_setPopup(frame: GuiObject, anchor: GuiObject, close: () -> ())
	self:_closePopup()
	self._popup = { frame = frame, anchor = anchor, close = close }
end

function Library:_closePopup()
	local popup = self._popup
	if popup then
		self._popup = nil
		popup.close()
	end
end

-- ─────────────────────────────── Notifications ──────────────────────────────

-- Library:Notify({ Title, Content, Duration }) -> { Dismiss = fn, Instance = holder }
function Library:Notify(options)
	options = options or {}
	self:_ensureGui()
	local duration = options.Duration or 4

	local holder = Create("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = self._notifRoot,
	})
	local inner = Create("Frame", {
		Theme = { BackgroundColor3 = "Panel" },
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(340, 0), -- starts off-screen right, slides in
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = holder,
	})
	Corner(inner)
	Stroke(inner)
	Pad(inner, 0, 0, 0, 12)

	Text({
		Theme = { TextColor3 = "Text", Font = "FontBold" },
		Text = tostring(options.Title or Library.Name),
		TextSize = 13,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(14, 10),
		Size = UDim2.new(1, -26, 0, 16),
		Parent = inner,
	})
	if options.Content then
		Text({
			Theme = { TextColor3 = "SubText" },
			Text = tostring(options.Content),
			TextSize = 12,
			TextWrapped = true,
			Position = UDim2.fromOffset(14, 30),
			Size = UDim2.new(1, -26, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = inner,
		})
	end

	-- Left accent bar doubles as the countdown indicator (shrinks over time).
	local countdown = Create("Frame", {
		Theme = { BackgroundColor3 = "Accent" },
		BorderSizePixel = 0,
		Size = UDim2.new(0, 3, 1, 0),
		Parent = inner,
	})
	Corner(countdown, 2)

	local dismissed = false
	local notification = { Instance = holder }

	function notification:Dismiss()
		if dismissed then
			return
		end
		dismissed = true
		local out = Tween(inner, { Position = UDim2.fromOffset(340, 0) }, 0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		out.Completed:Once(function()
			holder:Destroy()
		end)
	end

	-- Click anywhere on the toast to dismiss early.
	local clickCatcher = Create("TextButton", {
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 5,
		Parent = inner,
	})
	clickCatcher.MouseButton1Click:Connect(function()
		notification:Dismiss()
	end)

	Tween(inner, { Position = UDim2.fromOffset(0, 0) }, 0.25, Enum.EasingStyle.Quint)
	Tween(countdown, { Size = UDim2.new(0, 3, 0, 0) }, duration, Enum.EasingStyle.Linear)
	task.delay(duration, function()
		notification:Dismiss()
	end)

	return notification
end

-- ─────────────────────────────── Theme API ──────────────────────────────────

-- Merge a partial override table into the theme and re-apply every registered
-- themed property, e.g. Library:SetTheme({ Accent = Color3.fromRGB(0,170,255) })
function Library:SetTheme(overrides: { [string]: any })
	for key, value in pairs(overrides or {}) do
		Theme[key] = value
	end
	for inst, map in pairs(ThemeRegistry) do
		for prop, key in pairs(map) do
			pcall(SetThemedProp, inst, prop, key)
		end
	end
end

-- ═══════════════════════════════════ Elements (widget factories) ═══════════
-- Elements is a mixin: Tabs and Sections both inherit every Create* method, so
-- sections (collapsing headers) can host the full widget set, nested.

-- Updates an instance's theme registration without immediately applying it
-- (used by stateful widgets that tween between two theme colors).
local function Retheme(inst: Instance, map: { [string]: string })
	ThemeRegistry[inst] = map
end

local Elements = {}
Elements.__index = Elements

local function NewElementContainer(library, window, container: GuiObject)
	return setmetatable({
		_library = library,
		_window = window,
		_container = container,
		_order = 0,
	}, Elements)
end

function Elements:_nextOrder(): number
	self._order += 1
	return self._order
end

-- Standard widget row. `clickable` swaps the Frame for a TextButton.
function Elements:_baseRow(height: number, clickable: boolean?): GuiObject
	local props: { [string]: any } = {
		Theme = { BackgroundColor3 = "Panel" },
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = self:_nextOrder(),
		Parent = self._container,
	}
	if clickable then
		props.Text = ""
		props.AutoButtonColor = false
	end
	local row = Create(clickable and "TextButton" or "Frame", props) :: GuiObject
	Corner(row)
	return row
end

local function StandardDestroy(library, widget, maid, row: GuiObject, flag: string?)
	return function()
		if widget._destroyed then
			return
		end
		widget._destroyed = true
		maid:Clean()
		row:Destroy()
		if flag then
			library.Flags[flag] = nil
		end
	end
end

-- Shared widget tail: tooltip, config flag, Destroy, Instance handle.
function Elements:_finish(widget, row: GuiObject, maid, options)
	widget.Instance = row
	if options.Tooltip then
		AttachTooltip(self._library, row, tostring(options.Tooltip), maid)
	end
	if options.Flag then
		self._library.Flags[options.Flag] = widget
	end
	widget.Destroy = StandardDestroy(self._library, widget, maid, row, options.Flag)
	return widget
end

-- ─────────────────────────────── Button ─────────────────────────────────────
-- { Name, Callback, Disabled, Tooltip }
function Elements:CreateButton(options)
	options = options or {}
	local library = self._library
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local name = tostring(options.Name or "Button")
	local disabled = options.Disabled == true

	local row = self:_baseRow(34, true)
	local label = Text({
		Theme = { TextColor3 = disabled and "DisabledText" or "Text", Font = "FontSemibold" },
		Text = name,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 1, 0),
		Parent = row,
	})

	Hoverable(maid, row, "Panel", "PanelHover", function()
		return not disabled
	end)
	maid:Add(row.MouseButton1Down:Connect(function()
		if not disabled then
			row.BackgroundColor3 = Theme.PanelActive
		end
	end))
	maid:Add(row.MouseButton1Up:Connect(function()
		if not disabled then
			Tween(row, { BackgroundColor3 = Theme.PanelHover }, 0.12)
		end
	end))
	maid:Add(row.MouseButton1Click:Connect(function()
		if disabled then
			return
		end
		SafeCall(library, "Button '" .. name .. "' Callback", options.Callback)
	end))

	local widget = { _type = "Button", _destroyed = false }
	function widget:Set(text)
		name = tostring(text)
		label.Text = name
	end
	function widget:Get()
		return name
	end
	function widget:SetDisabled(state: boolean)
		disabled = state == true
		Themed(label, { TextColor3 = disabled and "DisabledText" or "Text", Font = "FontSemibold" })
	end
	return self:_finish(widget, row, maid, options)
end

-- ─────────────────────────────── Toggle / Checkbox ──────────────────────────
-- { Name, Default, Callback(state), LoopCallback, LoopInterval, Tooltip, Flag }
--
-- Callback fires once per state change. LoopCallback (optional) runs on its own
-- cooperative thread (task.spawn) the entire time the toggle is on — every
-- toggle's loop is independent, so any number can run simultaneously without
-- blocking each other or the UI. The library manages the whole thread
-- lifecycle; you never write the `while task.wait()` boilerplate or a stop
-- flag yourself.
function Elements:CreateToggle(options)
	options = options or {}
	local library = self._library
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local name = tostring(options.Name or "Toggle")
	local value = options.Default == true
	local loopGen = 0 -- generation counter: bumping it retires the active loop
	local activeThread: thread? = nil
	local loopErrorNotified = false

	local row = self:_baseRow(34, true)
	Hoverable(maid, row, "Panel", "PanelHover")
	Text({
		Theme = { Font = "FontSemibold" },
		Text = name,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -70, 1, 0),
		Parent = row,
	})

	local switch = Create("Frame", {
		BackgroundColor3 = Theme.PanelActive,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(38, 20),
		Parent = row,
	})
	Corner(switch, 10)
	local knob = Create("Frame", {
		BackgroundColor3 = Theme.Text,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		Parent = switch,
	})
	Corner(knob, 7)

	local widget = { _type = "Toggle", _destroyed = false }

	local function render(instant: boolean)
		Retheme(switch, { BackgroundColor3 = value and "Accent" or "PanelActive" })
		Retheme(knob, { BackgroundColor3 = value and "AccentText" or "Text" })
		local switchColor = value and Theme.Accent or Theme.PanelActive
		local knobColor = value and Theme.AccentText or Theme.Text
		local knobPos = value and UDim2.new(1, -17, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
		if instant then
			switch.BackgroundColor3 = switchColor
			knob.BackgroundColor3 = knobColor
			knob.Position = knobPos
		else
			Tween(switch, { BackgroundColor3 = switchColor }, 0.14)
			Tween(knob, { BackgroundColor3 = knobColor, Position = knobPos }, 0.14, Enum.EasingStyle.Back)
		end
	end

	local function startLoop()
		if options.LoopCallback == nil then
			return
		end
		loopGen += 1
		local gen = loopGen
		loopErrorNotified = false
		local interval = options.LoopInterval -- nil => one scheduler step per iteration
		-- NOTE: this is a cooperative Luau thread (task.spawn), not OS-level
		-- parallelism — Roblox LocalScripts have none. It IS fully independent
		-- of the main thread and of every other toggle's loop.
		activeThread = task.spawn(function()
			while value and gen == loopGen and not widget._destroyed do
				local ok, err = xpcall(options.LoopCallback, function(e)
					return debug.traceback(tostring(e), 2)
				end)
				if not ok then
					warn(("[GraphiteUI] Toggle '%s' loop error:\n%s"):format(name, err))
					if not loopErrorNotified then
						loopErrorNotified = true -- notify once per activation, keep looping
						library:Notify({
							Title = "Loop error",
							Content = ("Toggle '%s' loop errored — see console (F9). The loop keeps running."):format(name),
							Duration = 5,
						})
					end
				end
				task.wait(interval)
			end
			if gen == loopGen then
				activeThread = nil
			end
		end)
	end

	local function stopLoop()
		-- The loop re-checks its guard after the current task.wait and exits
		-- cleanly on its own — no orphaned threads, no pcall-swallowed errors.
		loopGen += 1
	end

	-- Hard-cancel on destroy so a long LoopInterval never lingers past teardown.
	maid:Add(function()
		if activeThread then
			pcall(task.cancel, activeThread)
			activeThread = nil
		end
	end)

	local function set(newValue, silent)
		newValue = newValue == true
		if newValue == value then
			return
		end
		value = newValue
		render(false)
		if not silent then
			SafeCall(library, "Toggle '" .. name .. "' Callback", options.Callback, value)
		end
		if value then
			startLoop()
		else
			stopLoop()
		end
	end

	maid:Add(row.MouseButton1Click:Connect(function()
		set(not value)
	end))

	render(true)
	if value then
		-- Default = true: the loop starts immediately. The one-shot Callback is
		-- not fired for the initial state; call :Set(true) yourself if desired.
		startLoop()
	end

	function widget:Set(v, silent)
		set(v, silent)
	end
	function widget:Get()
		return value
	end
	return self:_finish(widget, row, maid, options)
end

Elements.CreateCheckbox = Elements.CreateToggle -- ImGui checkbox == toggle here

-- ─────────────────────────────── Slider (int + float) ───────────────────────
-- { Name, Min, Max, Step, Default, Suffix, Callback(value), Tooltip, Flag }
-- Step < 1 (e.g. 0.1) makes it a float slider; the live label matches the step.
function Elements:CreateSlider(options)
	options = options or {}
	local library = self._library
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local name = tostring(options.Name or "Slider")
	local min = options.Min or 0
	local max = options.Max or 100
	local step = options.Step or 1
	local suffix = options.Suffix or ""
	local decimals = DecimalsOf(step)
	local value = Snap(tonumber(options.Default) or min, step, min, max)

	local row = self:_baseRow(46, false)
	Hoverable(maid, row, "Panel", "PanelHover")
	Text({
		Theme = { Font = "FontSemibold" },
		Text = name,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(1, -110, 0, 16),
		Parent = row,
	})
	local valueLabel = Text({
		Theme = { TextColor3 = "SubText" },
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 8),
		Size = UDim2.fromOffset(90, 16),
		Parent = row,
	})

	local bar = Create("Frame", {
		Theme = { BackgroundColor3 = "PanelActive" },
		BorderSizePixel = 0,
		Position = UDim2.new(0, 12, 1, -16),
		Size = UDim2.new(1, -24, 0, 6),
		Parent = row,
	})
	Corner(bar, 3)
	local fill = Create("Frame", {
		Theme = { BackgroundColor3 = "Accent" },
		BorderSizePixel = 0,
		Size = UDim2.new(0, 0, 1, 0),
		Parent = bar,
	})
	Corner(fill, 3)
	local knob = Create("Frame", {
		Theme = { BackgroundColor3 = "Accent" },
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(12, 12),
		ZIndex = 2,
		Parent = bar,
	})
	Corner(knob, 6)

	local widget = { _type = "Slider", _destroyed = false }

	local function alpha(): number
		return if max > min then (value - min) / (max - min) else 0
	end

	local function render(instant: boolean)
		local a = alpha()
		valueLabel.Text = FormatNumber(value, decimals) .. suffix
		local fillSize = UDim2.new(a, 0, 1, 0)
		local knobPos = UDim2.new(a, 0, 0.5, 0)
		if instant then
			fill.Size = fillSize
			knob.Position = knobPos
		else
			Tween(fill, { Size = fillSize }, 0.06)
			Tween(knob, { Position = knobPos }, 0.06)
		end
	end

	local function set(v, silent)
		v = Snap(tonumber(v) or min, step, min, max)
		if v == value then
			render(true)
			return
		end
		value = v
		render(false)
		if not silent then
			SafeCall(library, "Slider '" .. name .. "' Callback", options.Callback, value)
		end
	end

	local function fromPointer(pos: Vector2)
		local rel = math.clamp((pos.X - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
		set(min + (max - min) * rel)
	end

	maid:Add(row.InputBegan:Connect(function(input)
		if IsPress(input) then
			fromPointer(PointerPos(input))
			BeginPointerDrag(maid, fromPointer)
		end
	end))

	render(true)
	function widget:Set(v, silent)
		set(v, silent)
	end
	function widget:Get()
		return value
	end
	return self:_finish(widget, row, maid, options)
end

-- ─────────────────────────────── DragInput (DragFloat/DragInt) ──────────────
-- { Name, Min, Max, Step, Sensitivity (units per pixel), Default, Callback }
-- Click the value field and drag horizontally to change it. Min/Max optional.
function Elements:CreateDragInput(options)
	options = options or {}
	local library = self._library
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local name = tostring(options.Name or "Drag")
	local min, max = options.Min, options.Max
	local step = options.Step or 1
	local decimals = DecimalsOf(step)
	local perPixel = options.Sensitivity
		or (if min ~= nil and max ~= nil then (max - min) / 200 else step)
	local value = Snap(tonumber(options.Default) or min or 0, step, min, max)

	local row = self:_baseRow(34, false)
	Hoverable(maid, row, "Panel", "PanelHover")
	Text({
		Theme = { Font = "FontSemibold" },
		Text = name,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -120, 1, 0),
		Parent = row,
	})

	local valueBox = Create("TextButton", {
		Theme = { BackgroundColor3 = "Section", TextColor3 = "Text", Font = "Font" },
		AutoButtonColor = false,
		BorderSizePixel = 0,
		TextSize = 12,
		Text = "",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(90, 22),
		Parent = row,
	}) :: TextButton
	Corner(valueBox, 4)
	Stroke(valueBox, 0.5)

	local widget = { _type = "DragInput", _destroyed = false }

	local function render()
		valueBox.Text = FormatNumber(value, decimals)
	end

	local function set(v, silent)
		v = Snap(tonumber(v) or 0, step, min, max)
		if v == value then
			render()
			return
		end
		value = v
		render()
		if not silent then
			SafeCall(library, "DragInput '" .. name .. "' Callback", options.Callback, value)
		end
	end

	maid:Add(valueBox.InputBegan:Connect(function(input)
		if IsPress(input) then
			local startX = PointerPos(input).X
			local startValue = value
			valueBox.BackgroundColor3 = Theme.PanelActive
			BeginPointerDrag(maid, function(pos)
				set(startValue + (pos.X - startX) * perPixel)
			end, function()
				Tween(valueBox, { BackgroundColor3 = Theme.Section }, 0.12)
			end)
		end
	end))

	render()
	function widget:Set(v, silent)
		set(v, silent)
	end
	function widget:Get()
		return value
	end
	return self:_finish(widget, row, maid, options)
end

-- ─────────────────────────────── InputText ──────────────────────────────────
-- { Name, Placeholder, Default, Numeric, Finished, Callback(text|number) }
-- Numeric = true filters input to digits/./- and the callback receives a number.
-- Finished = true fires the callback only when Enter is pressed.
function Elements:CreateInput(options)
	options = options or {}
	local library = self._library
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local name = tostring(options.Name or "Input")
	local numeric = options.Numeric == true

	local row = self:_baseRow(34, false)
	Hoverable(maid, row, "Panel", "PanelHover")
	Text({
		Theme = { Font = "FontSemibold" },
		Text = name,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -200, 1, 0),
		Parent = row,
	})

	local box = Create("TextBox", {
		Theme = {
			BackgroundColor3 = "Section",
			TextColor3 = "Text",
			Font = "Font",
			PlaceholderColor3 = "DisabledText",
		},
		BorderSizePixel = 0,
		TextSize = 12,
		Text = tostring(options.Default or ""),
		PlaceholderText = tostring(options.Placeholder or ""),
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(170, 24),
		Parent = row,
	}) :: TextBox
	Corner(box, 4)
	Stroke(box, 0.5)
	Pad(box, 8, 0, 8, 0)

	local value = box.Text
	local widget = { _type = "Input", _destroyed = false }

	if numeric then
		maid:Add(box:GetPropertyChangedSignal("Text"):Connect(function()
			local filtered = box.Text:gsub("[^%d%.%-]", "")
			if filtered ~= box.Text then
				box.Text = filtered
			end
		end))
	end

	local function output()
		return if numeric then (tonumber(value) or 0) else value
	end

	maid:Add(box.FocusLost:Connect(function(enterPressed)
		value = box.Text
		if options.Finished and not enterPressed then
			return
		end
		SafeCall(library, "Input '" .. name .. "' Callback", options.Callback, output())
	end))

	function widget:Set(text, silent)
		box.Text = tostring(text)
		value = box.Text
		if not silent then
			SafeCall(library, "Input '" .. name .. "' Callback", options.Callback, output())
		end
	end
	function widget:Get()
		return output()
	end
	return self:_finish(widget, row, maid, options)
end

-- ─────────────────────────────── Dropdown / Combo box ───────────────────────
-- { Name, Items, Default, MultiSelect, Callback, Tooltip, Flag }
-- Single-select: Default/Set/Get/Callback use a string (or nil).
-- MultiSelect = true: they use an array of strings instead.
function Elements:CreateDropdown(options)
	options = options or {}
	local library = self._library
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local name = tostring(options.Name or "Dropdown")
	local multi = options.MultiSelect == true
	local items: { string } = {}
	for _, item in ipairs(options.Items or {}) do
		table.insert(items, tostring(item))
	end

	local HEADER_H = 34
	local ITEM_H = 26
	local LIST_MAX = 158

	local selectedSet: { [string]: boolean } = {}
	local selectedSingle: string? = nil
	if multi then
		if type(options.Default) == "table" then
			for _, item in ipairs(options.Default) do
				selectedSet[tostring(item)] = true
			end
		end
	elseif options.Default ~= nil then
		selectedSingle = tostring(options.Default)
	end

	local open = false

	-- The wrapper clips; opening tweens its height to reveal the inner list.
	local wrapper = Create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.new(1, 0, 0, HEADER_H),
		LayoutOrder = self:_nextOrder(),
		Parent = self._container,
	})
	local header = Create("TextButton", {
		Theme = { BackgroundColor3 = "Panel" },
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, HEADER_H),
		Parent = wrapper,
	}) :: TextButton
	Corner(header)
	Hoverable(maid, header, "Panel", "PanelHover")
	Text({
		Theme = { Font = "FontSemibold" },
		Text = name,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(0.45, -12, 1, 0),
		Parent = header,
	})
	local valueLabel = Text({
		Theme = { TextColor3 = "SubText" },
		Text = "",
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -30, 0.5, 0),
		Size = UDim2.new(0.5, -30, 1, 0),
		Parent = header,
	})
	local arrow = Text({
		Theme = { TextColor3 = "SubText" },
		Text = "›",
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Center,
		Rotation = 90,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		Parent = header,
	})

	local listFrame = Create("ScrollingFrame", {
		Theme = { BackgroundColor3 = "Section", ScrollBarImageColor3 = "Border" },
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, HEADER_H + 4),
		Size = UDim2.new(1, 0, 0, 0),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = wrapper,
	}) :: ScrollingFrame
	Corner(listFrame, 4)
	Pad(listFrame, 4, 4, 4, 4)
	VList(listFrame, 2)

	local itemButtons: { [string]: TextButton } = {}
	local widget = { _type = multi and "MultiDropdown" or "Dropdown", _destroyed = false }

	local function listHeight(): number
		return math.min(#items * (ITEM_H + 2) + 6, LIST_MAX)
	end

	local function selectionList(): { string }
		local out = {}
		for _, item in ipairs(items) do
			if selectedSet[item] then
				table.insert(out, item)
			end
		end
		return out
	end

	local function displayText(): string
		if multi then
			local list = selectionList()
			return if #list > 0 then table.concat(list, ", ") else "None"
		end
		return selectedSingle or "None"
	end

	local function isSelected(item: string): boolean
		return if multi then selectedSet[item] == true else selectedSingle == item
	end

	local function refreshVisuals()
		valueLabel.Text = displayText()
		for item, btn in pairs(itemButtons) do
			local on = isSelected(item)
			Retheme(btn, {
				BackgroundColor3 = on and "Accent" or "Section",
				TextColor3 = on and "AccentText" or "SubText",
			})
			btn.BackgroundColor3 = on and Theme.Accent or Theme.Section
			btn.TextColor3 = on and Theme.AccentText or Theme.SubText
		end
	end

	local function setOpen(state: boolean)
		open = state
		Tween(arrow, { Rotation = open and 270 or 90 }, 0.18)
		local target = if open then HEADER_H + 4 + listHeight() else HEADER_H
		listFrame.Size = UDim2.new(1, 0, 0, listHeight())
		Tween(wrapper, { Size = UDim2.new(1, 0, 0, target) }, 0.18, Enum.EasingStyle.Quint)
	end

	local function fireCallback()
		local payload = if multi then selectionList() else selectedSingle
		SafeCall(library, "Dropdown '" .. name .. "' Callback", options.Callback, payload)
	end

	local function onItemClicked(item: string)
		if multi then
			if selectedSet[item] then
				selectedSet[item] = nil
			else
				selectedSet[item] = true
			end
			refreshVisuals()
			fireCallback()
		else
			selectedSingle = item
			refreshVisuals()
			setOpen(false)
			fireCallback()
		end
	end

	local function rebuildItems()
		for _, btn in pairs(itemButtons) do
			btn:Destroy()
		end
		table.clear(itemButtons)
		for index, item in ipairs(items) do
			local btn = Create("TextButton", {
				Theme = { Font = "Font" },
				BackgroundColor3 = Theme.Section,
				TextColor3 = Theme.SubText,
				AutoButtonColor = false,
				BorderSizePixel = 0,
				TextSize = 12,
				Text = item,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, 0, 0, ITEM_H),
				LayoutOrder = index,
				Parent = listFrame,
			}) :: TextButton
			Corner(btn, 4)
			Pad(btn, 8, 0, 8, 0)
			itemButtons[item] = btn
			maid:Add(btn.MouseButton1Click:Connect(function()
				onItemClicked(item)
			end))
		end
		refreshVisuals()
		if open then
			listFrame.Size = UDim2.new(1, 0, 0, listHeight())
			wrapper.Size = UDim2.new(1, 0, 0, HEADER_H + 4 + listHeight())
		end
	end

	maid:Add(header.MouseButton1Click:Connect(function()
		setOpen(not open)
	end))

	rebuildItems()

	local function set(v, silent)
		if multi then
			table.clear(selectedSet)
			if type(v) == "table" then
				for _, item in ipairs(v) do
					selectedSet[tostring(item)] = true
				end
			end
		else
			selectedSingle = if v ~= nil then tostring(v) else nil
		end
		refreshVisuals()
		if not silent then
			fireCallback()
		end
	end

	function widget:Set(v, silent)
		set(v, silent)
	end
	function widget:Get()
		return if multi then selectionList() else selectedSingle
	end
	function widget:SetItems(newItems)
		items = {}
		for _, item in ipairs(newItems or {}) do
			table.insert(items, tostring(item))
		end
		local valid = {}
		for _, item in ipairs(items) do
			valid[item] = true
		end
		if multi then
			for item in pairs(selectedSet) do
				if not valid[item] then
					selectedSet[item] = nil
				end
			end
		elseif selectedSingle ~= nil and not valid[selectedSingle] then
			selectedSingle = nil
		end
		rebuildItems()
	end
	return self:_finish(widget, wrapper, maid, options)
end

-- ─────────────────────────────── RadioButton group ──────────────────────────
-- { Name, Options = {"A", "B", ...}, Default, Callback(choice), Tooltip, Flag }
function Elements:CreateRadioGroup(options)
	options = options or {}
	local library = self._library
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local name = tostring(options.Name or "Radio")
	local choices: { string } = {}
	for _, choice in ipairs(options.Options or {}) do
		table.insert(choices, tostring(choice))
	end
	local value: string? = if options.Default ~= nil then tostring(options.Default) else nil

	local OPTION_H = 26
	local row = self:_baseRow(34 + #choices * OPTION_H + 4, false)
	Text({
		Theme = { Font = "FontSemibold" },
		Text = name,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 0, 30),
		Parent = row,
	})

	local dots: { [string]: Frame } = {}
	local widget = { _type = "RadioGroup", _destroyed = false }

	local function refresh()
		for choice, dot in pairs(dots) do
			local on = choice == value
			Tween(dot, { Size = on and UDim2.fromOffset(8, 8) or UDim2.fromOffset(0, 0) }, 0.12)
		end
	end

	for index, choice in ipairs(choices) do
		local btn = Create("TextButton", {
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			Position = UDim2.new(0, 12, 0, 30 + (index - 1) * OPTION_H),
			Size = UDim2.new(1, -24, 0, OPTION_H),
			Parent = row,
		}) :: TextButton
		local circle = Create("Frame", {
			Theme = { BackgroundColor3 = "Section" },
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 0, 0.5, 0),
			Size = UDim2.fromOffset(16, 16),
			Parent = btn,
		})
		Corner(circle, 8)
		Stroke(circle)
		local dot = Create("Frame", {
			Theme = { BackgroundColor3 = "Accent" },
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = UDim2.fromOffset(0, 0),
			Parent = circle,
		})
		Corner(dot, 8)
		dots[choice] = dot
		Text({
			Theme = { TextColor3 = "SubText" },
			Text = choice,
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(24, 0),
			Size = UDim2.new(1, -24, 1, 0),
			Parent = btn,
		})
		maid:Add(btn.MouseButton1Click:Connect(function()
			if value ~= choice then
				value = choice
				refresh()
				SafeCall(library, "RadioGroup '" .. name .. "' Callback", options.Callback, value)
			end
		end))
	end

	if value ~= nil and dots[value] then
		dots[value].Size = UDim2.fromOffset(8, 8)
	end

	function widget:Set(v, silent)
		local coerced = if v ~= nil then tostring(v) else nil
		if coerced == value then
			return
		end
		value = coerced
		refresh()
		if not silent then
			SafeCall(library, "RadioGroup '" .. name .. "' Callback", options.Callback, value)
		end
	end
	function widget:Get()
		return value
	end
	return self:_finish(widget, row, maid, options)
end

-- ─────────────────────────────── ColorPicker (HSV + hex) ────────────────────
-- { Name, Default (Color3), Callback(color: Color3), Tooltip, Flag }
-- Collapsed row shows a swatch; expanding reveals an HSV picker (saturation/
-- value box + hue bar, built purely from gradients — no image assets) plus a
-- hex input and a live RGB readout.
function Elements:CreateColorPicker(options)
	options = options or {}
	local library = self._library
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local name = tostring(options.Name or "Color")
	local default = if typeof(options.Default) == "Color3" then options.Default else Color3.fromRGB(255, 255, 255)
	local h, s, v = default:ToHSV()
	local open = false

	local HEADER_H = 34
	local SV_H = 150
	local OPEN_H = HEADER_H + 4 + SV_H + 6 + 24 + 6

	local wrapper = Create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.new(1, 0, 0, HEADER_H),
		LayoutOrder = self:_nextOrder(),
		Parent = self._container,
	})
	local header = Create("TextButton", {
		Theme = { BackgroundColor3 = "Panel" },
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, HEADER_H),
		Parent = wrapper,
	}) :: TextButton
	Corner(header)
	Hoverable(maid, header, "Panel", "PanelHover")
	Text({
		Theme = { Font = "FontSemibold" },
		Text = name,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -80, 1, 0),
		Parent = header,
	})
	local swatch = Create("Frame", {
		BackgroundColor3 = default,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -30, 0.5, 0),
		Size = UDim2.fromOffset(28, 16),
		Parent = header,
	})
	Corner(swatch, 4)
	Stroke(swatch)
	local arrow = Text({
		Theme = { TextColor3 = "SubText" },
		Text = "›",
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Center,
		Rotation = 90,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		Parent = header,
	})

	-- Saturation/value box: base hue color + white gradient (x) + black gradient (y).
	local svBox = Create("Frame", {
		BackgroundColor3 = Color3.fromHSV(h, 1, 1),
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, HEADER_H + 4),
		Size = UDim2.new(1, -20, 0, SV_H),
		Parent = wrapper,
	})
	Corner(svBox, 4)
	local whiteOverlay = Create("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 2,
		Parent = svBox,
	})
	Corner(whiteOverlay, 4)
	Create("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = whiteOverlay,
	})
	local blackOverlay = Create("Frame", {
		BackgroundColor3 = Color3.new(0, 0, 0),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = 3,
		Parent = svBox,
	})
	Corner(blackOverlay, 4)
	Create("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Parent = blackOverlay,
	})
	local svCursor = Create("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(10, 10),
		ZIndex = 4,
		Parent = svBox,
	})
	Corner(svCursor, 5)
	Create("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2, Parent = svCursor })

	local hueBar = Create("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, HEADER_H + 4),
		Size = UDim2.new(0, 14, 0, SV_H),
		ClipsDescendants = true,
		Parent = wrapper,
	})
	Corner(hueBar, 4)
	Create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
			ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
			ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 255, 255)),
			ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
			ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 0)),
		}),
		Parent = hueBar,
	})
	local hueCursor = Create("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.new(1, 0, 0, 3),
		ZIndex = 2,
		Parent = hueBar,
	})

	local hexBox = Create("TextBox", {
		Theme = { BackgroundColor3 = "Section", TextColor3 = "Text", Font = "Font" },
		BorderSizePixel = 0,
		TextSize = 12,
		Text = "#FFFFFF",
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Center,
		Position = UDim2.new(0, 0, 0, HEADER_H + 4 + SV_H + 6),
		Size = UDim2.fromOffset(84, 22),
		Parent = wrapper,
	}) :: TextBox
	Corner(hexBox, 4)
	Stroke(hexBox, 0.5)
	local rgbLabel = Text({
		Theme = { TextColor3 = "SubText" },
		Text = "",
		TextSize = 12,
		Position = UDim2.fromOffset(92, HEADER_H + 4 + SV_H + 6),
		Size = UDim2.new(1, -92, 0, 22),
		Parent = wrapper,
	})

	local widget = { _type = "ColorPicker", _destroyed = false }

	local function currentColor(): Color3
		return Color3.fromHSV(h, s, v)
	end

	local function render(skipHex: boolean?)
		local color = currentColor()
		swatch.BackgroundColor3 = color
		svBox.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
		svCursor.Position = UDim2.new(s, 0, 1 - v, 0)
		hueCursor.Position = UDim2.new(0.5, 0, h, 0)
		local r = math.floor(color.R * 255 + 0.5)
		local g = math.floor(color.G * 255 + 0.5)
		local b = math.floor(color.B * 255 + 0.5)
		rgbLabel.Text = string.format("RGB %d, %d, %d", r, g, b)
		if not skipHex then
			hexBox.Text = string.format("#%02X%02X%02X", r, g, b)
		end
	end

	local function fireCallback()
		SafeCall(library, "ColorPicker '" .. name .. "' Callback", options.Callback, currentColor())
	end

	local function setOpen(state: boolean)
		open = state
		Tween(arrow, { Rotation = open and 270 or 90 }, 0.18)
		Tween(wrapper, { Size = UDim2.new(1, 0, 0, open and OPEN_H or HEADER_H) }, 0.18, Enum.EasingStyle.Quint)
	end

	maid:Add(header.MouseButton1Click:Connect(function()
		setOpen(not open)
	end))

	local function svFromPointer(pos: Vector2)
		s = math.clamp((pos.X - svBox.AbsolutePosition.X) / math.max(svBox.AbsoluteSize.X, 1), 0, 1)
		v = 1 - math.clamp((pos.Y - svBox.AbsolutePosition.Y) / math.max(svBox.AbsoluteSize.Y, 1), 0, 1)
		render()
		fireCallback()
	end
	local function hueFromPointer(pos: Vector2)
		h = math.clamp((pos.Y - hueBar.AbsolutePosition.Y) / math.max(hueBar.AbsoluteSize.Y, 1), 0, 1)
		render()
		fireCallback()
	end
	maid:Add(svBox.InputBegan:Connect(function(input)
		if IsPress(input) then
			svFromPointer(PointerPos(input))
			BeginPointerDrag(maid, svFromPointer)
		end
	end))
	maid:Add(hueBar.InputBegan:Connect(function(input)
		if IsPress(input) then
			hueFromPointer(PointerPos(input))
			BeginPointerDrag(maid, hueFromPointer)
		end
	end))

	maid:Add(hexBox.FocusLost:Connect(function()
		local txt = hexBox.Text:gsub("#", ""):gsub("%s", "")
		if #txt == 6 then
			local r = tonumber(txt:sub(1, 2), 16)
			local g = tonumber(txt:sub(3, 4), 16)
			local b = tonumber(txt:sub(5, 6), 16)
			if r and g and b then
				h, s, v = Color3.fromRGB(r, g, b):ToHSV()
				render()
				fireCallback()
				return
			end
		end
		render() -- invalid hex: snap the box back to the current color
	end))

	render()

	function widget:Set(color, silent)
		if typeof(color) == "Color3" then
			h, s, v = color:ToHSV()
			render()
			if not silent then
				fireCallback()
			end
		end
	end
	function widget:Get()
		return currentColor()
	end
	return self:_finish(widget, wrapper, maid, options)
end

-- ─────────────────────────────── Keybind picker ─────────────────────────────
-- { Name, Default (Enum.KeyCode | Enum.UserInputType.MouseButton2/3 | string),
--   Callback(bind)         -- fires every time the bound key is pressed
--   ChangedCallback(bind)  -- fires when the user rebinds the key
--   Tooltip, Flag }
-- Click the field, then press any key (or MB2/MB3). Escape cancels.
function Elements:CreateKeybind(options)
	options = options or {}
	local library = self._library
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local name = tostring(options.Name or "Keybind")
	local value: EnumItem? = nil
	if typeof(options.Default) == "EnumItem" then
		value = options.Default
	elseif type(options.Default) == "string" then
		local ok, key = pcall(function()
			return (Enum.KeyCode :: any)[options.Default]
		end)
		if ok then
			value = key
		end
	end
	local listening = false

	local row = self:_baseRow(34, false)
	Hoverable(maid, row, "Panel", "PanelHover")
	Text({
		Theme = { Font = "FontSemibold" },
		Text = name,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -120, 1, 0),
		Parent = row,
	})

	local bindBtn = Create("TextButton", {
		Theme = { BackgroundColor3 = "Section", TextColor3 = "SubText", Font = "Font" },
		AutoButtonColor = false,
		BorderSizePixel = 0,
		TextSize = 12,
		Text = "",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(90, 22),
		Parent = row,
	}) :: TextButton
	Corner(bindBtn, 4)
	Stroke(bindBtn, 0.5)

	local widget = { _type = "Keybind", _destroyed = false }

	local function render()
		if listening then
			bindBtn.Text = "..."
		else
			bindBtn.Text = if value ~= nil then value.Name else "None"
		end
	end

	-- Capture mode: the next key press becomes the bind.
	maid:Add(bindBtn.MouseButton1Click:Connect(function()
		if listening then
			return
		end
		listening = true
		render()
		local captureConn
		captureConn = UserInputService.InputBegan:Connect(function(input)
			local newValue: EnumItem? = nil
			if input.UserInputType == Enum.UserInputType.Keyboard then
				if input.KeyCode ~= Enum.KeyCode.Escape then
					newValue = input.KeyCode
				end
				-- Escape falls through with nil => cancel, keep the old bind
			elseif input.UserInputType == Enum.UserInputType.MouseButton2
				or input.UserInputType == Enum.UserInputType.MouseButton3 then
				newValue = input.UserInputType
			else
				return -- ignore MB1 / movement / touch, keep listening
			end
			captureConn:Disconnect()
			listening = false
			if newValue ~= nil then
				value = newValue
				SafeCall(library, "Keybind '" .. name .. "' ChangedCallback", options.ChangedCallback, value)
			end
			render()
		end)
		maid:Add(captureConn)
	end))

	-- Press detection for the bound key (skipped while rebinding / gameProcessed).
	maid:Add(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if listening or gameProcessed or value == nil then
			return
		end
		local pressed = (input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == value)
			or input.UserInputType == value
		if pressed then
			SafeCall(library, "Keybind '" .. name .. "' Callback", options.Callback, value)
		end
	end))

	render()

	function widget:Set(v, silent)
		if type(v) == "string" then
			local ok, key = pcall(function()
				return (Enum.KeyCode :: any)[v]
			end)
			v = if ok then key else nil
		end
		if v ~= nil and typeof(v) ~= "EnumItem" then
			return
		end
		value = v
		render()
		if not silent then
			SafeCall(library, "Keybind '" .. name .. "' ChangedCallback", options.ChangedCallback, value)
		end
	end
	function widget:Get()
		return value
	end
	return self:_finish(widget, row, maid, options)
end

-- ─────────────────────────────── ListBox ────────────────────────────────────
-- { Name, Items, Default, MultiSelect, Height, Callback, Tooltip, Flag }
-- A permanently-visible scrollable list with selectable entries.
function Elements:CreateListBox(options)
	options = options or {}
	local library = self._library
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local name = tostring(options.Name or "List")
	local multi = options.MultiSelect == true
	local listHeight = options.Height or 120
	local ITEM_H = 24
	local items: { string } = {}
	for _, item in ipairs(options.Items or {}) do
		table.insert(items, tostring(item))
	end

	local selectedSet: { [string]: boolean } = {}
	local selectedSingle: string? = nil
	if multi then
		if type(options.Default) == "table" then
			for _, item in ipairs(options.Default) do
				selectedSet[tostring(item)] = true
			end
		end
	elseif options.Default ~= nil then
		selectedSingle = tostring(options.Default)
	end

	local row = self:_baseRow(30 + listHeight + 8, false)
	Text({
		Theme = { Font = "FontSemibold" },
		Text = name,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 0, 28),
		Parent = row,
	})
	local listFrame = Create("ScrollingFrame", {
		Theme = { BackgroundColor3 = "Section", ScrollBarImageColor3 = "Border" },
		BorderSizePixel = 0,
		Position = UDim2.new(0, 8, 0, 28),
		Size = UDim2.new(1, -16, 0, listHeight),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = row,
	}) :: ScrollingFrame
	Corner(listFrame, 4)
	Pad(listFrame, 4, 4, 4, 4)
	VList(listFrame, 2)

	local itemButtons: { [string]: TextButton } = {}
	local widget = { _type = multi and "MultiListBox" or "ListBox", _destroyed = false }

	local function selectionList(): { string }
		local out = {}
		for _, item in ipairs(items) do
			if selectedSet[item] then
				table.insert(out, item)
			end
		end
		return out
	end

	local function isSelected(item: string): boolean
		return if multi then selectedSet[item] == true else selectedSingle == item
	end

	local function refreshVisuals()
		for item, btn in pairs(itemButtons) do
			local on = isSelected(item)
			Retheme(btn, {
				BackgroundColor3 = on and "Accent" or "Section",
				TextColor3 = on and "AccentText" or "SubText",
			})
			btn.BackgroundColor3 = on and Theme.Accent or Theme.Section
			btn.TextColor3 = on and Theme.AccentText or Theme.SubText
		end
	end

	local function fireCallback()
		local payload = if multi then selectionList() else selectedSingle
		SafeCall(library, "ListBox '" .. name .. "' Callback", options.Callback, payload)
	end

	local function rebuildItems()
		for _, btn in pairs(itemButtons) do
			btn:Destroy()
		end
		table.clear(itemButtons)
		for index, item in ipairs(items) do
			local btn = Create("TextButton", {
				Theme = { Font = "Font" },
				BackgroundColor3 = Theme.Section,
				TextColor3 = Theme.SubText,
				AutoButtonColor = false,
				BorderSizePixel = 0,
				TextSize = 12,
				Text = item,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, 0, 0, ITEM_H),
				LayoutOrder = index,
				Parent = listFrame,
			}) :: TextButton
			Corner(btn, 4)
			Pad(btn, 8, 0, 8, 0)
			itemButtons[item] = btn
			maid:Add(btn.MouseButton1Click:Connect(function()
				if multi then
					if selectedSet[item] then
						selectedSet[item] = nil
					else
						selectedSet[item] = true
					end
				else
					selectedSingle = item
				end
				refreshVisuals()
				fireCallback()
			end))
		end
		refreshVisuals()
	end

	rebuildItems()

	function widget:Set(v, silent)
		if multi then
			table.clear(selectedSet)
			if type(v) == "table" then
				for _, item in ipairs(v) do
					selectedSet[tostring(item)] = true
				end
			end
		else
			selectedSingle = if v ~= nil then tostring(v) else nil
		end
		refreshVisuals()
		if not silent then
			fireCallback()
		end
	end
	function widget:Get()
		return if multi then selectionList() else selectedSingle
	end
	function widget:SetItems(newItems)
		items = {}
		for _, item in ipairs(newItems or {}) do
			table.insert(items, tostring(item))
		end
		local valid = {}
		for _, item in ipairs(items) do
			valid[item] = true
		end
		if multi then
			for item in pairs(selectedSet) do
				if not valid[item] then
					selectedSet[item] = nil
				end
			end
		elseif selectedSingle ~= nil and not valid[selectedSingle] then
			selectedSingle = nil
		end
		rebuildItems()
	end
	return self:_finish(widget, row, maid, options)
end

-- ─────────────────────────────── Table ──────────────────────────────────────
-- { Columns = {"Name", "Value"}, Rows = {{"a", "1"}, ...}, Tooltip }
-- Simple multi-column row layout. :Set(rows) / :AddRow(row) / :Clear() / :Get()
function Elements:CreateTable(options)
	options = options or {}
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local columns: { string } = {}
	for _, col in ipairs(options.Columns or {}) do
		table.insert(columns, tostring(col))
	end
	if #columns == 0 then
		columns = { "Column" }
	end
	local rows: { { any } } = options.Rows or {}

	local ROW_H = 24
	local holder = self:_baseRow(0, false) -- height set by relayout()
	Pad(holder, 8, 6, 8, 6)

	-- Header line
	local headerRow = Create("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, ROW_H),
		Parent = holder,
	})
	local colWidth = 1 / #columns
	for index, col in ipairs(columns) do
		Text({
			Theme = { TextColor3 = "SubText", Font = "FontBold" },
			Text = col,
			TextSize = 12,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.new(colWidth * (index - 1), 4, 0, 0),
			Size = UDim2.new(colWidth, -8, 1, 0),
			Parent = headerRow,
		})
	end
	local divider = Create("Frame", {
		Theme = { BackgroundColor3 = "Border" },
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, ROW_H + 2),
		Size = UDim2.new(1, 0, 0, 1),
		Parent = holder,
	})

	local rowFrames: { Frame } = {}
	local widget = { _type = "Table", _destroyed = false }

	local function relayout()
		holder.Size = UDim2.new(1, 0, 0, 6 + ROW_H + 4 + #rows * ROW_H + 6)
	end

	local function buildRow(index: number, rowData: { any })
		local rowFrame = Create("Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 0, 0, ROW_H + 4 + (index - 1) * ROW_H),
			Size = UDim2.new(1, 0, 0, ROW_H),
			Parent = holder,
		}) :: Frame
		for colIndex = 1, #columns do
			Text({
				Theme = { TextColor3 = "Text" },
				Text = tostring(rowData[colIndex] ~= nil and rowData[colIndex] or ""),
				TextSize = 12,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Position = UDim2.new(colWidth * (colIndex - 1), 4, 0, 0),
				Size = UDim2.new(colWidth, -8, 1, 0),
				Parent = rowFrame,
			})
		end
		table.insert(rowFrames, rowFrame)
	end

	local function rebuild()
		for _, frame in ipairs(rowFrames) do
			frame:Destroy()
		end
		table.clear(rowFrames)
		for index, rowData in ipairs(rows) do
			buildRow(index, rowData)
		end
		relayout()
	end

	rebuild()

	function widget:Set(newRows)
		rows = newRows or {}
		rebuild()
	end
	widget.SetRows = widget.Set
	function widget:AddRow(rowData)
		table.insert(rows, rowData)
		buildRow(#rows, rowData)
		relayout()
	end
	function widget:Clear()
		rows = {}
		rebuild()
	end
	function widget:Get()
		return rows
	end
	return self:_finish(widget, holder, maid, options)
end

-- ─────────────────────────────── ProgressBar ────────────────────────────────
-- { Name, Default (0..1), Tooltip, Flag } — :Set(fraction) animates the fill.
function Elements:CreateProgressBar(options)
	options = options or {}
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local name = tostring(options.Name or "Progress")
	local value = math.clamp(tonumber(options.Default) or 0, 0, 1)

	local row = self:_baseRow(42, false)
	Text({
		Theme = { Font = "FontSemibold" },
		Text = name,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -80, 0, 16),
		Parent = row,
	})
	local percentLabel = Text({
		Theme = { TextColor3 = "SubText" },
		Text = "",
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 6),
		Size = UDim2.fromOffset(60, 16),
		Parent = row,
	})
	local bar = Create("Frame", {
		Theme = { BackgroundColor3 = "PanelActive" },
		BorderSizePixel = 0,
		Position = UDim2.new(0, 12, 1, -14),
		Size = UDim2.new(1, -24, 0, 6),
		Parent = row,
	})
	Corner(bar, 3)
	local fill = Create("Frame", {
		Theme = { BackgroundColor3 = "Accent" },
		BorderSizePixel = 0,
		Size = UDim2.new(value, 0, 1, 0),
		Parent = bar,
	})
	Corner(fill, 3)

	local widget = { _type = "ProgressBar", _destroyed = false }

	local function render(instant: boolean?)
		percentLabel.Text = string.format("%d%%", math.floor(value * 100 + 0.5))
		if instant then
			fill.Size = UDim2.new(value, 0, 1, 0)
		else
			Tween(fill, { Size = UDim2.new(value, 0, 1, 0) }, 0.2)
		end
	end

	render(true)

	function widget:Set(fraction)
		value = math.clamp(tonumber(fraction) or 0, 0, 1)
		render(false)
	end
	function widget:Get()
		return value
	end
	return self:_finish(widget, row, maid, options)
end

-- ─────────────────────────────── Label / Separator ──────────────────────────
-- CreateLabel({ Text, SubText? }) — plain wrapped text; :Set(text) to update.
function Elements:CreateLabel(options)
	if type(options) == "string" then
		options = { Text = options }
	end
	options = options or {}
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local label = Text({
		Theme = { TextColor3 = if options.SubText then "SubText" else "Text" },
		Text = tostring(options.Text or "Label"),
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = self:_nextOrder(),
		Parent = self._container,
	})
	Pad(label, 4, 2, 4, 2)

	local widget = { _type = "Label", _destroyed = false }
	function widget:Set(text)
		label.Text = tostring(text)
	end
	function widget:Get()
		return label.Text
	end
	return self:_finish(widget, label, maid, options)
end

-- CreateSeparator({ Text? }) — thin divider line, optionally with centered text.
function Elements:CreateSeparator(options)
	if type(options) == "string" then
		options = { Text = options }
	end
	options = options or {}
	local maid = Maid.new()
	self._window._maid:Add(maid)

	local holder = Create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 14),
		LayoutOrder = self:_nextOrder(),
		Parent = self._container,
	})
	Create("Frame", {
		Theme = { BackgroundColor3 = "Border" },
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 4, 0.5, 0),
		Size = UDim2.new(1, -8, 0, 1),
		Parent = holder,
	})
	local textLabel: TextLabel? = nil
	if options.Text then
		textLabel = Text({
			Theme = { TextColor3 = "SubText", BackgroundColor3 = "WindowBackground" },
			BackgroundTransparency = 0,
			Text = " " .. tostring(options.Text) .. " ",
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Center,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = UDim2.fromOffset(0, 14),
			AutomaticSize = Enum.AutomaticSize.X,
			ZIndex = 2,
			Parent = holder,
		})
	end

	local widget = { _type = "Separator", _destroyed = false }
	function widget:Set(text)
		if textLabel then
			textLabel.Text = " " .. tostring(text) .. " "
		end
	end
	function widget:Get()
		return if textLabel then textLabel.Text else ""
	end
	return self:_finish(widget, holder, maid, options)
end

-- ─────────────────────────────── Section (CollapsingHeader / TreeNode) ──────
-- { Name, Open (default true), Tooltip }
-- Returns a full element container: every Create* method works inside it, and
-- sections can nest inside sections (TreeNode-style).
function Elements:CreateSection(options)
	if type(options) == "string" then
		options = { Name = options }
	end
	options = options or {}
	local library = self._library
	local window = self._window
	local maid = Maid.new()
	window._maid:Add(maid)

	local name = tostring(options.Name or "Section")
	local open = options.Open ~= false
	local HEADER_H = 30

	local wrapper = Create("Frame", {
		Theme = { BackgroundColor3 = "Section" },
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.new(1, 0, 0, HEADER_H),
		LayoutOrder = self:_nextOrder(),
		Parent = self._container,
	})
	Corner(wrapper)
	Stroke(wrapper, 0.6)

	local header = Create("TextButton", {
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.new(1, 0, 0, HEADER_H),
		Parent = wrapper,
	}) :: TextButton
	local arrow = Text({
		Theme = { TextColor3 = "SubText" },
		Text = "›",
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Center,
		Rotation = if open then 90 else 0,
		Position = UDim2.new(0, 8, 0.5, -7),
		Size = UDim2.fromOffset(14, 14),
		Parent = header,
	})
	Text({
		Theme = { Font = "FontBold" },
		Text = name,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(28, 0),
		Size = UDim2.new(1, -40, 1, 0),
		Parent = header,
	})

	local holder = Create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, HEADER_H),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = wrapper,
	})
	Pad(holder, 8, 0, 8, 8)
	local layout = VList(holder, 6)

	local function contentHeight(): number
		return layout.AbsoluteContentSize.Y + 8 -- + bottom padding
	end

	local function applySize(instant: boolean)
		local target = if open then HEADER_H + contentHeight() else HEADER_H
		if instant then
			wrapper.Size = UDim2.new(1, 0, 0, target)
		else
			Tween(wrapper, { Size = UDim2.new(1, 0, 0, target) }, 0.18, Enum.EasingStyle.Quint)
		end
	end

	-- Children growing/shrinking (e.g. a nested dropdown opening) resize us live.
	maid:Add(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		if open then
			wrapper.Size = UDim2.new(1, 0, 0, HEADER_H + contentHeight())
		end
	end))

	local section = NewElementContainer(library, window, holder)
	section._type = "Section"
	section._destroyed = false

	function section:SetOpen(state: boolean, instant: boolean?)
		open = state == true
		Tween(arrow, { Rotation = open and 90 or 0 }, 0.18)
		applySize(instant == true)
	end
	function section:Set(state: boolean)
		section:SetOpen(state)
	end
	function section:Get()
		return open
	end

	maid:Add(header.MouseButton1Click:Connect(function()
		section:SetOpen(not open)
	end))

	applySize(true)

	-- _finish would clobber Set/Get with nothing useful; wire the tail manually.
	section.Instance = wrapper
	if options.Tooltip then
		AttachTooltip(library, header, tostring(options.Tooltip), maid)
	end
	section.Destroy = StandardDestroy(library, section, maid, wrapper, nil)
	return section
end

-- ═══════════════════════════════════ Window ════════════════════════════════
-- Library:CreateWindow({
--     Title, Icon (rbxassetid://...), Size (UDim2 offsets or Vector2),
--     ToggleKey (Enum.KeyCode, default RightShift — shows/hides the window),
--     CloseAction ("Hide" | "Destroy", default "Hide"),
-- })
function Library:CreateWindow(options)
	options = options or {}
	assert(not self._unloaded, "GraphiteUI: library has been unloaded")
	self:_ensureGui()
	local library = self

	local window = {}
	local maid = Maid.new()
	window._maid = maid
	window.Library = library
	self._maid:Add(maid)
	table.insert(self.Windows, window)

	local title = tostring(options.Title or "Window")
	local minWidth, minHeight = 440, 280
	local width, height = 560, 420
	if typeof(options.Size) == "UDim2" then
		width = math.max(minWidth, options.Size.X.Offset)
		height = math.max(minHeight, options.Size.Y.Offset)
	elseif typeof(options.Size) == "Vector2" then
		width = math.max(minWidth, options.Size.X)
		height = math.max(minHeight, options.Size.Y)
	end

	local screen = self._gui.AbsoluteSize
	if screen.X <= 0 then
		local camera = workspace.CurrentCamera
		screen = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	end
	local stagger = (#self.Windows - 1) * 30

	local root = Create("Frame", {
		Theme = { BackgroundColor3 = "WindowBackground" },
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(
			math.max(0, math.floor((screen.X - width) / 2) + stagger),
			math.max(0, math.floor((screen.Y - height) / 2) + stagger)
		),
		Size = UDim2.fromOffset(width, height),
		ClipsDescendants = true,
		Parent = self._gui,
	}) :: Frame
	Corner(root, 8)
	Stroke(root)
	local scale = Create("UIScale", { Parent = root }) :: UIScale
	maid:Add(root) -- destroying the root takes the whole window tree with it

	-- ── Title bar ──
	local TITLE_H = 36
	local titleBar = Create("Frame", {
		Theme = { BackgroundColor3 = "TitleBar" },
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, TITLE_H),
		Parent = root,
	})
	Corner(titleBar, 8)
	-- square off the bottom edge of the rounded title bar
	Create("Frame", {
		Theme = { BackgroundColor3 = "TitleBar" },
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, -8),
		Size = UDim2.new(1, 0, 0, 8),
		Parent = titleBar,
	})

	local titleX = 12
	if options.Icon then
		Create("ImageLabel", {
			BackgroundTransparency = 1,
			Image = tostring(options.Icon),
			Position = UDim2.new(0, 10, 0.5, -9),
			Size = UDim2.fromOffset(18, 18),
			ZIndex = 2,
			Parent = titleBar,
		})
		titleX = 34
	end
	local titleLabel = Text({
		Theme = { Font = "FontBold" },
		Text = title,
		TextSize = 14,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(titleX, 0),
		Size = UDim2.new(1, -(titleX + 64), 1, 0),
		ZIndex = 2,
		Parent = titleBar,
	})

	local function titleButton(buttonText: string, xOffset: number): TextButton
		local btn = Create("TextButton", {
			Theme = { TextColor3 = "SubText", Font = "FontBold" },
			BackgroundColor3 = Theme.PanelActive,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			BorderSizePixel = 0,
			TextSize = 14,
			Text = buttonText,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, xOffset, 0.5, 0),
			Size = UDim2.fromOffset(24, 24),
			ZIndex = 2,
			Parent = titleBar,
		}) :: TextButton
		Corner(btn, 4)
		maid:Add(btn.MouseEnter:Connect(function()
			btn.BackgroundTransparency = 0.85
			btn.TextColor3 = Theme.Text
		end))
		maid:Add(btn.MouseLeave:Connect(function()
			btn.BackgroundTransparency = 1
			btn.TextColor3 = Theme.SubText
		end))
		return btn
	end
	local closeBtn = titleButton("×", -8)
	local minBtn = titleButton("–", -34)

	-- ── Menu bar (hidden until the first CreateMenu call) ──
	local MENU_H = 26
	local menuBarVisible = false
	local menuBar = Create("Frame", {
		Theme = { BackgroundColor3 = "TitleBar" },
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, TITLE_H),
		Size = UDim2.new(1, 0, 0, 0),
		Visible = false,
		Parent = root,
	})
	Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 2),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = menuBar,
	})
	Pad(menuBar, 6, 0, 6, 0)

	-- ── Body: sidebar tab list + content area ──
	local body = Create("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0, TITLE_H),
		Size = UDim2.new(1, 0, 1, -TITLE_H),
		Parent = root,
	})
	local function relayoutBody()
		local topOffset = TITLE_H + (if menuBarVisible then MENU_H else 0)
		body.Position = UDim2.new(0, 0, 0, topOffset)
		body.Size = UDim2.new(1, 0, 1, -topOffset)
	end

	local SIDEBAR_W = 140
	local sidebar = Create("Frame", {
		Theme = { BackgroundColor3 = "Sidebar" },
		BorderSizePixel = 0,
		Size = UDim2.new(0, SIDEBAR_W, 1, 0),
		Parent = body,
	})
	Pad(sidebar, 8, 8, 8, 8)
	VList(sidebar, 4)

	local contentArea = Create("Frame", {
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Position = UDim2.new(0, SIDEBAR_W, 0, 0),
		Size = UDim2.new(1, -SIDEBAR_W, 1, 0),
		Parent = body,
	})

	-- ── Dragging (by title bar) ──
	maid:Add(titleBar.InputBegan:Connect(function(input)
		if IsPress(input) then
			local startPointer = PointerPos(input)
			local startPos = root.Position
			BeginPointerDrag(maid, function(pos)
				local delta = pos - startPointer
				root.Position = UDim2.new(
					startPos.X.Scale, startPos.X.Offset + delta.X,
					startPos.Y.Scale, startPos.Y.Offset + delta.Y
				)
			end)
		end
	end))

	-- ── Bring-to-front on click ──
	maid:Add(root.InputBegan:Connect(function(input)
		if IsPress(input) then
			library._topZ = math.min(library._topZ + 1, 150)
			root.ZIndex = library._topZ
		end
	end))

	-- ── Resize (bottom-right grip) ──
	window._minimized = false
	local grip = Create("TextButton", {
		Theme = { TextColor3 = "SubText", Font = "Font" },
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		TextSize = 10,
		Text = "◢",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -3, 1, -3),
		Size = UDim2.fromOffset(16, 16),
		ZIndex = 5,
		Parent = root,
	}) :: TextButton
	maid:Add(grip.InputBegan:Connect(function(input)
		if IsPress(input) and not window._minimized then
			local startPointer = PointerPos(input)
			local startW, startH = width, height
			BeginPointerDrag(maid, function(pos)
				local delta = pos - startPointer
				width = math.max(minWidth, math.floor(startW + delta.X))
				height = math.max(minHeight, math.floor(startH + delta.Y))
				root.Size = UDim2.fromOffset(width, height)
			end)
		end
	end))

	-- ── Minimize / close / show-hide ──
	local function setMinimized(state: boolean)
		window._minimized = state
		grip.Visible = not state
		local target = if state then UDim2.fromOffset(width, TITLE_H) else UDim2.fromOffset(width, height)
		Tween(root, { Size = target }, 0.2, Enum.EasingStyle.Quint)
	end
	maid:Add(minBtn.MouseButton1Click:Connect(function()
		setMinimized(not window._minimized)
	end))
	function window:SetMinimized(state: boolean)
		setMinimized(state == true)
	end

	window._visible = true
	function window:SetVisible(visible: boolean)
		window._visible = visible == true
		if window._visible then
			root.Visible = true
			scale.Scale = 0.92
			Tween(scale, { Scale = 1 }, 0.18, Enum.EasingStyle.Back)
		else
			local out = Tween(scale, { Scale = 0.92 }, 0.12)
			out.Completed:Once(function()
				if not window._visible then
					root.Visible = false
				end
			end)
		end
	end
	function window:Toggle()
		window:SetVisible(not window._visible)
	end

	local toggleKey = options.ToggleKey or Enum.KeyCode.RightShift
	-- Deliberately NOT gated on gameProcessedEvent: core scripts (e.g. Shift
	-- Lock, which binds RightShift) sink keys through ContextActionService,
	-- which marks them processed and would swallow the toggle. Only typing in
	-- a TextBox suppresses it.
	maid:Add(UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == toggleKey and UserInputService:GetFocusedTextBox() == nil then
			window:Toggle()
		end
	end))

	maid:Add(closeBtn.MouseButton1Click:Connect(function()
		if options.CloseAction == "Destroy" then
			window:Destroy()
		else
			window:SetVisible(false) -- ToggleKey brings it back
		end
	end))

	-- ── Tabs ──
	window._tabs = {}
	local selectedTab = nil

	function window:_selectTab(tab)
		if selectedTab == tab then
			return
		end
		selectedTab = tab
		for _, other in ipairs(window._tabs) do
			local active = other == tab
			Retheme(other._button, {
				BackgroundColor3 = active and "PanelActive" or "Sidebar",
				TextColor3 = active and "Text" or "SubText",
				Font = "FontSemibold",
			})
			Tween(other._button, {
				BackgroundColor3 = active and Theme.PanelActive or Theme.Sidebar,
				TextColor3 = active and Theme.Text or Theme.SubText,
			}, 0.15)
			Tween(other._indicator, {
				Size = active and UDim2.new(0, 3, 1, -12) or UDim2.new(0, 3, 0, 0),
			}, 0.18)
			if active then
				other._page.Visible = true
				other._page.Position = UDim2.fromOffset(0, 10)
				Tween(other._page, { Position = UDim2.fromOffset(0, 0) }, 0.2, Enum.EasingStyle.Quint)
			else
				other._page.Visible = false
			end
		end
	end

	-- Window:CreateTab("Name") or Window:CreateTab({ Name = "Name" })
	function window:CreateTab(nameOrOptions)
		local topts = if type(nameOrOptions) == "table" then nameOrOptions else { Name = nameOrOptions }
		local tabName = tostring(topts.Name or "Tab")

		local btn = Create("TextButton", {
			Theme = { Font = "FontSemibold" },
			BackgroundColor3 = Theme.Sidebar,
			TextColor3 = Theme.SubText,
			AutoButtonColor = false,
			BorderSizePixel = 0,
			TextSize = 13,
			Text = tabName,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, 0, 0, 30),
			LayoutOrder = #window._tabs + 1,
			Parent = sidebar,
		}) :: TextButton
		Corner(btn, 5)
		Pad(btn, 12, 0, 8, 0)
		local indicator = Create("Frame", {
			Theme = { BackgroundColor3 = "Accent" },
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, -8, 0.5, 0),
			Size = UDim2.new(0, 3, 0, 0),
			Parent = btn,
		})
		Corner(indicator, 2)

		local page = Create("ScrollingFrame", {
			Theme = { ScrollBarImageColor3 = "Border" },
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 1, 0),
			CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollBarThickness = 3,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			Visible = false,
			Parent = contentArea,
		}) :: ScrollingFrame
		Pad(page, 10, 10, 10, 10)
		VList(page, 6)

		local tab = NewElementContainer(library, window, page)
		tab.Name = tabName
		tab._button = btn
		tab._page = page
		tab._indicator = indicator
		function tab:Select()
			window:_selectTab(tab)
		end

		maid:Add(btn.MouseButton1Click:Connect(function()
			window:_selectTab(tab)
		end))
		maid:Add(btn.MouseEnter:Connect(function()
			if selectedTab ~= tab then
				Tween(btn, { BackgroundColor3 = Theme.PanelHover }, 0.12)
			end
		end))
		maid:Add(btn.MouseLeave:Connect(function()
			if selectedTab ~= tab then
				Tween(btn, { BackgroundColor3 = Theme.Sidebar }, 0.12)
			end
		end))

		table.insert(window._tabs, tab)
		if #window._tabs == 1 then
			window:_selectTab(tab)
		end
		return tab
	end

	-- ── Menu bar: Window:CreateMenu("File") -> menu:AddItem / menu:AddSeparator ──
	function window:CreateMenu(menuName)
		menuName = tostring(menuName or "Menu")
		if not menuBarVisible then
			menuBarVisible = true
			menuBar.Visible = true
			menuBar.Size = UDim2.new(1, 0, 0, MENU_H)
			relayoutBody()
		end

		local btn = Create("TextButton", {
			Theme = { Font = "FontSemibold" },
			BackgroundColor3 = Theme.TitleBar,
			TextColor3 = Theme.SubText,
			AutoButtonColor = false,
			BorderSizePixel = 0,
			TextSize = 12,
			Text = menuName,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 1, -6),
			Parent = menuBar,
		}) :: TextButton
		Corner(btn, 4)
		Pad(btn, 10, 0, 10, 0)
		maid:Add(btn.MouseEnter:Connect(function()
			Tween(btn, { BackgroundColor3 = Theme.PanelHover }, 0.12)
		end))
		maid:Add(btn.MouseLeave:Connect(function()
			Tween(btn, { BackgroundColor3 = Theme.TitleBar }, 0.12)
		end))

		-- Popup lives at the ScreenGui root so it can't be clipped by the window.
		local popup = Create("Frame", {
			Theme = { BackgroundColor3 = "Panel" },
			BorderSizePixel = 0,
			Visible = false,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.fromOffset(180, 0),
			ZIndex = 300,
			Parent = library._gui,
		})
		Corner(popup)
		Stroke(popup)
		Pad(popup, 4, 4, 4, 4)
		VList(popup, 2)
		maid:Add(popup)

		local menuOpen = false
		local function closePopup()
			menuOpen = false
			popup.Visible = false
			btn.TextColor3 = Theme.SubText
		end
		local function openPopup()
			-- AbsolutePosition-space -> ScreenGui local space
			local origin = library._gui.AbsolutePosition
			popup.Position = UDim2.fromOffset(
				btn.AbsolutePosition.X - origin.X,
				btn.AbsolutePosition.Y + btn.AbsoluteSize.Y + 4 - origin.Y
			)
			popup.Visible = true
			btn.TextColor3 = Theme.Text
			menuOpen = true
			library:_setPopup(popup, btn, closePopup)
		end
		maid:Add(btn.MouseButton1Click:Connect(function()
			if menuOpen then
				library:_closePopup()
			else
				openPopup()
			end
		end))

		local menu = { Instance = btn }
		local itemOrder = 0

		-- menu:AddItem({ Name, Callback }) or menu:AddItem("Name")
		function menu:AddItem(itemOptions)
			if type(itemOptions) == "string" then
				itemOptions = { Name = itemOptions }
			end
			itemOptions = itemOptions or {}
			itemOrder += 1
			local itemName = tostring(itemOptions.Name or "Item")
			local item = Create("TextButton", {
				Theme = { Font = "Font" },
				BackgroundColor3 = Theme.Panel,
				TextColor3 = Theme.Text,
				AutoButtonColor = false,
				BorderSizePixel = 0,
				TextSize = 12,
				Text = itemName,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, 0, 0, 26),
				LayoutOrder = itemOrder,
				ZIndex = 301,
				Parent = popup,
			}) :: TextButton
			Corner(item, 4)
			Pad(item, 8, 0, 8, 0)
			Hoverable(maid, item, "Panel", "PanelActive")
			maid:Add(item.MouseButton1Click:Connect(function()
				library:_closePopup()
				SafeCall(library, "MenuItem '" .. itemName .. "' Callback", itemOptions.Callback)
			end))
			return item
		end

		function menu:AddSeparator()
			itemOrder += 1
			return Create("Frame", {
				Theme = { BackgroundColor3 = "Border" },
				BorderSizePixel = 0,
				Size = UDim2.new(1, -8, 0, 1),
				LayoutOrder = itemOrder,
				ZIndex = 301,
				Parent = popup,
			})
		end

		return menu
	end

	-- ── Modal dialog ──
	-- window:Dialog({ Title, Content, Buttons = { { Text = "OK", Callback = fn }, ... } })
	-- Blocks interaction with the window beneath until a button is pressed.
	function window:Dialog(dialogOptions)
		dialogOptions = dialogOptions or {}
		local overlay = Create("TextButton", {
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 1, 0),
			ZIndex = 50,
			Active = true,
			Parent = root,
		}) :: TextButton
		Tween(overlay, { BackgroundTransparency = 0.45 }, 0.18)

		local box = Create("Frame", {
			Theme = { BackgroundColor3 = "Panel" },
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = UDim2.new(0, 300, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			ZIndex = 51,
			Parent = overlay,
		})
		Corner(box)
		Stroke(box)
		Pad(box, 14, 12, 14, 12)
		VList(box, 10)
		local boxScale = Create("UIScale", { Scale = 0.9, Parent = box }) :: UIScale
		Tween(boxScale, { Scale = 1 }, 0.18, Enum.EasingStyle.Back)

		Text({
			Theme = { Font = "FontBold" },
			Text = tostring(dialogOptions.Title or "Dialog"),
			TextSize = 14,
			Size = UDim2.new(1, 0, 0, 18),
			LayoutOrder = 1,
			ZIndex = 52,
			Parent = box,
		})
		Text({
			Theme = { TextColor3 = "SubText" },
			Text = tostring(dialogOptions.Content or ""),
			TextWrapped = true,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 2,
			ZIndex = 52,
			Parent = box,
		})
		local buttonRow = Create("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 28),
			LayoutOrder = 3,
			ZIndex = 52,
			Parent = box,
		})
		Create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = buttonRow,
		})

		local dialog = { Instance = overlay }
		local closed = false
		function dialog:Close()
			if closed then
				return
			end
			closed = true
			Tween(boxScale, { Scale = 0.9 }, 0.12)
			local fade = Tween(overlay, { BackgroundTransparency = 1 }, 0.14)
			fade.Completed:Once(function()
				overlay:Destroy()
			end)
		end

		local buttons = dialogOptions.Buttons or { { Text = "OK" } }
		for index, buttonOptions in ipairs(buttons) do
			local btnText = tostring(buttonOptions.Text or buttonOptions.Name or "OK")
			local btn = Create("TextButton", {
				Theme = { Font = "FontSemibold" },
				BackgroundColor3 = if index == 1 then Theme.Accent else Theme.PanelActive,
				TextColor3 = if index == 1 then Theme.AccentText else Theme.Text,
				AutoButtonColor = false,
				BorderSizePixel = 0,
				TextSize = 12,
				Text = btnText,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.new(0, 0, 1, 0),
				LayoutOrder = index,
				ZIndex = 53,
				Parent = buttonRow,
			}) :: TextButton
			Corner(btn, 5)
			Pad(btn, 14, 0, 14, 0)
			maid:Add(btn.MouseButton1Click:Connect(function()
				dialog:Close()
				SafeCall(library, "Dialog button '" .. btnText .. "' Callback", buttonOptions.Callback)
			end))
		end

		maid:Add(overlay)
		return dialog
	end

	-- ── Misc window API ──
	function window:SetTitle(newTitle)
		title = tostring(newTitle)
		titleLabel.Text = title
	end
	function window:Notify(notifyOptions)
		return library:Notify(notifyOptions)
	end

	window._destroyed = false
	function window:Destroy()
		if window._destroyed then
			return
		end
		window._destroyed = true
		library:_closePopup()
		maid:Clean() -- disconnects everything, cancels loop threads, destroys root
		local index = table.find(library.Windows, window)
		if index then
			table.remove(library.Windows, index)
		end
	end

	window:SetVisible(true) -- opening pop
	return window
end

-- ═══════════════════════════════════ Config persistence ════════════════════
-- Widgets created with a `Flag = "unique_id"` option register themselves in
-- Library.Flags. SaveConfig() snapshots every flagged widget's value into a
-- plain JSON-safe table; LoadConfig(tbl) pushes values back (firing callbacks
-- so the restored state actually takes effect). Persist the table however you
-- like (e.g. writefile/readfile + HttpService:JSONEncode in an exploit env,
-- or DataStores in a real game).

function Library:SaveConfig(): { [string]: any }
	local out = {}
	for flag, widget in pairs(self.Flags) do
		local ok, value = pcall(widget.Get, widget)
		if ok then
			local kind = typeof(value)
			if kind == "Color3" then
				out[flag] = { __type = "Color3", value.R, value.G, value.B }
			elseif kind == "EnumItem" then
				out[flag] = { __type = "EnumItem", tostring(value.EnumType), value.Name }
			elseif kind == "table" then
				local list = {}
				for _, item in ipairs(value) do
					table.insert(list, item)
				end
				out[flag] = { __type = "List", Items = list }
			elseif kind == "boolean" or kind == "number" or kind == "string" then
				out[flag] = value
			end
		end
	end
	return out
end

function Library:LoadConfig(data: { [string]: any })
	for flag, raw in pairs(data or {}) do
		local widget = self.Flags[flag]
		if widget ~= nil then
			local value = raw
			if type(raw) == "table" then
				if raw.__type == "Color3" then
					value = Color3.new(raw[1] or 1, raw[2] or 1, raw[3] or 1)
				elseif raw.__type == "EnumItem" then
					local ok, item = pcall(function()
						return (Enum :: any)[raw[2] and raw[1] or ""][raw[2]]
					end)
					value = if ok then item else nil
				elseif raw.__type == "List" then
					value = raw.Items or {}
				end
			end
			pcall(widget.Set, widget, value)
		end
	end
end

-- ═══════════════════════════════════ Unload ════════════════════════════════
-- Full teardown: every window, widget, connection, loop thread, popup,
-- notification, and the ScreenGui itself. Nothing is left running.
function Library:Unload()
	if self._unloaded then
		return
	end
	self._unloaded = true
	self:_closePopup()
	self:_hideTooltip()
	for index = #self.Windows, 1, -1 do
		local window = self.Windows[index]
		pcall(function()
			window:Destroy()
		end)
	end
	self._maid:Clean()
	if self._gui then
		self._gui:Destroy()
		self._gui = nil
	end
	table.clear(self.Flags)
	table.clear(self.Windows)
end

--[[
	════════════════════════════════════ USAGE EXAMPLE ═════════════════════════
	Paste into a LocalScript (with this module as a child named "GraphiteUI"),
	or loadstring() the file in a suitable environment.

	local Library = require(script.GraphiteUI)

	-- Optional: re-skin (everything re-themes live)
	-- Library:SetTheme({ Accent = Color3.fromRGB(120, 170, 255) })

	local Window = Library:CreateWindow({
		Title = "Graphite Demo",
		Size = UDim2.fromOffset(600, 460),
		ToggleKey = Enum.KeyCode.RightShift, -- show/hide the window
		-- Icon = "rbxassetid://1234567890",
	})

	-- Menu bar ---------------------------------------------------------------
	local fileMenu = Window:CreateMenu("File")
	fileMenu:AddItem({ Name = "Save config", Callback = function()
		local snapshot = Library:SaveConfig()
		print("Saved flags:", snapshot)
		Library:Notify({ Title = "Config", Content = "Configuration captured." })
	end })
	fileMenu:AddSeparator()
	fileMenu:AddItem({ Name = "Unload UI", Callback = function()
		Library:Unload()
	end })

	-- Main tab ---------------------------------------------------------------
	local Main = Window:CreateTab("Main")

	Main:CreateLabel("Every widget lives on this tab. Hover things for tooltips.")
	Main:CreateSeparator({ Text = "Actions" })

	Main:CreateButton({
		Name = "Click Me",
		Tooltip = "A regular button",
		Callback = function()
			Library:Notify({ Title = "Button", Content = "Clicked!", Duration = 3 })
		end,
	})
	local disabledBtn = Main:CreateButton({ Name = "Disabled", Disabled = true })
	-- disabledBtn:SetDisabled(false) -- re-enable from code any time

	-- Toggles with independent loop threads ----------------------------------
	-- Both can be ON at once; each loop runs on its own task.spawn thread and
	-- neither blocks the other or the UI.
	Main:CreateToggle({
		Name = "Auto Farm",
		Default = false,
		Flag = "auto_farm",
		Tooltip = "Loops every 0.5s while enabled",
		Callback = function(enabled)         -- fires once per state change
			print("Auto Farm:", enabled)
		end,
		LoopCallback = function()            -- loops on its own thread while on
			print("farming...")
		end,
		LoopInterval = 0.5,
	})
	Main:CreateToggle({
		Name = "Auto Collect",
		Flag = "auto_collect",
		LoopCallback = function()
			print("collecting...")
		end,
		LoopInterval = 1,
	})

	-- Value widgets ----------------------------------------------------------
	Main:CreateSlider({
		Name = "WalkSpeed", Min = 8, Max = 100, Step = 1, Default = 16,
		Flag = "walkspeed",
		Callback = function(v) print("speed", v) end,
	})
	Main:CreateSlider({
		Name = "Field of View", Min = 0.5, Max = 1.5, Step = 0.05, Default = 1,
		Suffix = "x", Flag = "fov_scale",
		Callback = function(v) print("fov scale", v) end,
	})
	Main:CreateDragInput({
		Name = "Offset Y", Step = 0.1, Default = 0, Flag = "offset_y",
		Callback = function(v) print("offset", v) end,
	})
	Main:CreateInput({
		Name = "Player Name", Placeholder = "type here...", Flag = "target",
		Callback = function(text) print("target:", text) end,
	})
	Main:CreateInput({
		Name = "Amount", Numeric = true, Default = 10, Finished = true,
		Callback = function(n) print("amount:", n) end,
	})
	Main:CreateKeybind({
		Name = "Toggle Key", Default = Enum.KeyCode.E, Flag = "action_key",
		Callback = function(key) print("pressed", key.Name) end,
		ChangedCallback = function(key) print("rebound to", key and key.Name) end,
	})
	Main:CreateColorPicker({
		Name = "ESP Color", Default = Color3.fromRGB(255, 80, 80), Flag = "esp_color",
		Callback = function(color) print("color", color) end,
	})

	-- Selection widgets ------------------------------------------------------
	local Misc = Window:CreateTab("Widgets")

	Misc:CreateDropdown({
		Name = "Mode", Items = { "Legit", "Rage", "Spectate" }, Default = "Legit",
		Flag = "mode", Callback = function(v) print("mode:", v) end,
	})
	Misc:CreateDropdown({
		Name = "Targets", Items = { "Head", "Torso", "Legs" }, MultiSelect = true,
		Default = { "Head" }, Flag = "targets",
		Callback = function(list) print("targets:", table.concat(list, ", ")) end,
	})
	Misc:CreateRadioGroup({
		Name = "Team", Options = { "Red", "Blue", "Neutral" }, Default = "Neutral",
		Flag = "team", Callback = function(choice) print("team:", choice) end,
	})
	Misc:CreateListBox({
		Name = "Players", Items = { "Alice", "Bob", "Carol", "Dan" }, Height = 100,
		Callback = function(sel) print("selected:", sel) end,
	})
	Misc:CreateTable({
		Columns = { "Item", "Count", "Rarity" },
		Rows = {
			{ "Sword", 1, "Rare" },
			{ "Potion", 12, "Common" },
		},
	})
	local progress = Misc:CreateProgressBar({ Name = "Loading", Default = 0.35 })
	-- progress:Set(0.8) -- animate to 80% any time

	-- Collapsing section (nests the full widget set, sections included) ------
	local sect = Misc:CreateSection({ Name = "Advanced", Open = false })
	sect:CreateToggle({ Name = "Nested toggle", Callback = print })
	local inner = sect:CreateSection({ Name = "Even deeper" })
	inner:CreateLabel("TreeNode-style nesting works.")

	-- Modal dialog -----------------------------------------------------------
	Misc:CreateButton({
		Name = "Reset everything",
		Callback = function()
			Window:Dialog({
				Title = "Confirm reset",
				Content = "This clears all settings. Are you sure?",
				Buttons = {
					{ Text = "Reset", Callback = function() print("reset!") end },
					{ Text = "Cancel" },
				},
			})
		end,
	})

	-- Driving widgets from code ----------------------------------------------
	-- Every widget object supports :Set(value) / :Get() (and :Destroy()).
	-- Library.Flags.walkspeed:Set(40)
	-- print(Library.Flags.mode:Get())

	-- Config round-trip ------------------------------------------------------
	-- local saved = Library:SaveConfig()   -- plain table, JSON-safe
	-- Library:LoadConfig(saved)            -- restores + fires callbacks
	════════════════════════════════════════════════════════════════════════════
]]

return Library