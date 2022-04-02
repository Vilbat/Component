-- Component
-- Stephen Leitnick
-- November 26, 2021

-- Modified component package

type AncestorList = { Instance }

type ExtensionFn = (any) -> ()

type ExtensionShouldFn = (any) -> boolean

type Extension = {
	ShouldExtend: ExtensionShouldFn?,
	ShouldConstruct: ExtensionShouldFn?,
	Constructing: ExtensionFn?,
	Constructed: ExtensionFn?,
	Starting: ExtensionFn?,
	Started: ExtensionFn?,
	Stopping: ExtensionFn?,
	Stopped: ExtensionFn?,
}

type ComponentConfig = {
	Tag: string,
	Ancestors: AncestorList?,
	Extensions: { Extension }?,
}

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Signal)
local Symbol = require(script.Parent.Symbol)
local Trove = require(script.Parent.Trove)
local Promise = require(script.Parent.Promise)

local IS_SERVER = RunService:IsServer()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DEFAULT_ANCESTORS = { workspace, game:GetService("Players") }
local DEFAULT_TIMEOUT = 60

-- Symbol keys
local KEY_ANCESTORS = Symbol("Ancestors")
local KEY_EXTENSIONS = Symbol("Extensions")
local KEY_TROVE = Symbol("Trove")
local KEY_ACTIVE_EXTENSIONS = Symbol("ActiveExtensions")

local KEY_CONSTRUCTED = Symbol("Constructed")
local KEY_STARTED = Symbol("Started")
local KEY_COMPONENTS = Symbol("Components")

local KEY_STOPPED = Symbol("Stopped")

local renderId = 0
local function NextRenderName(): string
	renderId += 1
	return "ComponentRender" .. tostring(renderId)
end

local function InvokeExtensionFn(component, fnName: string)
	for _, extension in ipairs(component[KEY_ACTIVE_EXTENSIONS]) do
		local fn = extension[fnName]
		if type(fn) == "function" then
			fn(component)
		end
	end
end

local function ShouldConstruct(component): boolean
	for _, extension in ipairs(component[KEY_ACTIVE_EXTENSIONS]) do
		local fn = extension.ShouldConstruct
		if type(fn) == "function" then
			local shouldConstruct = fn(component)
			if not shouldConstruct then
				return false
			end
		end
	end
	return true
end

local function GetActiveExtensions(component, extensionList)
	local activeExtensions = table.create(#extensionList)
	local allActive = true
	for _, extension in ipairs(extensionList) do
		local fn = extension.ShouldExtend
		local shouldExtend = type(fn) ~= "function" or not not fn(component)
		if shouldExtend then
			table.insert(activeExtensions, extension)
		else
			allActive = false
		end
	end
	return if allActive then extensionList else activeExtensions
end

local Component = {}
Component.__index = Component

function Component.new(config: ComponentConfig)
	local customComponent = {}
	customComponent.__index = customComponent
	customComponent.__tostring = function()
		return "Component<" .. config.Tag .. ">"
	end
	customComponent[KEY_TROVE] = Trove.new()

	customComponent[KEY_ANCESTORS] = config.Ancestors or DEFAULT_ANCESTORS
	customComponent[KEY_EXTENSIONS] = config.Extensions or {}

	customComponent[KEY_CONSTRUCTED] = {}
	customComponent[KEY_STARTED] = {}
	customComponent[KEY_COMPONENTS] = {}

	customComponent[KEY_STOPPED] = false

	customComponent.Tag = config.Tag
	customComponent.Started = customComponent[KEY_TROVE]:Construct(Signal)
	customComponent.Stopped = customComponent[KEY_TROVE]:Construct(Signal)
	setmetatable(customComponent, Component)
	customComponent:_setup()

	customComponent[KEY_TROVE]:Add(function()
		customComponent[KEY_STOPPED] = true
		customComponent:_end()
	end)

	return customComponent
end

function Component:_end()
	for instance, _ in pairs(self[KEY_CONSTRUCTED]) do
		task.spawn(function()
			self:_stop(instance)
		end)
	end
end

function Component:_instansiate(instance: Instance)
	local function StartComponent(component)
		InvokeExtensionFn(component, "Starting")
		component:Start()
		InvokeExtensionFn(component, "Started")
		local hasHeartbeatUpdate = typeof(component.HeartbeatUpdate) == "function"
		local hasSteppedUpdate = typeof(component.SteppedUpdate) == "function"
		local hasRenderSteppedUpdate = typeof(component.RenderSteppedUpdate) == "function"
		if hasHeartbeatUpdate then
			component._heartbeatUpdate = RunService.Heartbeat:Connect(function(dt)
				component:HeartbeatUpdate(dt)
			end)
		end
		if hasSteppedUpdate then
			component._steppedUpdate = RunService.Stepped:Connect(function(_, dt)
				component:SteppedUpdate(dt)
			end)
		end
		if hasRenderSteppedUpdate and not IS_SERVER then
			if component.RenderPriority then
				component._renderName = NextRenderName()
				RunService:BindToRenderStep(component._renderName, component.RenderPriority, function(dt)
					component:RenderSteppedUpdate(dt)
				end)
			else
				component._renderSteppedUpdate = RunService.RenderStepped:Connect(function(dt)
					component:RenderSteppedUpdate(dt)
				end)
			end
		end

		self.Started:Fire(component)
	end

	self[KEY_CONSTRUCTED][instance] = Promise.defer(function(resolve, reject)
		local component = setmetatable({}, self)
		component.Instance = instance
		component[KEY_ACTIVE_EXTENSIONS] = GetActiveExtensions(component, self[KEY_EXTENSIONS])

		if not ShouldConstruct(component) then
			reject()
			return
		end
		InvokeExtensionFn(component, "Constructing")
		if type(component.Construct) == "function" then
			component:Construct()
		end
		InvokeExtensionFn(component, "Constructed")

		table.insert(self[KEY_COMPONENTS], component)
		resolve(component)
	end)

	self[KEY_STARTED][instance] = Promise.new(function(resolve, reject)
		self[KEY_CONSTRUCTED][instance]
			:andThen(function(component)
				task.defer(function()
					Promise.try(function()
						StartComponent(component)
					end):andThen(resolve):catch(reject)
				end)
			end)
			:catch(reject)
	end):catch(function(error)
		if error then
			warn(error)
		end
	end)
end

function Component:_stop(instance: Instance)
	local constructed = self[KEY_CONSTRUCTED][instance]
	self[KEY_CONSTRUCTED][instance] = nil

	constructed
		:andThen(function(component)
			local index = table.find(self[KEY_COMPONENTS], component)
			if index then
				table.remove(self[KEY_COMPONENTS], index)
			end

			self[KEY_STARTED][instance]:await()

			if component._heartbeatUpdate then
				component._heartbeatUpdate:Disconnect()
			end
			if component._steppedUpdate then
				component._steppedUpdate:Disconnect()
			end
			if component._renderSteppedUpdate then
				component._renderSteppedUpdate:Disconnect()
			elseif component._renderName then
				RunService:UnbindFromRenderStep(component._renderName)
			end
			InvokeExtensionFn(component, "Stopping")
			component:Stop()
			InvokeExtensionFn(component, "Stopped")
			self.Stopped:Fire(component)
		end)
		:finally(function()
			self[KEY_STARTED][instance] = nil
		end)
		:catch(function(error)
			if error then
				warn(error)
			end
		end)
end

function Component:_setup()
	local watchingInstances = {}

	local function TryConstructComponent(instance)
		if self[KEY_CONSTRUCTED][instance] then
			return
		end

		self:_instansiate(instance)
	end

	local function TryDeconstructComponent(instance)
		if not self[KEY_CONSTRUCTED][instance] then
			return
		end

		self:_stop(instance)
	end

	local function StartWatchingInstance(instance)
		local function IsInAncestorList(): boolean
			for _, parent in ipairs(self[KEY_ANCESTORS]) do
				if instance:IsDescendantOf(parent) then
					return true
				end
			end
			return false
		end

		local ancestryChangedHandle = self[KEY_TROVE]:Connect(instance.AncestryChanged, function(_, parent)
			if parent and IsInAncestorList() then
				TryConstructComponent(instance)
			else
				TryDeconstructComponent(instance)
			end
		end)
		watchingInstances[instance] = ancestryChangedHandle
		if IsInAncestorList() then
			TryConstructComponent(instance)
		end
	end

	local function InstanceTagged(instance: Instance)
		if self[KEY_STOPPED] then
			return
		end
		StartWatchingInstance(instance)
	end

	local function InstanceUntagged(instance: Instance)
		local watchHandle = watchingInstances[instance]
		if watchHandle then
			watchHandle:Disconnect()
			watchingInstances[instance] = nil
		end

		TryDeconstructComponent(instance)
	end

	task.defer(function()
		self[KEY_TROVE]:Connect(CollectionService:GetInstanceAddedSignal(self.Tag), InstanceTagged)
		self[KEY_TROVE]:Connect(CollectionService:GetInstanceRemovedSignal(self.Tag), InstanceUntagged)

		local tagged = CollectionService:GetTagged(self.Tag)
		for _, instance in ipairs(tagged) do
			task.spawn(InstanceTagged, instance)
		end
	end)
end

function Component:GetAll(): table
	return self[KEY_COMPONENTS]
end

function Component:FromInstance(instance): table
	local promise = self[KEY_CONSTRUCTED][instance]

	if not promise then
		return
	end

	if promise:getStatus() ~= Promise.Status.Resolved then
		return
	end

	local _, component = promise:await()
	return component
end

function Component:GetComponent(componentClass)
	return componentClass:FromInstance(self.Instance)
end

function Component:WaitForInstance(instance: Instance, timeout: number?): table
	local promise = self[KEY_STARTED][instance]
	if promise then
		if promise:getStatus() ~= Promise.Status.Started then
			local _, component = promise:await()
			return component
		end
	end

	local component
	return Promise.fromEvent(self.Started, function(c)
		local match = c.Instance == instance
		if match then
			component = c
		end
		return match
	end)
		:andThen(function()
			return component
		end)
		:timeout(if type(timeout) == "number" then timeout else DEFAULT_TIMEOUT)
end

function Component:Construct() end

function Component:Start() end

function Component:Stop() end

function Component:Destroy()
	self[KEY_TROVE]:Destroy()
end

return Component
